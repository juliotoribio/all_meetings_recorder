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

import json

import logging
import re
import shutil
import unicodedata
from pathlib import Path

from ..config import Config
from ..session import Session, base_name
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


def _utf8(s: str) -> str:
    """Rehace las letras que whisper partió entre dos tokens (p. ej. «é» = C3 + A9)."""
    return s.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def parse_whisper_json(path: Path, offset_s: float = 0.0, vad: VadMap | None = None) -> list[dict]:
    # Con -ojf cada token lleva su texto, y whisper puede cortar una letra de
    # varios bytes entre dos tokens: el JSON no es UTF-8 válido. Se leen los
    # bytes sueltos tal cual y se recomponen al unir los tokens.
    data = json.loads(path.read_bytes().decode("utf-8", "surrogateescape"))
    out: list[dict] = []
    for seg in data.get("transcription", []):
        for p in _split_segment(seg, vad):
            p["text"] = _utf8(p["text"])
            if "words" in p:
                p["words"] = [[a, b, _utf8(w)] for a, b, w in p["words"]]
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


def pick_model(cfg: Config, quality: str = "max") -> Path:
    """Modelo según la calidad elegida; si falta, el otro que haya."""
    w = cfg.whisper
    order = [w.fast_model, w.model] if quality == "fast" else [w.model, w.fast_model]
    for m in order:
        if m and m.is_file():
            return m
    raise PermanentError(f"no hay modelo de whisper: descarga uno en Configuración ({w.model.name} o {w.fast_model.name})")


def _whisper_args(cfg: Config, language: str, model: Path, vad: bool = True, audio_ctx: int = 0) -> list[str]:
    w = cfg.whisper
    cmd = [str(w.bin), "-m", str(model), "-l", language, "-t", str(w.threads), "-mc", "0", "-ojf", "-np"]
    if audio_ctx:
        cmd += ["-ac", str(audio_ctx)]
    if vad and _vad_enabled(cfg):
        cmd += ["--vad", "-vm", str(w.vad_model), *vad_args(cfg)]
    elif vad:
        log.warning("modelo VAD no encontrado (%s): se transcribe sin VAD", w.vad_model)
    prompt = glossary_prompt(cfg, language)
    if prompt:
        cmd += ["--prompt", prompt]
    return cmd


def _whisper(cfg: Config, wav: Path, out_prefix: Path, language: str, timeout: float,
             model: Path | None = None) -> Path:
    model = model or pick_model(cfg)
    run([*_whisper_args(cfg, language, model), "-f", str(wav), "-of", str(out_prefix)], timeout=timeout)
    out = Path(f"{out_prefix}.json")  # whisper añade ".json" al prefijo tal cual
    if not out.is_file():
        raise StepError(f"whisper no generó {out.name}")
    return out


def _whisper_many(cfg: Config, wavs: list[Path], language: str, timeout: float, model: Path,
                  audio_ctx: int = 0) -> list[Path]:
    """Varios archivos en una sola llamada: el modelo se carga una vez y, con
    "auto", cada archivo detecta su propio idioma. Salida: <archivo>.json.
    Sin VAD: los trozos ya son voz (turnos sin silencios largos)."""
    cmd = _whisper_args(cfg, language, model, vad=False, audio_ctx=audio_ctx)
    for w in wavs:
        cmd += ["-f", str(w)]
    run(cmd, timeout=timeout)
    outs = [w.with_name(w.name + ".json") for w in wavs]
    missing = [o.name for o in outs if not o.is_file()]
    if missing:
        raise StepError(f"whisper no generó {', '.join(missing[:3])}")
    return outs


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


def turn_cuts(turns: list[tuple[float, float, int]], duration_s: float, min_s: float = 1.0,
              min_gap: float = 0.15) -> list[float]:
    """Cortes donde cambia la voz (ahí suele cambiar también el idioma).

    Sólo se corta en mitad de un silencio real (≥ `min_gap`) entre un turno
    y el de otra voz: si pyannote cambia de voz sin pausa suele ser un error
    suyo a mitad de frase, y cortar ahí partiría la frase. Los trozos de
    menos de `min_s` se unen al anterior (un "ok" suelto no basta para
    detectar el idioma).
    """
    ts = sorted(turns)
    if not ts:
        return []
    cuts: list[float] = []
    spk, end = ts[0][2], ts[0][1]
    for a, b, k in ts[1:]:
        if k != spk:
            cut = (end + a) / 2
            if (a - end >= min_gap and min_s <= cut <= duration_s - min_s
                    and (not cuts or cut - cuts[-1] >= min_s)):
                cuts.append(round(cut, 3))
            spk, end = k, b
        else:
            end = max(end, b)
    return cuts


