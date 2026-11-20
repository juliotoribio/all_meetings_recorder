"""Configuración: config.toml (opcional) sobre valores por defecto.

Búsqueda: $RECORDER_CONFIG → ~/RecorderJT/config.toml → <repo>/config/config.toml.
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _p(value: str | Path) -> Path:
    return Path(os.path.expandvars(str(value))).expanduser()


def _whisper_bin() -> Path:
    """whisper-cli de Homebrew (Apple Silicon o Intel) o el que esté en el PATH."""
    import shutil
    for c in ("/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"):
        if Path(c).is_file():
            return Path(c)
    found = shutil.which("whisper-cli")
    return Path(found) if found else Path("/opt/homebrew/bin/whisper-cli")


# Modelos descargados desde la app (Configuración) o con install.sh.
MODELS_DIR = _p("~/RecorderJT/models")


@dataclass
class WhisperConfig:
    bin: Path = field(default_factory=_whisper_bin)
    model: Path = MODELS_DIR / "ggml-large-v3.bin"               # calidad máxima
    fast_model: Path = MODELS_DIR / "ggml-large-v3-turbo-q5_0.bin"  # modo rápido (turbo)
    quality: str = "max"  # max | fast (la app guarda la elegida en cada grabación)
    vad_model: Path | None = MODELS_DIR / "ggml-silero-v6.2.0.bin"
    language: str = "auto"
    threads: int = field(default_factory=lambda: min(8, os.cpu_count() or 4))
    # timeout = base + duración_audio * factor (large-v3 en M1 Max ≈ 11-20x tiempo real)
    timeout_base_s: int = 180
    timeout_factor: float = 0.5
    chunk_minutes: int = 10  # tamaño de bloque en el fallback por bloques
    # Detector de voz: margen alrededor de cada tramo de voz (whisper.cpp usa 30 ms,
    # lo que corta bordes de palabras) y silencio mínimo para separar tramos.
    vad_pad_ms: int = 200
    vad_min_silence_ms: int = 300
    glossary_file: Path | None = REPO_ROOT / "config" / "glossary.txt"


@dataclass
class ClaudeConfig:
    model: str = "claude-opus-5-5"
    effort: str = "medium"
    max_tokens: int = 16000
    template: str = "general"
    keychain_service: str = "recorder-jt-anthropic"
    # Por encima de esto (caracteres de transcripción) se resume por bloques.
    max_chars_single_call: int = 2_000_000
    chunk_chars: int = 400_000


@dataclass
class SpeakersConfig:
    """Separar las voces de la otra parte (Persona 1, Persona 2…)."""
    enabled: bool = True
    model: Path = MODELS_DIR / "wespeaker_en_voxceleb_resnet34.onnx"
    threshold: float = 0.3   # distancia coseno; medido: 0.20-0.35 separa al 100 %
    min_share: float = 0.03  # voces con menos del 3 % del tiempo se reasignan
    # pyannote: dónde cambia la persona (también dentro de una frase) y cuándo hablan a la vez
    segmentation: Path = MODELS_DIR / "pyannote-segmentation-3.0.onnx"
    # recordar voces con nombre entre reuniones (similitud coseno mínima)
    remember: bool = True
    recall_threshold: float = 0.6


@dataclass
class SummaryConfig:
    # false = sólo transcribir; el resumen se pide con `recorder resume`.
    auto: bool = False
    provider: str = "deepseek"  # deepseek | local | claude


@dataclass
class DeepSeekConfig:
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-chat"
    max_tokens: int = 8000
    timeout_s: float = 300
    max_input_chars: int = 300_000  # ≈ 85k tokens; más que eso se resume por bloques


@dataclass
class LocalConfig:
    base_url: str = "http://localhost:1234/v1"  # servidor de LM Studio
    model: str = "qwen/qwen3.8-27b"
    lms_bin: Path = _p("~/.lmstudio/bin/lms")
    context_length: int = 32768
    ttl_s: int = 900  # descarga el modelo tras 15 min sin uso (libera ~16 GB de RAM)
    max_tokens: int = 6000
    timeout_s: float = 1800
    max_input_chars: int = 70_000  # ≈ 20k tokens: cabe en 32k de contexto con el prompt y la respuesta


@dataclass
class Paths:
    home: Path = _p("~/RecorderJT")
    sessions: Path = field(default=None)  # type: ignore[assignment]
    inbox: Path = field(default=None)  # type: ignore[assignment]
    db: Path = field(default=None)  # type: ignore[assignment]
    logs: Path = field(default=None)  # type: ignore[assignment]
    templates: Path = REPO_ROOT / "config" / "templates"

    def __post_init__(self) -> None:
        self.sessions = self.sessions or self.home / "sessions"
        self.inbox = self.inbox or self.home / "resumenes"
        self.db = self.db or self.home / "recorder.db"
        self.logs = self.logs or self.home / "logs"

    def ensure(self) -> None:
        for d in (self.home, self.sessions, self.inbox, self.logs):
            d.mkdir(parents=True, exist_ok=True)


@dataclass
class Worker:
    poll_seconds: int = 15
    max_attempts: int = 3
    backoff_base_s: int = 60
    notify: bool = True


@dataclass
class Config:
    whisper: WhisperConfig = field(default_factory=WhisperConfig)
    claude: ClaudeConfig = field(default_factory=ClaudeConfig)
    summary: SummaryConfig = field(default_factory=SummaryConfig)
    speakers: SpeakersConfig = field(default_factory=SpeakersConfig)
    deepseek: DeepSeekConfig = field(default_factory=DeepSeekConfig)
    local: LocalConfig = field(default_factory=LocalConfig)
    paths: Paths = field(default_factory=Paths)
    worker: Worker = field(default_factory=Worker)
    source: Path | None = None


PATH_KEYS = {"bin", "vad_model", "glossary_file", "home", "sessions", "inbox", "db", "logs", "templates", "lms_bin"}


def _apply(obj: object, data: dict) -> None:
    for key, value in data.items():
        if not hasattr(obj, key):
            raise ValueError(f"Clave de configuración desconocida: {type(obj).__name__}.{key}")
        if key in PATH_KEYS and value not in (None, ""):
            value = _p(value)
            if key in {"glossary_file", "templates"} and not value.is_absolute():
                value = REPO_ROOT / value
        setattr(obj, key, value)


def find_config_file() -> Path | None:
    candidates = [os.environ.get("RECORDER_CONFIG"), "~/RecorderJT/config.toml", REPO_ROOT / "config" / "config.toml"]
    for c in candidates:
        if c and _p(c).is_file():
            return _p(c)
    return None


def load_config(path: Path | None = None) -> Config:
    cfg = Config()
    path = path or find_config_file()
    if path:
        data = tomllib.loads(path.read_text())
        _apply(cfg.whisper, data.get("whisper", {}))
        whisper_model = data.get("whisper", {}).get("model")
        if whisper_model:
            cfg.whisper.model = _p(whisper_model)  # "model" sólo es ruta en [whisper]
        fast_model = data.get("whisper", {}).get("fast_model")
        if fast_model:
            cfg.whisper.fast_model = _p(fast_model)
        _apply(cfg.claude, data.get("claude", {}))
        _apply(cfg.summary, data.get("summary", {}))
        sp = dict(data.get("speakers", {}))
        if sp.get("model"):
            cfg.speakers.model = _p(sp.pop("model"))
        if "segmentation" in sp:
            cfg.speakers.segmentation = _p(sp.pop("segmentation"))
        _apply(cfg.speakers, sp)
        _apply(cfg.deepseek, data.get("deepseek", {}))
        _apply(cfg.local, data.get("local", {}))
        paths_data = data.get("paths", {})
        _apply(cfg.paths, paths_data)
        # recalcula derivados si sólo cambió home
        if "home" in paths_data:
            for k in ("sessions", "inbox", "db", "logs"):
                if k not in paths_data:
                    setattr(cfg.paths, k, None)
            cfg.paths.__post_init__()
        _apply(cfg.worker, data.get("worker", {}))
        cfg.source = path
    # La app con RJT_HOME (datos de demostración) pasa esa carpeta al worker.
    home = os.environ.get("RJT_HOME")
    if home:
        cfg.paths.home = Path(home).expanduser()
        for k in ("sessions", "inbox", "db", "logs"):
            setattr(cfg.paths, k, None)
        cfg.paths.__post_init__()
    return cfg
