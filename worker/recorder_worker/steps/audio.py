"""Pasos 1-2: validar pistas y normalizar a WAV 16 kHz mono."""

from __future__ import annotations

import logging
import re

from ..config import Config
from ..session import Session
from ..util import PermanentError, atomic_write_json, ffprobe_duration, read_json, run

log = logging.getLogger("recorder")

SILENCE_DB = -60.0  # max_volume por debajo de esto = pista muda


def _max_volume(path) -> float:
    res = run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
              timeout=900)
    m = re.search(r"max_volume:\s*(-?[\d.]+|-inf) dB", res.stderr)
    if not m:
        return float("-inf")
    return float("-inf") if m.group(1) == "-inf" else float(m.group(1))


class Validate:
    name = "validate"

    def is_done(self, s: Session, cfg: Config) -> bool:
        if not s.validate_json.is_file():
            return False
        done = read_json(s.validate_json)
        return all(t.name in done for t in s.tracks())

    def run(self, s: Session, cfg: Config) -> None:
        # Incremental: con grabación por bloques llegan pistas nuevas durante la reunión.
        result: dict[str, dict] = read_json(s.validate_json) if s.validate_json.is_file() else {}
        for t in s.tracks():
            if t.name in result:
                continue
            if not t.file.is_file() or t.file.stat().st_size == 0:
                result[t.name] = {"usable": False, "reason": "archivo inexistente o vacío"}
                continue
            dur = ffprobe_duration(t.file)
            vol = _max_volume(t.file)
            usable = dur >= 1.0 and vol > SILENCE_DB
            reason = None if usable else ("demasiado corta" if dur < 1.0 else f"silencio (max {vol} dB)")
            result[t.name] = {"usable": usable, "duration_s": dur, "max_volume_db": vol, "reason": reason}
            log.info("[%s] pista %s: %.0fs, max %.1f dB%s", s.id, t.name, dur, vol,
                     "" if usable else f" -> se omite ({reason})")
        s.work.mkdir(exist_ok=True)
        if not any(r["usable"] for r in result.values()) and not s.is_recording:
            atomic_write_json(s.work / "validate.failed.json", result)
            raise PermanentError(f"ninguna pista utilizable: {result}")
        atomic_write_json(s.validate_json, result)


def usable_tracks(s: Session):
    info = read_json(s.validate_json)
    return [t for t in s.tracks() if info.get(t.name, {}).get("usable")]


def track_duration(s: Session, name: str) -> float:
    return float(read_json(s.validate_json)[name]["duration_s"])


class Normalize:
    name = "normalize"

    def is_done(self, s: Session, cfg: Config) -> bool:
        return all(s.wav16k(t.name).is_file() for t in usable_tracks(s))

    def run(self, s: Session, cfg: Config) -> None:
        s.work.mkdir(exist_ok=True)
        for t in usable_tracks(s):
            out = s.wav16k(t.name)
            if out.is_file():
                continue
            tmp = out.with_suffix(".tmp.wav")
            run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(t.file),
                 "-ac", "1", "-ar", "16000", "-af", "highpass=f=80", "-c:a", "pcm_s16le", str(tmp)],
                timeout=1800)
            tmp.replace(out)
        if not usable_tracks(s) and not s.is_recording:
            raise PermanentError("sin pistas utilizables")
