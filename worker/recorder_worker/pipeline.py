"""Orquestación: descubre sesiones, ejecuta pasos idempotentes, reintenta."""

from __future__ import annotations

import fcntl
import logging
import shutil
import time
import traceback
from pathlib import Path

from .config import Config
from .queue import Queue
from .session import Session
from .steps.audio import Normalize, Validate
from .steps.export import Export
from .steps.merge import Merge
from .steps.playback import Playback
from .steps.speakers import Speakers
from .steps.summarize import Summarize
from .steps.transcribe import Transcribe
from .util import PermanentError, StepError, read_json

log = logging.getLogger("recorder")

STEPS = [Validate(), Normalize(), Transcribe(), Speakers(), Merge(), Playback(), Summarize(), Export()]
# Durante la grabación sólo se transcriben los bloques cerrados (sin resumen ni exportación).
LIVE_STEPS = [Validate(), Normalize(), Transcribe(), Speakers(), Merge()]
STEP_NAMES = [s.name for s in STEPS]
READY_STATUSES = {"recorded", "recovered"}


def artifacts_from(s: Session, step: str) -> list[Path]:
    """Artefactos que hay que borrar para rehacer desde `step` en adelante."""
    idx = STEP_NAMES.index(step)
    paths: list[Path] = []
    later = set(STEP_NAMES[idx:])
    if "validate" in later:
        paths += [s.validate_json, s.work / "validate.failed.json"]
    if "normalize" in later:
        paths += list(s.work.glob("*.16k.wav")) + list(s.work.glob("*.env.npy"))
    if "transcribe" in later:
        paths += list(s.work.glob("*.segments.json")) + list(s.work.glob("*.whisper.json"))
        paths += [p for p in s.work.glob("*.chunks") if p.is_dir()]
    if "speakers" in later:
        paths += list(s.work.glob("*.emb.npz"))
    if "merge" in later:
        paths += [s.transcript_json, s.transcript_md, s.transcript_txt]
    if "playback" in later:
        paths += [s.path / "playback.m4a", s.path / "playback.json"]
    if "summarize" in later:
        paths += [s.summary_json, s.summary_md]
    if "export" in later:
        paths += [s.export_marker]
    return paths


def reset_from(s: Session, step: str) -> None:
    for p in artifacts_from(s, step):
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
        else:
            p.unlink(missing_ok=True)


def discover(cfg: Config, q: Queue) -> int:
    new = 0
    for manifest in sorted(cfg.paths.sessions.glob("*/manifest.json")):
        try:
            status = read_json(manifest).get("status")
        except Exception:  # noqa: BLE001  (manifest a medio escribir)
            continue
        if status in READY_STATUSES and q.add(manifest.parent.name, manifest.parent):
            log.info("nueva sesión en cola: %s", manifest.parent.name)
            new += 1
    return new


def run_steps(s: Session, cfg: Config, on_step=None) -> None:
    s.work.mkdir(exist_ok=True)
    for step in STEPS:
        if step.is_done(s, cfg):
            continue
        if on_step:
            on_step(step.name)
        log.info("[%s] paso: %s", s.id, step.name)
        t0 = time.monotonic()
        step.run(s, cfg)
        log.info("[%s] %s OK (%.1fs)", s.id, step.name, time.monotonic() - t0)


def process_live(s: Session, cfg: Config) -> None:
    """Transcribe los bloques ya cerrados de una sesión que sigue grabando.

    Idempotente: lo ya transcrito se salta. Deja una transcripción parcial
    (transcript.txt) que se puede copiar mientras la reunión continúa.
    """
    s.work.mkdir(exist_ok=True)
    for step in LIVE_STEPS:
        if not step.is_done(s, cfg):
            t0 = time.monotonic()
            step.run(s, cfg)
            log.info("[%s] (en vivo) %s OK (%.1fs)", s.id, step.name, time.monotonic() - t0)


def process_job(cfg: Config, q: Queue, session_id: str) -> bool:
    job = q.get(session_id)
    if job is None:
        raise KeyError(session_id)
    s = Session(Path(job["path"]))
    try:
        run_steps(s, cfg, on_step=lambda name: q.running(session_id, name))
    except PermanentError as e:
        log.error("[%s] fallo permanente: %s", session_id, e)
        q.fail(session_id, str(e))
        _mark(s, "failed", str(e))
        return False
    except Exception as e:  # noqa: BLE001
        attempts = job["attempts"] + 1
        msg = str(e) if isinstance(e, StepError) else f"{type(e).__name__}: {e}"
        if not isinstance(e, StepError):
            log.error("[%s] error inesperado:\n%s", session_id, traceback.format_exc())
        if attempts >= cfg.worker.max_attempts:
            log.error("[%s] falló %d veces, se marca como fallida: %s", session_id, attempts, msg)
            q.fail(session_id, msg)
            _mark(s, "failed", msg)
        else:
            delay = cfg.worker.backoff_base_s * 2 ** (attempts - 1)
            log.warning("[%s] intento %d falló (%s); reintento en %ds", session_id, attempts, msg, delay)
            q.retry_later(session_id, msg, attempts, delay)
        return False
    q.done(session_id)
    _mark(s, "done", None)
    log.info("[%s] sesión completada", session_id)
    return True


def _mark(s: Session, state: str, error: str | None) -> None:
    """Estado visible para la app de la barra de menú."""
    try:
        s.update_manifest(pipeline=state, pipeline_error=(error or "").splitlines()[0][:200] if error else None)
    except Exception:  # noqa: BLE001
        pass


class WorkerLock:
    """Garantiza un único worker procesando a la vez."""

    def __init__(self, path: Path):
        self.path = path
        self.fh = None

    def acquire(self, wait_s: float = 0) -> bool:
        """`wait_s` > 0: espera su turno (p. ej. la app encola bloques seguidos)."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(self.path, "w")  # noqa: SIM115
        deadline = time.monotonic() + wait_s
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.fh.close()
                    self.fh = None
                    return False
                time.sleep(1)

    def release(self) -> None:
        if self.fh:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
            self.fh.close()
            self.fh = None


def drain(cfg: Config, q: Queue) -> int:
    """Procesa todo lo listo ahora mismo. Devuelve cuántas sesiones se procesaron."""
    n = 0
    while (job := q.next_ready()) is not None:
        process_job(cfg, q, job["session_id"])
        n += 1
    return n


def run_forever(cfg: Config, q: Queue) -> None:
    lock = WorkerLock(cfg.paths.home / "worker.lock")
    if not lock.acquire():
        raise SystemExit("Ya hay un worker corriendo (worker.lock ocupado).")
    try:
        if (n := q.recover_orphans()):
            log.warning("%d sesiones interrumpidas se reanudan", n)
        log.info("worker iniciado; vigilando %s", cfg.paths.sessions)
        while True:
            discover(cfg, q)
            if drain(cfg, q) == 0:
                time.sleep(cfg.worker.poll_seconds)
    finally:
        lock.release()
