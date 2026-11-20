"""Separar las voces de la otra parte ("Participantes" → Persona 1, Persona 2…).

1. Por cada frase de la pista del sistema se calcula una *huella de voz*
   (embedding, modelo WeSpeaker local) y se guarda por bloque:
   work/<pista>.emb.npz. Así funciona con grabación por bloques: cada bloque
   se procesa una vez.
2. Al unir la transcripción se agrupan TODAS las huellas de la sesión a la vez
   (agrupamiento jerárquico por similitud), de modo que la misma voz conserva
   su número toda la reunión.
3. Frases muy cortas (sin huella fiable) heredan la voz de la frase vecina.
"""

from __future__ import annotations

import logging
import wave
from pathlib import Path

import numpy as np

from ..config import Config
from ..session import Session, base_name
from ..util import read_json
from .audio import usable_tracks

log = logging.getLogger("recorder")

DIARIZE_TRACKS = {"system", "mixed"}
SR = 16000
MIN_EMBED_S = 1.0       # frases más cortas no dan una huella fiable
MAX_EMBED_S = 12.0      # suficiente para identificar; acota el cálculo
EDGE_KEEP = 1.0         # fracción de la frase usada (probado: recortar bordes empeora)


def enabled(cfg: Config) -> bool:
    return cfg.speakers.enabled and cfg.speakers.model.is_file()


_extractor = None


def _get_extractor(cfg: Config):
    global _extractor
    if _extractor is None:
        import sherpa_onnx
        c = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(cfg.speakers.model),
                                                        num_threads=cfg.whisper.threads)
        _extractor = sherpa_onnx.SpeakerEmbeddingExtractor(c)
    return _extractor


def _read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def voiced(x: np.ndarray, frame: int = 320, below_peak_db: float = 30.0) -> np.ndarray:
    """Sólo las tramas con voz (descarta silencios que contaminan la huella)."""
    n = len(x) // frame
    if n == 0:
        return x
    f = x[: n * frame].reshape(n, frame)
    db = 20 * np.log10(np.sqrt((f ** 2).mean(axis=1)) + 1e-6)
    keep = db >= db.max() - below_peak_db
    return f[keep].reshape(-1)


def embed_track(cfg: Config, s: Session, track: str) -> Path:
    """Huellas de voz de las frases de una pista (tiempos locales del bloque)."""
    out = s.work / f"{track}.emb.npz"
    segs = read_json(s.segments(track))["segments"]
    audio = _read_wav(s.wav16k(track))
    ex = _get_extractor(cfg)
    idx, embs = [], []
    for i, seg in enumerate(segs):
        dur = seg["end"] - seg["start"]
        if dur < MIN_EMBED_S:
            continue
        # sólo el centro de la frase: los bordes suelen traer audio de la frase vecina
        mid = (seg["start"] + seg["end"]) / 2
        half = max(min(dur * EDGE_KEEP, MAX_EMBED_S), MIN_EMBED_S) / 2
        a, b = int((mid - half) * SR), int((mid + half) * SR)
        chunk = voiced(audio[max(a, 0): min(b, len(audio))])
        if len(chunk) < SR * MIN_EMBED_S:
            continue
        st = ex.create_stream()
        st.accept_waveform(sample_rate=SR, waveform=chunk)
        st.input_finished()
        if not ex.is_ready(st):
            continue
        embs.append(np.asarray(ex.compute(st), dtype=np.float32))
        idx.append(i)
    tmp = out.with_suffix(".tmp.npz")
    # Un bloque puede no tener ninguna frase con huella (silencio o sólo "Sí."):
    # se guarda vacío y el resto de la sesión sigue igual.
    emb = np.stack(embs).astype(np.float32) if embs else np.zeros((0, 0), dtype=np.float32)
    np.savez(tmp, idx=np.asarray(idx, dtype=np.int32), emb=emb)
    tmp.replace(out)
    return out


class Speakers:
    """Paso del pipeline: huellas de voz por bloque (entre transcribir y unir)."""

    name = "speakers"

    def _targets(self, s: Session):
        return [t for t in usable_tracks(s) if base_name(t.name) in DIARIZE_TRACKS]

    def is_done(self, s: Session, cfg: Config) -> bool:
        if not enabled(cfg):
            return True
        return all((s.work / f"{t.name}.emb.npz").is_file() for t in self._targets(s))

    def run(self, s: Session, cfg: Config) -> None:
        for t in self._targets(s):
            if not (s.work / f"{t.name}.emb.npz").is_file():
                embed_track(cfg, s, t.name)


