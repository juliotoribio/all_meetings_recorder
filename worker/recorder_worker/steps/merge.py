"""Paso 4: unir pistas en una sola línea de tiempo y quitar el eco.

Eco: con altavoces, el micrófono capta a los demás. Un segmento del mic que se
solapa en el tiempo con uno del sistema y dice casi lo mismo se descarta.
"""

from __future__ import annotations

import logging

from rapidfuzz import fuzz

from ..config import Config
from ..session import Session, base_name, speaker_for
from ..util import atomic_write_json, atomic_write_text, fmt_ts, read_json
from .audio import usable_tracks
from .echo import TrackEnvelope, envelope, is_audio_echo
from .speakers import assign_speakers

log = logging.getLogger("recorder")

ECHO_TOLERANCE_S = 1.5
ECHO_SIMILARITY = 80


def _overlaps(a: dict, b: dict, tol: float) -> bool:
    return a["start"] <= b["end"] + tol and b["start"] <= a["end"] + tol


def is_echo(mic_seg: dict, system_segs: list[dict]) -> bool:
    text = mic_seg["text"]
    for s in system_segs:
        if not _overlaps(mic_seg, s, ECHO_TOLERANCE_S):
            continue
        # partial_ratio tolera que whisper corte distinto las frases. Para textos
        # cortos ("Gracias.", "Sí.") se exige coincidencia con el segmento entero
        # o con su inicio/final (whisper suele pegarlos a la frase vecina).
        if len(text) >= 20:
            score = fuzz.partial_ratio(text, s["text"])
        else:
            n = len(text) + 2
            score = max(fuzz.ratio(text, s["text"]), fuzz.ratio(text, s["text"][:n]), fuzz.ratio(text, s["text"][-n:]))
        if score >= ECHO_SIMILARITY:
            return True
    return False


def merge_tracks(tracks: dict[str, list[dict]], audio_echo=None) -> tuple[list[dict], int]:
    """tracks: nombre -> segmentos (ya con offset aplicado). Devuelve (segmentos, nº de ecos).

    Los bloques ("system.000", "system.001"…) se tratan como una sola pista.
    """
    system = sorted((x for name, segs in tracks.items() if base_name(name) == "system" for x in segs),
                    key=lambda x: x["start"])
    merged: list[dict] = []
    echoes = 0
    for name, segs in tracks.items():
        for seg in segs:
            if base_name(name) == "mic" and system and (
                    (audio_echo is not None and audio_echo(seg)) or is_echo(seg, system)):
                echoes += 1
                continue
            merged.append({**seg, "track": name, "speaker": seg.get("speaker") or speaker_for(name)})
    merged.sort(key=lambda x: (x["start"], x["end"]))
    return merged, echoes


def group_turns(segs: list[dict], gap_s: float = 2.0) -> list[dict]:
    """Agrupa segmentos consecutivos del mismo hablante en turnos."""
    turns: list[dict] = []
    for s in segs:
        cur = turns[-1] if turns else None
        if cur and cur["speaker"] == s["speaker"] and s["start"] - cur["end"] <= gap_s:
            cur["text"] += " " + s["text"]
            cur["end"] = max(cur["end"], s["end"])
        else:
            turns.append({"speaker": s["speaker"], "start": s["start"], "end": s["end"], "text": s["text"]})
    return turns


def to_markdown(title: str, segs: list[dict]) -> str:
    lines = [f"# Transcripción — {title}", ""]
    lines += [f"**[{fmt_ts(t['start'])}] {t['speaker']}:** {t['text']}\n" for t in group_turns(segs)]
    return "\n".join(lines)


def to_text(title: str, segs: list[dict]) -> str:
    lines = [f"Transcripción — {title}", ""]
    lines += [f"[{fmt_ts(t['start'])}] {t['speaker']}: {t['text']}" for t in group_turns(segs)]
    return "\n".join(lines) + "\n"


class Merge:
    name = "merge"

    @staticmethod
    def _audio_echo(s: Session):
        """Detector de eco por señal (envolventes de mic y sistema); None si falta una pista."""
        parts: dict[str, list] = {}
        try:
            for t in usable_tracks(s):
                wav = s.wav16k(t.name)
                if wav.is_file():
                    env = envelope(wav, cache=s.work / f"{t.name}.env.npy")
                    parts.setdefault(base_name(t.name), []).append((t.offset_s, env))
        except Exception:  # noqa: BLE001  (si algo falla, queda el detector por texto)
            log.warning("[%s] no se pudo calcular la envolvente para el eco", s.id, exc_info=True)
            return None
        if "mic" not in parts or "system" not in parts:
            return None
        mic, system = TrackEnvelope(parts["mic"]), TrackEnvelope(parts["system"])
        return lambda seg: is_audio_echo(mic, system, seg)

    def is_done(self, s: Session, cfg: Config) -> bool:
        if not (s.transcript_json.is_file() and s.transcript_md.is_file() and s.transcript_txt.is_file()):
            return False
        # Con bloques, la transcripción se rehace cuando hay pistas nuevas.
        return read_json(s.transcript_json).get("tracks") == sorted(t.name for t in usable_tracks(s))

    def run(self, s: Session, cfg: Config) -> None:
        tracks: dict[str, list[dict]] = {}
        for t in usable_tracks(s):
            segs = read_json(s.segments(t.name))["segments"]
            tracks[t.name] = [{**x, "start": round(x["start"] + t.offset_s, 2),
                               "end": round(x["end"] + t.offset_s, 2)} for x in segs]
        try:
            n_voices = assign_speakers(cfg, s, tracks)
            if n_voices > 1:
                log.info("[%s] %d voces distintas entre los participantes", s.id, n_voices)
        except Exception:  # noqa: BLE001  (si falla, queda "Participantes")
            log.warning("[%s] no se pudieron separar las voces", s.id, exc_info=True)
        merged, echoes = merge_tracks(tracks, audio_echo=self._audio_echo(s))
        if echoes:
            log.info("[%s] %d segmentos de eco descartados del micrófono", s.id, echoes)
        atomic_write_json(s.transcript_json, {"title": s.title, "echo_removed": echoes,
                                              "tracks": sorted(tracks), "segments": merged})
        atomic_write_text(s.transcript_md, to_markdown(s.title, merged))
        atomic_write_text(s.transcript_txt, to_text(s.title, merged))