def _write_pieces(wav: Path, pdir: Path, bounds: list[float]) -> list[Path]:
    """Trozos exactos (por muestra) del WAV de 16 kHz, entre cortes consecutivos."""
    return _write_pieces_at(wav, pdir, list(zip(bounds, bounds[1:])))


def _write_pieces_at(wav: Path, pdir: Path, ranges: list[tuple[float, float]]) -> list[Path]:
    """Trozos exactos (por muestra) del WAV de 16 kHz para cada rango (inicio, fin)."""
    import wave
    out: list[Path] = []
    with wave.open(str(wav), "rb") as r:
        sr, n = r.getframerate(), r.getnframes()
        params = r.getparams()
        for i, (a, b) in enumerate(ranges):
            fa, fb = int(round(a * sr)), min(int(round(b * sr)), n)
            r.setpos(fa)
            frames = r.readframes(max(fb - fa, 0))
            p = pdir / f"p{i:04d}.wav"
            with wave.open(str(p), "wb") as w:
                w.setparams(params)
                w.writeframes(frames)
            out.append(p)
    return out


def _transcribe_pieces(cfg: Config, wav: Path, work: Path, stem: str, language: str, duration_s: float,
                       cuts: list[float], vad_map, model: Path) -> list[dict]:
    pdir = work / f"{stem}.pieces"
    shutil.rmtree(pdir, ignore_errors=True)
    pdir.mkdir(parents=True)
    bounds = [0.0, *cuts, duration_s]
    segs: list[dict] = []
    for a, b, piece in zip(bounds, bounds[1:], _write_pieces(wav, pdir, bounds)):
        raw = _whisper(cfg, piece, piece.with_suffix(""), language, _timeout(cfg, b - a), model)
        segs += parse_whisper_json(raw, offset_s=a, vad=vad_map(piece))
    return segs


LONG_SILENCE_S = 2.0
SENTENCE_GAP_S = 0.1  # hueco entre intervalos VAD (ya con 0,2 s de margen a cada lado): pausa real ≳ 0,5 s


def silence_cuts(intervals: list[tuple[float, float]], min_gap: float = LONG_SILENCE_S) -> list[float]:
    """Mitad de cada silencio largo entre intervalos de voz."""
    return [round((a[1] + b[0]) / 2, 3) for a, b in zip(intervals, intervals[1:]) if b[0] - a[1] >= min_gap]


def audio_ctx_for(seconds: float, floor: int = 512) -> int:
    """Contexto del codificador justo para el trozo (+2 s de margen).

    whisper procesa siempre ventanas de 30 s; con trozos cortos, reducir el
    contexto lo hace ~2× más rápido. Nunca menos que el trozo: se perdería
    el final.
    """
    need = (seconds + 2.0) / 30.0 * 1500
    for ctx in (512, 768, 1024):
        if ctx >= floor and need <= ctx:
            return ctx
    return 0  # completo (1500)


def _has_speech(a: float, b: float, intervals: list[tuple[float, float]], min_s: float = 0.2) -> bool:
    return sum(max(0.0, min(b, y) - max(a, x)) for x, y in intervals) >= min_s


