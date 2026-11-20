"""Audio para escuchar en la app: une las pistas (micrófono + reunión, todos los
bloques) en playback.m4a, alineadas en el tiempo real de la sesión, y calcula
la forma de onda (playback.json) para dibujarla sin leer el audio.
"""

from __future__ import annotations

import wave

import numpy as np

from ..config import Config
from ..session import Session
from ..util import atomic_write_json, read_json, run
from .audio import usable_tracks

BINS = 240


def _peaks(parts: list[tuple[float, np.ndarray]], duration: float) -> list[float]:
    """Pico por franja (0-1) de todas las pistas sobre la línea de tiempo global."""
    sr = 16000
    peaks = np.zeros(BINS, dtype=np.float32)
    if duration <= 0:
        return peaks.tolist()
    for off, x in parts:
        if not len(x):
            continue
        idx = ((off + np.arange(0, len(x), 160) / sr) / duration * BINS).astype(int).clip(0, BINS - 1)
        frames = np.abs(x[: len(x) // 160 * 160].reshape(-1, 160)).max(axis=1)
        np.maximum.at(peaks, idx[: len(frames)], frames)
    ref = float(np.percentile(peaks[peaks > 0], 95)) if (peaks > 0).any() else 1.0
    return [round(float(v), 3) for v in np.clip(peaks / (ref or 1.0), 0, 1)]


class Playback:
    name = "playback"

    def is_done(self, s: Session, cfg: Config) -> bool:
        info = s.path / "playback.json"
        if not (info.is_file() and (s.path / "playback.m4a").is_file()):
            return False
        return read_json(info).get("tracks") == sorted(t.name for t in usable_tracks(s))

    def run(self, s: Session, cfg: Config) -> None:
        tracks = sorted(usable_tracks(s), key=lambda t: t.name)
        if not tracks:
            return
        args, chains, labels, parts = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"], [], [], []
        duration = 0.0
        for i, t in enumerate(tracks):
            wav = s.wav16k(t.name)
            args += ["-i", str(wav)]
            ms = int(round(t.offset_s * 1000))
            chains.append(f"[{i}]adelay={ms}:all=1[a{i}]")
            labels.append(f"[a{i}]")
            with wave.open(str(wav)) as w:
                x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
            parts.append((t.offset_s, x))
            duration = max(duration, t.offset_s + len(x) / 16000)
        if len(tracks) > 1:
            mix = f"{''.join(labels)}amix=inputs={len(tracks)}:normalize=0:dropout_transition=0,alimiter=limit=0.95[out]"
        else:
            mix = "[a0]anull[out]"
        out = s.path / "playback.m4a"
        tmp = s.path / "playback.tmp.m4a"
        run(args + ["-filter_complex", ";".join(chains + [mix]), "-map", "[out]", "-ac", "1",
                    "-c:a", "aac", "-b:a", "48k", "-f", "mp4", str(tmp)], timeout=3600)
        tmp.replace(out)
        atomic_write_json(s.path / "playback.json", {
            "tracks": [t.name for t in tracks],
            "duration_s": round(duration, 2),
            "peaks": _peaks(parts, duration),
        })
