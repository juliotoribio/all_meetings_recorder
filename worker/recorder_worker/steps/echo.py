"""Detección de eco por señal (no por texto).

Con altavoces, el micrófono capta lo que dicen los participantes. Whisper suele
transcribir ese eco con otras palabras, así que comparar textos no basta. Aquí
se compara la *envolvente de energía* (cómo sube y baja el volumen cada 20 ms)
del micrófono con la del audio del sistema: si el micrófono sigue al sistema con
un pequeño retraso, es eco. Si hablas tú, tu voz no sigue esa forma.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

FRAME_S = 0.02          # 20 ms
SR = 16000
HOP = int(SR * FRAME_S)
MAX_LAG_FRAMES = 15     # el eco llega hasta ~300 ms tarde
SILENCE_DB = -100.0
ACTIVE_DB = -45.0       # el sistema "suena" por encima de esto
ECHO_CORR = 0.6         # correlación mínima para considerarlo eco


def envelope(wav: Path, cache: Path | None = None) -> np.ndarray:
    """Energía en dB por trama de 20 ms (con caché .npy)."""
    if cache and cache.is_file() and cache.stat().st_mtime >= wav.stat().st_mtime:
        return np.load(cache)
    with wave.open(str(wav)) as w:
        data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    n = len(data) // HOP
    frames = data[: n * HOP].reshape(n, HOP) if n else np.zeros((0, HOP), np.float32)
    env = 20 * np.log10(np.sqrt((frames ** 2).mean(axis=1)) / 32768 + 1e-5)
    env = env.astype(np.float32)
    if cache:
        np.save(cache, env)
    return env


class TrackEnvelope:
    """Envolvente global de una pista (une los bloques según su desplazamiento)."""

    def __init__(self, parts: list[tuple[float, np.ndarray]]):
        end = max((int(off / FRAME_S) + len(e) for off, e in parts), default=0)
        self.env = np.full(end, SILENCE_DB, dtype=np.float32)
        for off, e in parts:
            i = int(round(off / FRAME_S))
            self.env[i: i + len(e)] = e[: max(0, len(self.env) - i)]

    def window(self, a: int, b: int) -> np.ndarray:
        a, b = max(a, 0), min(b, len(self.env))
        return self.env[a:b] if b > a else np.zeros(0, np.float32)


def echo_score(mic: TrackEnvelope, system: TrackEnvelope, start: float, end: float) -> float:
    """Correlación máxima (0-1) entre mic y sistema en [start, end], probando retrasos."""
    a, b = int(start / FRAME_S), int(end / FRAME_S)
    m = mic.window(a, b)
    if len(m) < 10 or m.std() < 1.0:
        return 0.0
    best = 0.0
    for lag in range(0, MAX_LAG_FRAMES + 1):
        s = system.window(a - lag, b - lag)
        if len(s) != len(m):
            continue
        if s.std() < 1.0 or (s > ACTIVE_DB).mean() < 0.3:
            continue  # el sistema no suena: no puede ser eco
        c = float(np.corrcoef(m, s)[0, 1])
        if c > best:
            best = c
    return best


def is_audio_echo(mic: TrackEnvelope | None, system: TrackEnvelope | None, seg: dict) -> bool:
    if mic is None or system is None:
        return False
    return echo_score(mic, system, seg["start"], seg["end"]) >= ECHO_CORR