# ---------------------------------------------------------------- agrupamiento


def cluster(embs: np.ndarray, threshold: float) -> np.ndarray:
    """Agrupamiento jerárquico (enlace promedio, distancia coseno)."""
    from scipy.cluster.hierarchy import fcluster, linkage

    if len(embs) < 2:
        return np.zeros(len(embs), dtype=int)
    x = embs / (np.linalg.norm(embs, axis=1, keepdims=True) + 1e-9)
    z = linkage(x, method="average", metric="cosine")
    return fcluster(z, t=threshold, criterion="distance") - 1


def assign_speakers(cfg: Config, s: Session, tracks: dict[str, list[dict]]) -> int:
    """Asigna "Persona N" a los segmentos de las pistas a separar (in place).

    `tracks`: nombre de pista → segmentos con tiempos GLOBALES, en el mismo
    orden que en <pista>.segments.json. Devuelve el nº de voces detectadas.
    """
    if not enabled(cfg):
        return 0
    refs: list[tuple[str, int]] = []
    embs: list[np.ndarray] = []
    for name in tracks:
        if base_name(name) not in DIARIZE_TRACKS:
            continue
        f = s.work / f"{name}.emb.npz"
        if not f.is_file():
            continue
        data = np.load(f)
        for i, e in zip(data["idx"], data["emb"]):
            if i < len(tracks[name]):
                refs.append((name, int(i)))
                embs.append(e)
    if len(embs) < 2:
        return 1 if embs else 0

    labels = cluster(np.stack(embs), cfg.speakers.threshold)

    # Voces con muy poca presencia suelen ser ruido del agrupamiento: se
    # reasignan al grupo más parecido.
    dur = {}
    for (name, i), lab in zip(refs, labels):
        seg = tracks[name][i]
        dur[lab] = dur.get(lab, 0.0) + (seg["end"] - seg["start"])
    total = sum(dur.values()) or 1
    big = [k for k, d in dur.items() if d / total >= cfg.speakers.min_share]
    if not big:
        big = [max(dur, key=dur.get)]
    x = np.stack(embs)
    x = x / (np.linalg.norm(x, axis=1, keepdims=True) + 1e-9)
    centroids = {k: x[labels == k].mean(axis=0) for k in big}
    for n, lab in enumerate(labels):
        if lab not in centroids:
            labels[n] = max(centroids, key=lambda k: float(x[n] @ centroids[k]))

    # Numerar por orden de aparición: la primera voz que habla es "Persona 1".
    first = {}
    for (name, i), lab in zip(refs, labels):
        first[lab] = min(first.get(lab, float("inf")), tracks[name][i]["start"])
    order = {lab: k + 1 for k, lab in enumerate(sorted(first, key=first.get))}
    n_speakers = len(order)
    if n_speakers <= 1:
        return n_speakers  # una sola voz: se deja "Participantes"

    for (name, i), lab in zip(refs, labels):
        tracks[name][i]["speaker"] = f"Persona {order[lab]}"

    # Frases sin huella (cortas: "Sí.", "De acuerdo."): heredan la voz de una vecina.
    # Su hora de FIN es fiable (la de inicio a veces viene adelantada), así que
    # se prefiere la frase que empieza justo cuando ésta termina: suele ser la
    # continuación de la misma persona. Si no hay, la más cercana en el tiempo.
    labeled = sorted(((x["start"], x["end"], x["speaker"]) for n, segs in tracks.items()
                      if base_name(n) in DIARIZE_TRACKS for x in segs if "speaker" in x))
    if labeled:
        for name, segs in tracks.items():
            if base_name(name) not in DIARIZE_TRACKS:
                continue
            for seg in segs:
                if "speaker" in seg:
                    continue
                following = [l for l in labeled if seg["end"] - 0.3 <= l[0] <= seg["end"] + 1.0]
                if following:
                    seg["speaker"] = following[0][2]
                else:
                    def gap(l):
                        return max(l[0] - seg["end"], seg["start"] - l[1], 0)
                    seg["speaker"] = min(labeled, key=gap)[2]
    return n_speakers
