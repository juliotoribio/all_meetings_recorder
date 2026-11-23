"""Qué audio se conserva cuando una sesión ya está transcrita.

Al grabar se guardan los bloques en crudo (chunks/, ~1,2 GB por hora) y el
proceso crea copias a 16 kHz y trozos en work/. Terminada la sesión, para
leer, escuchar, buscar y resumir sólo hace falta la transcripción, el
resumen, playback.m4a (audio comprimido) y los JSON pequeños de work/
(entre ellos voices.json, que recuerda las voces entre reuniones).

Política (la elige la app en <home>/storage.json, clave "keep_audio"):
  delete  borrar el audio original al terminar (por defecto)
  7d      conservarlo 7 días
  always  no borrar nunca

Sólo se limpian sesiones terminadas por este mecanismo (marcadas en el
manifest); las anteriores se liberan a mano con `recorder free-space`.
"""

from __future__ import annotations

import json
import logging
import shutil
import time
from pathlib import Path

from .config import Config
from .session import Session
from .util import read_json

log = logging.getLogger("recorder")

POLICIES = {"delete": 0, "7d": 7 * 86400, "always": None}
DEFAULT_POLICY = "delete"
_WORK_FILES = ("*.16k.wav", "*.tmp.wav", "*.env.npy")
_WORK_DIRS = ("*.pieces", "*.chunks")


def storage_path(cfg: Config) -> Path:
    return cfg.paths.home / "storage.json"


def keep_policy(cfg: Config) -> str:
    try:
        value = json.loads(storage_path(cfg).read_text(encoding="utf-8")).get("keep_audio")
    except (OSError, ValueError, AttributeError):
        value = None
    return value if value in POLICIES else DEFAULT_POLICY


def _size(p: Path) -> int:
    if p.is_dir():
        return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    return p.stat().st_size if p.is_file() else 0


def heavy_paths(s: Session) -> list[Path]:
    """Audio original y archivos intermedios que ya no hacen falta."""
    paths: list[Path] = []
    root = s.path.resolve()
    try:
        tracks = s.manifest().get("tracks") or {}
    except Exception:  # noqa: BLE001
        tracks = {}
    for t in tracks.values():
        f = (s.path / str(t.get("file", ""))).resolve()
        # Sólo lo que vive dentro de la sesión (nunca el archivo importado original).
        if f.is_file() and root in f.parents and f.name != "playback.m4a":
            paths.append(f)
    chunks = s.path / "chunks"
    if chunks.is_dir():
        paths.append(chunks)
    if s.work.is_dir():
        for g in _WORK_FILES:
            paths += s.work.glob(g)
        for g in _WORK_DIRS:
            paths += [p for p in s.work.glob(g) if p.is_dir()]
    # Sin duplicados (un bloque de chunks/ y la carpeta chunks/).
    out: list[Path] = []
    for p in paths:
        if not any(q in p.parents for q in paths) and p not in out:
            out.append(p)
    return out


def can_purge(s: Session) -> bool:
    try:
        m = s.manifest()
    except Exception:  # noqa: BLE001
        return False
    return (m.get("status") != "recording" and m.get("pipeline") == "done" and not m.get("audio_purged")
            and s.transcript_json.is_file() and (s.path / "playback.m4a").is_file())


def purge(s: Session) -> int:
    """Borra el audio original y los intermedios. Devuelve los bytes liberados."""
    if not can_purge(s):
        return 0
    freed = 0
    for p in heavy_paths(s):
        freed += _size(p)
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
        else:
            p.unlink(missing_ok=True)
    s.update_manifest(audio_purged=True, audio_purged_at=time.time(), audio_expires_at=None,
                      audio_freed_bytes=freed)
    log.info("[%s] audio original borrado (%.0f MB liberados)", s.id, freed / 1e6)
    return freed


def after_done(cfg: Config, s: Session) -> None:
    """Se llama al completar una sesión: aplica la política elegida."""
    policy = keep_policy(cfg)
    keep = POLICIES[policy]
    try:
        if keep == 0:
            purge(s)
        elif keep is not None and not s.manifest().get("audio_purged"):
            s.update_manifest(audio_expires_at=time.time() + keep)
    except Exception:  # noqa: BLE001  (la limpieza nunca hace fallar una sesión)
        log.warning("[%s] no se pudo limpiar el audio", s.id, exc_info=True)


def sweep(cfg: Config, now: float | None = None) -> int:
    """Borra el audio de las sesiones cuyo plazo venció. Devuelve cuántas limpió."""
    policy = keep_policy(cfg)
    if POLICIES[policy] is None:
        return 0
    now = time.time() if now is None else now
    n = 0
    for manifest in sorted(cfg.paths.sessions.glob("*/manifest.json")):
        try:
            exp = read_json(manifest).get("audio_expires_at")
        except Exception:  # noqa: BLE001
            continue
        if exp is None or (policy != "delete" and float(exp) > now):
            continue
        s = Session(manifest.parent)
        try:
            if purge(s):
                n += 1
        except Exception:  # noqa: BLE001
            log.warning("[%s] no se pudo limpiar el audio", s.id, exc_info=True)
    return n


def reclaimable(cfg: Config) -> dict:
    """Cuánto se liberaría borrando el audio original de todas las sesiones terminadas."""
    sessions, total = 0, 0
    for manifest in sorted(cfg.paths.sessions.glob("*/manifest.json")):
        s = Session(manifest.parent)
        if can_purge(s):
            b = sum(_size(p) for p in heavy_paths(s))
            if b:
                sessions += 1
                total += b
    return {"policy": keep_policy(cfg), "sessions": sessions, "bytes": total}


def purge_all(cfg: Config) -> dict:
    sessions, total = 0, 0
    for manifest in sorted(cfg.paths.sessions.glob("*/manifest.json")):
        b = purge(Session(manifest.parent))
        if b:
            sessions += 1
            total += b
    return {"sessions": sessions, "bytes": total}


def restore_from_playback(s: Session) -> None:
    """Para volver a transcribir una sesión sin audio original: usa playback.m4a
    (mezcla mono comprimida) como única pista. Pierde la separación Yo/Participantes."""
    pb = s.path / "playback.m4a"
    if not pb.is_file():
        from .util import PermanentError
        raise PermanentError("el audio original se borró y no queda playback.m4a")
    src = s.path / "audio.m4a"
    shutil.copyfile(pb, src)
    s.update_manifest(tracks={"mixed": {"file": "audio.m4a", "first_host_time_s": 0.0}},
                      audio_purged=False, audio_expires_at=None, retranscribed_from="playback")
