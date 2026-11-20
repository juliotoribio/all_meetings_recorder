"""Separar las voces de la otra parte ("Participantes" → Persona 1, Persona 2…).

0. Con el modelo pyannote (segmentation-3.0) se detecta en cada bloque dónde
   cambia la persona y cuándo hablan dos a la vez. Las frases de whisper se
   cortan por esos cambios usando la hora de cada palabra (work/<pista>.split.json).
1. Por cada frase de la pista del sistema se calcula una *huella de voz*
   (embedding, modelo WeSpeaker local) y se guarda por bloque:
   work/<pista>.emb.npz. Así funciona con grabación por bloques: cada bloque
   se procesa una vez.
2. Al unir la transcripción se agrupan TODAS las huellas de la sesión a la vez
   (agrupamiento jerárquico por similitud), de modo que la misma voz conserva
   su número toda la reunión.
3. Frases muy cortas (sin huella fiable) heredan la voz de la frase vecina.
4. Memoria de voces: la huella media de cada voz se guarda (work/voices.json).
   Cuando el usuario le pone nombre, en las reuniones siguientes esa voz se
   reconoce y aparece ya con su nombre.
"""

from __future__ import annotations

import json
import logging
import re
import wave
from pathlib import Path

import numpy as np

from ..config import Config
from ..session import Session, base_name
from ..util import atomic_write_json, read_json
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


# ---------------------------------------------------------------- cambios de voz (pyannote)


def segmentation_enabled(cfg: Config) -> bool:
    return bool(cfg.speakers.segmentation) and cfg.speakers.segmentation.is_file()


_diarizer = None


def _get_diarizer(cfg: Config):
    global _diarizer
    if _diarizer is None:
        import sherpa_onnx as so
        c = so.OfflineSpeakerDiarizationConfig(
            segmentation=so.OfflineSpeakerSegmentationModelConfig(
                pyannote=so.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(cfg.speakers.segmentation)),
                num_threads=cfg.whisper.threads),
            embedding=so.SpeakerEmbeddingExtractorConfig(model=str(cfg.speakers.model),
                                                         num_threads=cfg.whisper.threads),
            clustering=so.FastClusteringConfig(num_clusters=-1, threshold=cfg.speakers.threshold),
            min_duration_on=0.3, min_duration_off=0.5)
        if not c.validate():
            raise RuntimeError("configuración de pyannote no válida")
        _diarizer = so.OfflineSpeakerDiarization(c)
    return _diarizer


def speaker_turns(cfg: Config, audio: np.ndarray) -> list[tuple[float, float, int]]:
    """Turnos (inicio, fin, voz local) de un bloque; pueden solaparse."""
    if len(audio) < SR:
        return []
    res = _get_diarizer(cfg).process(audio).sort_by_start_time()
    return [(r.start, r.end, r.speaker) for r in res]


def split_by_turns(segs: list[dict], turns: list[tuple[float, float, int]],
                   min_words: int = 2, min_s: float = 0.6) -> list[dict]:
    """Corta cada frase donde cambia la voz y marca las que se pisan.

    Cada palabra va a la voz cuyo turno la cubre (si hay varias, se mantiene
    la de la palabra anterior: así un "ajá" ajeno no parte la frase). Los
    trozos de menos de `min_words` palabras y `min_s` segundos se unen al
    vecino: suelen ser imprecisión del borde del turno.
    """
    out: list[dict] = []
    for n, seg in enumerate(segs):
        words = seg.get("words") or []
        base = {k: v for k, v in seg.items() if k != "words"}
        if not words or not turns:
            out.append(base)
            continue
        labs: list[int | None] = []
        over: list[bool] = []
        for a, b, _ in words:
            mid = (a + b) / 2
            cover = [t for t in turns if t[0] - 0.05 <= mid <= t[1] + 0.05]
            if not cover:
                near = min(turns, key=lambda t: max(t[0] - mid, mid - t[1], 0))
                cover = [near] if max(near[0] - mid, mid - near[1], 0) <= 1.0 else []
            prev = labs[-1] if labs else None
            if not cover:
                labs.append(prev)
            elif any(t[2] == prev for t in cover):
                labs.append(prev)
            else:
                labs.append(max(cover, key=lambda t: t[1] - t[0])[2])
            over.append(len({t[2] for t in cover}) > 1)
        # palabras sin turno al principio: la voz de la siguiente
        first = next((l for l in labs if l is not None), None)
        labs = [first if l is None else l for l in labs]

        groups: list[list[int]] = []  # índices de palabras
        for i, lab in enumerate(labs):
            if groups and labs[groups[-1][0]] == lab:
                groups[-1].append(i)
            else:
                groups.append([i])

        def small(g: list[int]) -> bool:
            return len(g) < min_words and words[g[-1]][1] - words[g[0]][0] < min_s

        merged: list[list[int]] = []
        for g in groups:
            if merged and (small(g) or labs[g[0]] == labs[merged[-1][0]]):
                merged[-1] += g
            else:
                merged.append(g)
        if len(merged) > 1 and small(merged[0]):
            merged[1] = merged[0] + merged[1]
            merged.pop(0)

        def overlap(g: list[int]) -> bool:
            return sum(over[i] for i in g) >= max(2, 0.3 * len(g))

        if len(merged) == 1:
            if overlap(merged[0]):
                base["overlap"] = True
            out.append(base)
            continue
        for g in merged:
            piece = {"start": words[g[0]][0], "end": max(words[g[0]][0], words[g[-1]][1]),
                     "text": " ".join(words[i][2] for i in g), "src": n}
            if overlap(g):
                piece["overlap"] = True
            out.append(piece)
    return out