def _transcribe_turns(cfg: Config, wav: Path, work: Path, stem: str, language: str, duration_s: float,
                      turns: list[tuple[float, float, int]], model: Path) -> list[dict]:
    """Un trozo por turno de voz (cada uno detecta su idioma), en pocas llamadas a whisper."""
    intervals = vad_intervals(cfg, wav) if _vad_enabled(cfg) else []
    # también en cada pausa entre frases: pyannote a veces junta a dos personas
    # y, si el trozo mezcla idiomas, whisper se salta las frases del otro
    pauses = [c for c in silence_cuts(intervals, SENTENCE_GAP_S)]
    cuts = sorted(set(turn_cuts(turns, duration_s)) | set(pauses))
    cuts = [c for i, c in enumerate(cuts) if i == 0 or c - cuts[i - 1] >= 1.0]
    bounds = [0.0, *[c for c in cuts if 0 < c < duration_s], duration_s]
    pdir = work / f"{stem}.pieces"
    shutil.rmtree(pdir, ignore_errors=True)
    pdir.mkdir(parents=True)
    keep = [(a, b) for a, b in zip(bounds, bounds[1:])
            if b - a >= 0.3 and (not intervals or _has_speech(a, b, intervals))]
    if not keep:
        return []
    starts = [a for a, _ in keep]
    pieces = _write_pieces_at(wav, pdir, keep)
    log.info("idioma automático: %d trozos por turno de voz", len(pieces))
    groups: dict[int, list[int]] = {}
    for i, (a, b) in enumerate(keep):
        # turbo repite texto y desordena tiempos con el contexto reducido: sólo large-v3
        # medido: turbo con 512 repite texto y desordena tiempos; con 1024 va bien
        floor = 1024 if "turbo" in model.name else 512
        groups.setdefault(audio_ctx_for(b - a, floor), []).append(i)
    raws: dict[int, Path] = {}
    for ctx, idx in sorted(groups.items()):
        secs = sum(keep[i][1] - keep[i][0] for i in idx)
        outs = _whisper_many(cfg, [pieces[i] for i in idx], language,
                             _timeout(cfg, secs) + 2 * len(idx), model, audio_ctx=ctx)
        raws.update(zip(idx, outs))
    segs: list[dict] = []
    for i in range(len(pieces)):
        segs += parse_whisper_json(raws[i], offset_s=starts[i])
    return segs


def transcribe_wav(cfg: Config, wav: Path, work: Path, stem: str, language: str, duration_s: float,
                   model: Path | None = None,
                   turns: list[tuple[float, float, int]] | None = None) -> list[dict]:
    """Transcribe una pista completa; si falla, por bloques."""
    model = model or pick_model(cfg)

    def vad_map(path: Path) -> VadMap | None:
        return VadMap(vad_intervals(cfg, path)) if _vad_enabled(cfg) else None

    if language == "auto":
        if turns:  # un trozo por turno de voz: cada uno detecta su idioma
            return _transcribe_turns(cfg, wav, work, stem, language, duration_s, turns, model)
        intervals = vad_intervals(cfg, wav) if _vad_enabled(cfg) else []
        cuts = cut_points(intervals, duration_s)
        if cuts:
            log.info("idioma automático: %d tramos (cada uno detecta su idioma)", len(cuts) + 1)
            return _transcribe_pieces(cfg, wav, work, stem, language, duration_s, cuts, vad_map, model)

    try:
        raw = _whisper(cfg, wav, work / f"{stem}.whisper", language, _timeout(cfg, duration_s), model)
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
        raw = _whisper(cfg, chunk, chunk.with_suffix(""), language, _timeout(cfg, chunk_s), model)
        segs += parse_whisper_json(raw, offset_s=i * chunk_s, vad=vad_map(chunk))
    return segs


def _turns_for_language(cfg: Config, s: Session, track: str):
    """Turnos de voz (pyannote) para cortar por idioma; None si no aplica."""
    from . import speakers as sp
    if not (sp.enabled(cfg) and sp.segmentation_enabled(cfg)):
        return None
    if base_name(track) not in sp.DIARIZE_TRACKS:
        return None
    try:
        return sp.track_turns(cfg, s, track) or None
    except Exception:  # noqa: BLE001  (sin turnos: tramos por silencios, como antes)
        log.warning("[%s] pyannote falló en %s; idioma por tramos largos", s.id, track, exc_info=True)
        return None


class Transcribe:
    name = "transcribe"

    def is_done(self, s: Session, cfg: Config) -> bool:
        return all(s.segments(t.name).is_file() for t in usable_tracks(s))

    def run(self, s: Session, cfg: Config) -> None:
        lang = s.language(cfg.whisper.language)
        model = pick_model(cfg, s.manifest().get("quality") or cfg.whisper.quality)
        for t in usable_tracks(s):
            out = s.segments(t.name)
            if out.is_file():
                continue
            dur = track_duration(s, t.name)
            log.info("[%s] transcribiendo %s (%.0fs de audio, %s)", s.id, t.name, dur, model.name)
            turns = _turns_for_language(cfg, s, t.name) if lang == "auto" else None
            segs = transcribe_wav(cfg, s.wav16k(t.name), s.work, t.name, lang, dur, model, turns)
            segs = clean_segments(segs)
            atomic_write_json(out, {"track": t.name, "language": lang, "model": model.name, "segments": segs})
            log.info("[%s] %s: %d segmentos", s.id, t.name, len(segs))
