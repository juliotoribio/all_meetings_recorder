from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

log = logging.getLogger("recorder")


class StepError(Exception):
    """Error reintentable (se reintenta con backoff)."""


class PermanentError(StepError):
    """Error que no se arregla reintentando (requiere intervención)."""


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def atomic_write_json(path: Path, data: Any) -> None:
    atomic_write_text(path, json.dumps(data, ensure_ascii=False, indent=2))


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def run(cmd: list[str], timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    """Ejecuta un comando; convierte fallos en StepError con el final de stderr."""
    log.debug("exec: %s", " ".join(cmd))
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise StepError(f"timeout ({timeout:.0f}s): {Path(cmd[0]).name}") from e
    except FileNotFoundError as e:
        raise PermanentError(f"no existe el ejecutable: {cmd[0]}") from e
    if res.returncode != 0:
        tail = "\n".join(res.stderr.strip().splitlines()[-8:])
        raise StepError(f"{Path(cmd[0]).name} salió con código {res.returncode}:\n{tail}")
    return res


def ffprobe_duration(path: Path) -> float:
    res = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)], timeout=60)
    try:
        return float(res.stdout.strip())
    except ValueError as e:
        raise PermanentError(f"no se pudo leer la duración de {path.name}") from e


def fmt_ts(seconds: float) -> str:
    s = max(0, int(seconds))
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def notify(title: str, message: str) -> None:
    """Notificación de macOS; nunca falla el pipeline."""
    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')
    try:
        subprocess.run(
            ["osascript", "-e", f'display notification "{esc(message)}" with title "{esc(title)}"'],
            capture_output=True, timeout=10,
        )
    except Exception:  # noqa: BLE001
        log.debug("notificación falló", exc_info=True)
