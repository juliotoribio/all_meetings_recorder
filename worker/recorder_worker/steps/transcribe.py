"""Paso 3: transcribir cada pista con whisper.cpp (whisper-cli).

- VAD (Silero) para saltar silencios: más rápido y menos alucinaciones.
- `-mc 0` evita bucles de repetición en audios largos.
- Glosario como prompt inicial para nombres propios.
- Si la pista completa falla (crash/timeout) se reintenta por bloques.
- Idioma "auto": whisper detecta el idioma una sola vez (primeros 30 s), así
  que la pista se corta en tramos de ~3 min por los silencios y cada tramo se
  detecta por separado (reuniones que cambian de español a inglés).
"""

from __future__ import annotations

import logging
import re
import shutil
import unicodedata
from pathlib import Path

from ..config import Config
from ..session import Session
from ..util import PermanentError, StepError, atomic_write_json, read_json, run
from .audio import track_duration, usable_tracks

log = logging.getLogger("recorder")

# Frases que Whisper "inventa" en silencios/música (comparación normalizada).
HALLUCINATIONS = [
    "subtitulos realizados por la comunidad de amara.org",
    "subtitulos por la comunidad de amara.org",
    "subtitulado por la comunidad de amara.org",
    "gracias por ver el video",
    "gracias por ver",
    "gracias por vernos",
    "suscribete al canal",
    "no olvides suscribirte",
    "thanks for watching",
    "thank you for watching",
    "please subscribe",
    "musica",
    "[musica]",
    "[music]",
    "[blank_audio]",
    "(musica)",
]