def split_path(s: Session, track: str) -> Path:
    return s.work / f"{track}.split.json"


def split_track(cfg: Config, s: Session, track: str) -> list[dict]:
    """Frases de la pista cortadas por cambios de voz (o tal cual si no hay pyannote)."""
    segs = read_json(s.segments(track))["segments"]
    turns: list[tuple[float, float, int]] = []
    if segmentation_enabled(cfg) and any(x.get("words") for x in segs):
        try:
            turns = speaker_turns(cfg, _read_wav(s.wav16k(track)))
        except Exception:  # noqa: BLE001  (sin cortes: se usa la frase entera)
            log.warning("[%s] pyannote falló en %s; se usan las frases enteras", s.id, track, exc_info=True)
    out = split_by_turns(segs, turns)
    atomic_write_json(split_path(s, track), {"track": track, "turns": len(turns), "segments": out})
    extra = len(out) - len(segs)
    if extra > 0 or any(x.get("overlap") for x in out):
        log.info("[%s] %s: %d cortes por cambio de voz, %d frases con voces a la vez", s.id, track,
                 max(extra, 0), sum(1 for x in out if x.get("overlap")))
    return out


def embed_track(cfg: Config, s: Session, track: str) -> Path:
    """Huellas de voz de las frases de una pista (tiempos locales del bloque)."""
    out = s.work / f"{track}.emb.npz"
    segs = split_track(cfg, s, track)
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
    if not embs:
        return 0

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
    ordered = sorted(first, key=first.get)
    n_speakers = len(ordered)
    cents = {lab: _unit(x[labels == lab].mean(axis=0)) for lab in ordered}
    label = {lab: f"Persona {k + 1}" if n_speakers > 1 else "Participantes" for k, lab in enumerate(ordered)}

    # Voces ya conocidas de otras reuniones: aparecen con su nombre, salvo que
    # el usuario ya haya nombrado esa voz en ESTA sesión.
    if cfg.speakers.remember:
        try:
            own = s.manifest().get("speaker_names") or {}
            free = [lab for lab in ordered if not own.get(label[lab])]
            for lab, nm in recall(cfg, s, {lab: cents[lab] for lab in free}).items():
                label[lab] = nm
        except Exception:  # noqa: BLE001
            log.warning("[%s] no se pudo consultar la memoria de voces", s.id, exc_info=True)
    try:
        atomic_write_json(s.work / "voices.json",
                          {label[lab]: [round(float(v), 5) for v in cents[lab]] for lab in ordered})
    except Exception:  # noqa: BLE001
        log.warning("[%s] no se pudo guardar voices.json", s.id, exc_info=True)

    if n_speakers <= 1 and label[ordered[0]] == "Participantes":
        return n_speakers  # una sola voz desconocida: se deja "Participantes"

    for (name, i), lab in zip(refs, labels):
        tracks[name][i]["speaker"] = label[lab]

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


# ---------------------------------------------------------------- memoria de voces

GENERIC = re.compile(r"^(Persona \d+|Participantes|Yo|Sala)$")


def _unit(v: np.ndarray) -> np.ndarray:
    return v / (np.linalg.norm(v) + 1e-9)


def load_profiles(cfg: Config, exclude: str | None = None) -> dict[str, np.ndarray]:
    """Huella media de cada voz con nombre, sacada de todas las sesiones."""
    acc: dict[str, list[np.ndarray]] = {}
    root = cfg.paths.sessions
    if not root.is_dir():
        return {}
    for d in root.iterdir():
        f = d / "work" / "voices.json"
        if d.name == exclude or not f.is_file():
            continue
        try:
            voices = json.loads(f.read_text())
            names = (read_json(d / "manifest.json").get("speaker_names") or {}) if (d / "manifest.json").is_file() else {}
        except Exception:  # noqa: BLE001
            continue
        for lab, emb in voices.items():
            name = (names.get(lab, lab) or "").strip()
            if not name or GENERIC.match(name):
                continue
            acc.setdefault(name, []).append(_unit(np.asarray(emb, dtype=np.float32)))
    return {n: _unit(np.mean(v, axis=0)) for n, v in acc.items()}


def recall(cfg: Config, s: Session, cents: dict) -> dict:
    """Empareja las voces de esta sesión con voces conocidas (una a una)."""
    profiles = load_profiles(cfg, exclude=s.id)
    if not profiles or not cents:
        return {}
    pairs = sorted(((float(c @ p), lab, name) for lab, c in cents.items() for name, p in profiles.items()),
                   reverse=True)
    out: dict = {}
    used: set[str] = set()
    for sim, lab, name in pairs:
        if sim < cfg.speakers.recall_threshold:
            break
        if lab in out or name in used:
            continue
        out[lab] = name
        used.add(name)
        log.info("[%s] voz reconocida: %s (similitud %.2f)", s.id, name, sim)
    return out


def rejoin(segs: list[dict]) -> list[dict]:
    """Vuelve a unir los trozos de una misma frase que acabaron con la misma voz."""
    out: list[dict] = []
    for x in segs:
        prev = out[-1] if out else None
        if (prev is not None and "src" in x and prev.get("src") == x["src"]
                and prev.get("speaker") == x.get("speaker")):
            prev["end"] = max(prev["end"], x["end"])
            prev["text"] = f"{prev['text']} {x['text']}"
            if x.get("overlap"):
                prev["overlap"] = True
        else:
            out.append(dict(x))
    for x in out:
        x.pop("src", None)
    return out
