"""Cola persistente (SQLite) con estados, reintentos y backoff."""

from __future__ import annotations

import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    session_id  TEXT PRIMARY KEY,
    path        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',   -- pending | running | done | failed
    step        TEXT,
    attempts    INTEGER NOT NULL DEFAULT 0,
    last_error  TEXT,
    next_run_at REAL NOT NULL DEFAULT 0,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
"""


class Queue:
    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = db_path
        with self._conn() as c:
            c.executescript(SCHEMA)

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def add(self, session_id: str, path: Path) -> bool:
        now = time.time()
        with self._conn() as c:
            cur = c.execute(
                "INSERT OR IGNORE INTO jobs(session_id, path, created_at, updated_at) VALUES (?,?,?,?)",
                (session_id, str(path), now, now),
            )
            return cur.rowcount > 0

    def remove(self, session_id: str) -> bool:
        with self._conn() as c:
            return c.execute("DELETE FROM jobs WHERE session_id=?", (session_id,)).rowcount > 0

    def get(self, session_id: str) -> sqlite3.Row | None:
        with self._conn() as c:
            return c.execute("SELECT * FROM jobs WHERE session_id=?", (session_id,)).fetchone()

    def all(self) -> list[sqlite3.Row]:
        with self._conn() as c:
            return c.execute("SELECT * FROM jobs ORDER BY created_at DESC").fetchall()

    def next_ready(self) -> sqlite3.Row | None:
        with self._conn() as c:
            return c.execute(
                "SELECT * FROM jobs WHERE status='pending' AND next_run_at<=? ORDER BY created_at LIMIT 1",
                (time.time(),),
            ).fetchone()

    def _set(self, session_id: str, **fields) -> None:
        fields["updated_at"] = time.time()
        cols = ", ".join(f"{k}=?" for k in fields)
        with self._conn() as c:
            c.execute(f"UPDATE jobs SET {cols} WHERE session_id=?", (*fields.values(), session_id))

    def running(self, session_id: str, step: str) -> None:
        self._set(session_id, status="running", step=step)

    def done(self, session_id: str) -> None:
        self._set(session_id, status="done", step=None, attempts=0, last_error=None)

    def fail(self, session_id: str, error: str) -> None:
        self._set(session_id, status="failed", last_error=error)

    def retry_later(self, session_id: str, error: str, attempts: int, delay_s: float) -> None:
        self._set(session_id, status="pending", last_error=error, attempts=attempts,
                  next_run_at=time.time() + delay_s)

    def reset(self, session_id: str) -> None:
        self._set(session_id, status="pending", attempts=0, last_error=None, next_run_at=0)

    def recover_orphans(self) -> int:
        """Al arrancar: un 'running' sólo puede venir de un worker que murió."""
        with self._conn() as c:
            cur = c.execute("UPDATE jobs SET status='pending', updated_at=? WHERE status='running'", (time.time(),))
            return cur.rowcount