def _norm(text: str) -> str:
    t = unicodedata.normalize("NFKD", text.lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.sub(r"[^\w\[\]().\s]", "", t).strip(" .")


def is_hallucination(text: str) -> bool:
    n = _norm(text)
    if not n:
        return True
    if n.startswith("[") and n.endswith("]"):  # [BLANK_AUDIO], [Música], etc.
        return True
    # coincidencia exacta: "Gracias por ver el informe…" es habla real
    return n in HALLUCINATIONS


def glossary_prompt(cfg: Config, language: str = "es") -> str | None:
    f = cfg.whisper.glossary_file
    if not f or not f.is_file():
        return None
    terms = [ln.strip() for ln in f.read_text(encoding="utf-8").splitlines()
             if ln.strip() and not ln.lstrip().startswith("#")]
    if not terms:
        return None
    # En español se presenta como glosario; en otro idioma o "auto" sólo la
    # lista, para no empujar a whisper a escribir en español.
    prompt = ("Glosario: " if language == "es" else "") + ", ".join(terms) + "."
    return prompt[:600]  # whisper admite ~224 tokens de prompt


# ---------------------------------------------------------------- VAD → tiempo real

# whisper.cpp añade --vad-samples-overlap (0.10 s) a cada lado de cada intervalo
# de voz al concatenarlos. Ajustado empíricamente contra los inicios de segmento
# que calcula whisper: con 0.20 el error medio es ~0.03 s (con 0.10 era >10 s).
VAD_OVERLAP_S = 0.20


class VadMap:
    """Convierte tiempos de la línea "sin silencios" (tokens con VAD) a tiempo real.

    whisper.cpp concatena los intervalos de voz, cada uno seguido de
    VAD_OVERLAP_S; los tokens quedan en esa línea comprimida.
    """

    def __init__(self, intervals: list[tuple[float, float]]):
        self.table: list[tuple[float, float, float]] = []  # (inicio_comprimido, inicio_real, duración)
        c = 0.0
        for start, end in intervals:
            self.table.append((c, start, end - start))
            c += (end - start) + VAD_OVERLAP_S

    def __bool__(self) -> bool:
        return bool(self.table)

    def index_of(self, compressed_s: float) -> int:
        return self._index(compressed_s)

    def _index(self, compressed_s: float) -> int:
        lo, hi = 0, len(self.table) - 1
        while lo < hi:  # último intervalo con inicio_comprimido <= t
            mid = (lo + hi + 1) // 2
            if self.table[mid][0] <= compressed_s:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def real(self, compressed_s: float, snap_forward_s: float = 0.0) -> float:
        """`snap_forward_s`: si el siguiente intervalo de voz empieza a menos de
        esa distancia, el instante pertenece a él (no a la cola del anterior)."""
        i = self._index(compressed_s)
        if snap_forward_s and i + 1 < len(self.table) and self.table[i + 1][0] - compressed_s <= snap_forward_s:
            return self.table[i + 1][1]
        c0, r0, dur = self.table[i]
        return r0 + min(max(compressed_s - c0, 0.0), dur + VAD_OVERLAP_S)

    def real_start(self, tok_from: float, tok_to: float) -> float:
        """Inicio real de una palabra. En whisper el inicio de un token es poco
        fiable (se pega al final del anterior, a veces en el intervalo de voz
        previo); el final sí es preciso. Se ancla en el final y se resta la
        duración sin cruzar el inicio de su intervalo de voz."""
        i = self._index(tok_to)
        if i + 1 < len(self.table) and self.table[i + 1][0] - tok_to <= 0.3:
            return self.table[i + 1][1]  # palabra que en realidad abre el intervalo siguiente
        c0, r0, dur = self.table[i]
        end_real = r0 + min(max(tok_to - c0, 0.0), dur + VAD_OVERLAP_S)
        return max(r0, end_real - max(tok_to - tok_from, 0.0))


def vad_args(cfg: Config) -> list[str]:
    """Mismos parámetros para whisper-cli y para el mapa de tiempos (deben coincidir)."""
    return ["-vp", str(cfg.whisper.vad_pad_ms), "-vsd", str(cfg.whisper.vad_min_silence_ms)]


def vad_intervals(cfg: Config, wav: Path) -> list[tuple[float, float]]:
    """Intervalos de voz (s) con los mismos parámetros que usa whisper-cli."""
    tool = cfg.whisper.bin.parent / "whisper-vad-speech-segments"
    if not (tool.is_file() and cfg.whisper.vad_model and cfg.whisper.vad_model.is_file()):
        return []
    try:
        res = run([str(tool), "-f", str(wav), "-vm", str(cfg.whisper.vad_model), "-t", str(cfg.whisper.threads),
                   *vad_args(cfg)], timeout=600)
    except StepError as e:
        log.warning("no se pudieron obtener intervalos VAD (%s); timestamps aproximados", e)
        return []
    # stdout: "Speech segment 0: start = 698.00, end = 765.00"  (centésimas de segundo).
    # Ojo: stderr repite los intervalos en otro formato; sólo se lee stdout.
    num = r"([\d.]+(?:[eE][+-]?\d+)?)"
    found = re.findall(rf"Speech segment \d+: start = {num}, end = {num}", res.stdout)
    intervals = [(float(a) / 100, float(b) / 100) for a, b in found]
    m = re.search(r"Detected (\d+) speech segments", res.stdout)
    if m and int(m.group(1)) != len(intervals):
        log.warning("salida VAD inesperada (%s vs %d); timestamps aproximados", m.group(1), len(intervals))
        return []
    if any(b < a for a, b in intervals) or any(intervals[i + 1][0] < intervals[i][0] for i in range(len(intervals) - 1)):
        log.warning("intervalos VAD no monótonos; timestamps aproximados")
        return []
    return intervals


# ---------------------------------------------------------------- parseo


def _split_segment(seg: dict, vad: VadMap | None = None) -> list[dict]:
    """Parte un segmento de whisper en frases usando timestamps de tokens.

    Con VAD, los offsets de tokens están en la línea de tiempo sin silencios:
    se convierten con el mapa VAD (exacto) o, si no hay, proporcionalmente
    sobre el rango real del segmento (aproximado).
    """
    start_ms, end_ms = seg["offsets"]["from"], seg["offsets"]["to"]
    toks = [t for t in seg.get("tokens", []) if not t["text"].startswith("[_")]
    if not toks:
        return [{"start": start_ms / 1000, "end": end_ms / 1000, "text": seg["text"].strip()}]
    t0, t1 = toks[0]["offsets"]["from"], toks[-1]["offsets"]["to"]
    span = max(t1 - t0, 1)

    def real(ms: int) -> float:
        if vad:  # sin recortar a los bordes del segmento: con VAD no son fiables
            return vad.real(ms / 1000)
        return (start_ms + (ms - t0) / span * (end_ms - start_ms)) / 1000

    def tok_start(t: dict) -> float:
        o = t["offsets"]
        return vad.real_start(o["from"] / 1000, o["to"] / 1000) if vad else real(o["from"])

    def words(tokens: list[dict]) -> list[list]:
        """[inicio, fin, palabra] (para cortar la frase donde cambia la voz)."""
        out: list[list] = []
        for t in tokens:
            if t["text"].startswith(" ") or not out:
                out.append([tok_start(t), real(t["offsets"]["to"]), t["text"].strip()])
            else:
                out[-1][1] = real(t["offsets"]["to"])
                out[-1][2] += t["text"]
        return [w for w in out if w[2]]

    def piece(tokens: list[dict], text: str) -> dict:
        a = tok_start(tokens[0])
        b = real(tokens[-1]["offsets"]["to"])
        return {"start": a, "end": max(a, b), "text": text, "words": words(tokens)}

    pieces: list[dict] = []
    buf: list[dict] = []
    for i, tok in enumerate(toks):
        buf.append(tok)
        nxt = toks[i + 1]["text"] if i + 1 < len(toks) else " "
        ends_sentence = tok["text"].rstrip().endswith((".", "?", "!", "…"))
        if ends_sentence and nxt.startswith(" "):
            text = "".join(t["text"] for t in buf).strip()
            if len(text.split()) >= 3 or not pieces:
                pieces.append(piece(buf, text))
                buf = []
    if buf:
        text = "".join(t["text"] for t in buf).strip()
        if pieces and len(text.split()) < 3:
            pieces[-1]["text"] += " " + text
            pieces[-1]["end"] = max(pieces[-1]["end"], real(buf[-1]["offsets"]["to"]))
            pieces[-1]["words"] += words(buf)
        elif text:
            pieces.append(piece(buf, text))
    # Sin mapa VAD, el primer/último trozo hereda los bordes del segmento.
    # (Con mapa no: whisper estira los bordes del segmento sobre los silencios.)
    if pieces and not vad:
        pieces[0]["start"] = start_ms / 1000
        pieces[-1]["end"] = end_ms / 1000
    return pieces


def parse_whisper_json(path: Path, offset_s: float = 0.0, vad: VadMap | None = None) -> list[dict]:
    data = read_json(path)
    out: list[dict] = []
    for seg in data.get("transcription", []):
        for p in _split_segment(seg, vad):
            p["start"] = round(p["start"] + offset_s, 2)
            p["end"] = round(p["end"] + offset_s, 2)
            if "words" in p:
                p["words"] = [[round(a + offset_s, 2), round(b + offset_s, 2), w] for a, b, w in p["words"]]
            out.append(p)
    return out


def clean_segments(segs: list[dict], max_repeats: int = 2) -> list[dict]:
    """Quita alucinaciones conocidas y bucles de repetición consecutiva."""
    out: list[dict] = []
    run_len = 0
    for s in segs:
        if is_hallucination(s["text"]):
            continue
        if out and _norm(out[-1]["text"]) == _norm(s["text"]):
            run_len += 1
            if run_len >= max_repeats:
                continue
        else:
            run_len = 0
        out.append(s)
    return out


# ---------------------------------------------------------------- whisper


def _vad_enabled(cfg: Config) -> bool:
    return bool(cfg.whisper.vad_model and cfg.whisper.vad_model.is_file())


def _whisper(cfg: Config, wav: Path, out_prefix: Path, language: str, timeout: float) -> Path:
    w = cfg.whisper
    if not w.model.is_file():
        raise PermanentError(f"no existe el modelo de whisper: {w.model}")
    cmd = [str(w.bin), "-m", str(w.model), "-f", str(wav), "-l", language, "-t", str(w.threads),
           "-mc", "0", "-ojf", "-of", str(out_prefix), "-np"]
    if _vad_enabled(cfg):
        cmd += ["--vad", "-vm", str(w.vad_model), *vad_args(cfg)]
    else:
        log.warning("modelo VAD no encontrado (%s): se transcribe sin VAD", w.vad_model)
    prompt = glossary_prompt(cfg, language)
    if prompt:
        cmd += ["--prompt", prompt]
    run(cmd, timeout=timeout)
    out = Path(f"{out_prefix}.json")  # whisper añade ".json" al prefijo tal cual
    if not out.is_file():
        raise StepError(f"whisper no generó {out.name}")
    return out


def _timeout(cfg: Config, seconds: float) -> float:
    return cfg.whisper.timeout_base_s + seconds * cfg.whisper.timeout_factor


AUTO_PIECE_S = 180.0  # tamaño orientativo de cada tramo con idioma "auto"


def cut_points(intervals: list[tuple[float, float]], duration_s: float, target_s: float | None = None) -> list[float]:
    """Puntos de corte cada ~target_s segundos, en mitad de un silencio.

    Si no hay silencio en ~1,5 × target_s (o no hay VAD) se corta igualmente.
    """
    target_s = target_s or AUTO_PIECE_S
    if duration_s <= target_s * 1.5:
        return []
    gaps = [(a[1] + b[0]) / 2 for a, b in zip(intervals, intervals[1:]) if b[0] > a[1]]
    cuts: list[float] = []
    last = 0.0
    while duration_s - last > target_s * 1.5:
        ok = [g for g in gaps if last + target_s <= g <= last + target_s * 1.5]
        cut = ok[0] if ok else last + target_s
        cuts.append(cut)
        last = cut
    return cuts


def _transcribe_pieces(cfg: Config, wav: Path, work: Path, stem: str, language: str, duration_s: float,
                       cuts: list[float], vad_map) -> list[dict]:
    pdir = work / f"{stem}.pieces"
    shutil.rmtree(pdir, ignore_errors=True)
    pdir.mkdir(parents=True)
    bounds = [0.0, *cuts, duration_s]
    segs: list[dict] = []
    for i, (a, b) in enumerate(zip(bounds, bounds[1:])):
        piece = pdir / f"p{i:04d}.wav"
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(wav), "-ss", f"{a:.2f}",
             "-t", f"{b - a:.2f}", "-c", "copy", str(piece)], timeout=600)
        raw = _whisper(cfg, piece, piece.with_suffix(""), language, _timeout(cfg, b - a))
        segs += parse_whisper_json(raw, offset_s=a, vad=vad_map(piece))
    return segs


