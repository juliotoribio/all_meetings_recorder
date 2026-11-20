"""Una sesión = una carpeta con manifest.json + pistas de audio + artefactos."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .util import PermanentError, atomic_write_json, read_json

# Etiqueta por defecto de cada pista en la transcripción
SPEAKER_LABELS = {"mic": "Yo", "system": "Participantes", "mixed": "Participantes"}


def base_name(track: str) -> str:
    """Las grabaciones por bloques nombran pistas "mic.000", "system.003"…"""
    return track.split(".")[0]


def speaker_for(track: str) -> str:
    return SPEAKER_LABELS.get(base_name(track), base_name(track))


@dataclass
class Track:
    name: str
    file: Path
    offset_s: float  # desplazamiento respecto al inicio de la sesión


class Session:
    def __init__(self, path: Path):
        self.path = path
        self.manifest_path = path / "manifest.json"
        self.work = path / "work"

    @property
    def id(self) -> str:
        return self.path.name

    def manifest(self) -> dict[str, Any]:
        if not self.manifest_path.is_file():
            raise PermanentError(f"falta manifest.json en {self.path}")
        return read_json(self.manifest_path)

    def update_manifest(self, **fields: Any) -> None:
        m = self.manifest()
        m.update(fields)
        atomic_write_json(self.manifest_path, m)

    @property
    def is_recording(self) -> bool:
        return self.manifest().get("status") == "recording"

    @property
    def title(self) -> str:
        return self.manifest().get("title") or self.id

    def tracks(self) -> list[Track]:
        m = self.manifest()
        raw = m.get("tracks") or {}
        if not raw:
            raise PermanentError("el manifest no declara pistas")
        # Alineación: cada pista declara el instante (s) de su primer buffer;
        # el offset es relativo a la pista que arrancó primero.
        starts = {name: float(t.get("first_host_time_s", 0.0)) for name, t in raw.items()}
        t0 = min(starts.values())
        return [Track(name, self.path / t["file"], starts[name] - t0) for name, t in raw.items()]

    def language(self, default: str) -> str:
        return self.manifest().get("language") or default

    # Artefactos
    def wav16k(self, track: str) -> Path:
        return self.work / f"{track}.16k.wav"

    def segments(self, track: str) -> Path:
        return self.work / f"{track}.segments.json"

    @property
    def validate_json(self) -> Path:
        return self.work / "validate.json"

    @property
    def transcript_json(self) -> Path:
        return self.path / "transcript.json"

    @property
    def transcript_md(self) -> Path:
        return self.path / "transcript.md"

    @property
    def transcript_txt(self) -> Path:
        """Texto plano agrupado por turnos: para copiar y pegar donde quieras."""
        return self.path / "transcript.txt"

    @property
    def summary_json(self) -> Path:
        return self.path / "summary.json"

    @property
    def summary_md(self) -> Path:
        return self.path / "summary.md"

    @property
    def export_marker(self) -> Path:
        return self.work / "exported.json"