def transcribe_wav(cfg: Config, wav: Path, work: Path, stem: str, language: str, duration_s: float) -> list[dict]:
    """Transcribe una pista completa; si falla, por bloques."""

    def vad_map(path: Path) -> VadMap | None:
        return VadMap(vad_intervals(cfg, path)) if _vad_enabled(cfg) else None

    if language == "auto":
        intervals = vad_intervals(cfg, wav) if _vad_enabled(cfg) else []
        cuts = cut_points(intervals, duration_s)
        if cuts:
            log.info("idioma automático: %d tramos (cada uno detecta su idioma)", len(cuts) + 1)
            return _transcribe_pieces(cfg, wav, work, stem, language, duration_s, cuts, vad_map)

    try:
        raw = _whisper(cfg, wav, work / f"{stem}.whisper", language, _timeout(cfg, duration_s))
        return parse_whisper_json(raw, vad=vad_map(wav))
    except PermanentError:
        raise
    except StepError as e:
        log.warning("whisper falló con la pista completa (%s); reintentando por bloques", e)

    chunk_s = cfg.whisper.chunk_minutes * 60
    cdir = work / f"{stem}.chunks"
    shutil.rmtree(cdir, ignore_errors=True)
    cdir.mkdir(parents=True)
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(wav), "-f", "segment",
         "-segment_time", str(chunk_s), "-c", "copy", str(cdir / "c%04d.wav")], timeout=600)
    segs: list[dict] = []
    for i, chunk in enumerate(sorted(cdir.glob("c*.wav"))):
        raw = _whisper(cfg, chunk, chunk.with_suffix(""), language, _timeout(cfg, chunk_s))
        segs += parse_whisper_json(raw, offset_s=i * chunk_s, vad=vad_map(chunk))
    return segs


class Transcribe:
    name = "transcribe"

    def is_done(self, s: Session, cfg: Config) -> bool:
        return all(s.segments(t.name).is_file() for t in usable_tracks(s))

    def run(self, s: Session, cfg: Config) -> None:
        lang = s.language(cfg.whisper.language)
        for t in usable_tracks(s):
            out = s.segments(t.name)
            if out.is_file():
                continue
            dur = track_duration(s, t.name)
            log.info("[%s] transcribiendo %s (%.0fs de audio)", s.id, t.name, dur)
            segs = transcribe_wav(cfg, s.wav16k(t.name), s.work, t.name, lang, dur)
            segs = clean_segments(segs)
            atomic_write_json(out, {"track": t.name, "language": lang, "segments": segs})
            log.info("[%s] %s: %d segmentos", s.id, t.name, len(segs))
