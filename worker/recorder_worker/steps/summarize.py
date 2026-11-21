"""Paso 5: resumen estructurado con la IA que elija el usuario (o la de su agente).

Sólo se envía TEXTO (la transcripción); el audio nunca sale del Mac.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess

import anthropic
from pydantic import BaseModel, Field

from ..config import Config
from ..session import Session
from ..util import PermanentError, StepError, atomic_write_json, atomic_write_text, fmt_ts, read_json

log = logging.getLogger("recorder")

FALLBACK_BETA = "server-side-fallback-2026-07-01"


# ---------------------------------------------------------------- esquema


class Tema(BaseModel):
    titulo: str
    inicio: str = Field(description="Timestamp HH:MM:SS donde empieza el tema")
    puntos_clave: list[str]


class ActionItem(BaseModel):
    tarea: str
    responsable: str | None = Field(description="Persona responsable si se menciona; null si no")
    fecha_limite: str | None = Field(description="Fecha o plazo tal como se dijo; null si no")
    timestamp: str | None = Field(description="HH:MM:SS donde se acordó")


class Resumen(BaseModel):
    titulo_sugerido: str
    resumen_ejecutivo: str = Field(description="5 a 8 líneas")
    participantes_mencionados: list[str]
    temas: list[Tema]
    decisiones: list[str]
    action_items: list[ActionItem]
    preguntas_abiertas: list[str]
    riesgos: list[str]


SYSTEM = """Eres un asistente que resume reuniones de trabajo a partir de transcripciones automáticas.

Sobre la transcripción:
- Viene de reconocimiento de voz: puede tener errores de palabras, nombres mal escritos o frases cortadas. Corrige lo obvio por contexto, pero no inventes contenido.
- "Yo" es la persona que grabó la reunión (su micrófono). "Participantes" agrupa al resto de voces sin distinguirlas; si por el contexto se deduce quién habla (alguien dice su nombre o se le pregunta directamente), úsalo.
- Cada línea empieza con [HH:MM:SS]; úsalos para los timestamps que pide el esquema.

Sobre el resumen:
- Escribe en el mismo idioma predominante de la reunión.
- Sé concreto: cifras, fechas, nombres y compromisos tal como se dijeron.
- Una decisión es algo acordado; no conviertas propuestas o dudas en decisiones.
- Un action item necesita una tarea concreta; si no hay responsable o fecha explícitos, déjalos en null.
- Si una sección no aplica, devuelve una lista vacía.
"""


# ---------------------------------------------------------------- cliente


def _api_key(cfg: Config) -> str | None:
    if os.environ.get("ANTHROPIC_API_KEY"):
        return None  # el SDK la toma del entorno
    try:
        res = subprocess.run(["security", "find-generic-password", "-s", cfg.claude.keychain_service, "-w"],
                             capture_output=True, text=True, timeout=10)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:  # noqa: BLE001
        log.debug("no se pudo leer el Llavero", exc_info=True)
    return None  # el SDK intentará otras fuentes (p. ej. `ant auth login`)


def make_client(cfg: Config) -> anthropic.Anthropic:
    key = _api_key(cfg)
    kwargs = {"max_retries": 4, "timeout": 600.0}
    try:
        return anthropic.Anthropic(api_key=key, **kwargs) if key else anthropic.Anthropic(**kwargs)
    except anthropic.AnthropicError as e:
        raise PermanentError(
            "No hay credenciales de Anthropic. Guarda la API key con: recorder set-key"
        ) from e


def _template(cfg: Config, name: str) -> str:
    f = cfg.paths.templates / f"{name}.md"
    if not f.is_file():
        if name != "general":
            raise PermanentError(f"no existe la plantilla {f}")
        return ""
    return f.read_text(encoding="utf-8").strip()


def _glossary(cfg: Config) -> str:
    f = cfg.whisper.glossary_file
    if not f or not f.is_file():
        return ""
    terms = [ln.strip() for ln in f.read_text(encoding="utf-8").splitlines()
             if ln.strip() and not ln.lstrip().startswith("#")]
    return ("Glosario (ortografía correcta de nombres y términos): " + ", ".join(terms)) if terms else ""


def call_claude(client: anthropic.Anthropic, cfg: Config, system: str, user: str) -> Resumen:
    try:
        resp = client.beta.messages.parse(
            model=cfg.claude.model,
            max_tokens=cfg.claude.max_tokens,
            betas=[FALLBACK_BETA],
            fallbacks="default",
            output_config={"effort": cfg.claude.effort},
            output_format=Resumen,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
    except (anthropic.AuthenticationError, anthropic.PermissionDeniedError) as e:
        raise PermanentError(f"credenciales de Anthropic inválidas: {e.message}") from e
    except (anthropic.BadRequestError, anthropic.NotFoundError) as e:
        raise PermanentError(f"petición rechazada por la API: {e.message}") from e
    except anthropic.RateLimitError as e:
        raise StepError("límite de tasa de la API; se reintentará") from e
    except anthropic.APIStatusError as e:
        if e.status_code >= 500:
            raise StepError(f"error del servidor ({e.status_code})") from e
        raise PermanentError(f"error de la API ({e.status_code}): {e.message}") from e
    except anthropic.APIConnectionError as e:
        raise StepError("sin conexión con la API de Anthropic") from e

    if resp.stop_reason == "refusal":
        cat = resp.stop_details.category if resp.stop_details else None
        raise PermanentError(f"Claude rechazó resumir esta sesión (categoría: {cat})")
    if resp.stop_reason == "max_tokens":
        raise StepError("respuesta truncada por max_tokens")
    if resp.parsed_output is None:
        raise StepError("la respuesta no trajo un resumen válido")
    u = resp.usage
    log.info("Claude (%s): %s tokens entrada, %s salida", resp.model, u.input_tokens, u.output_tokens)
    return resp.parsed_output


# ---------------------------------------------------------------- lógica


def transcript_text(segs: list[dict], names: dict[str, str] | None = None) -> str:
    """Una línea por frase; con los nombres que el usuario puso a las voces (Persona 2 → Ana)."""
    names = names or {}
    return "\n".join(f"[{fmt_ts(s['start'])}] {names.get(s['speaker'], s['speaker'])}: {s['text']}" for s in segs)


def _chunks(lines: list[str], max_chars: int) -> list[str]:
    out, cur, size = [], [], 0
    for ln in lines:
        if size + len(ln) > max_chars and cur:
            out.append("\n".join(cur))
            cur, size = [], 0
        cur.append(ln)
        size += len(ln) + 1
    if cur:
        out.append("\n".join(cur))
    return out


def session_provider(s: Session, cfg: Config) -> str:
    return s.manifest().get("provider") or cfg.summary.provider


def summary_requested(s: Session, cfg: Config) -> bool:
    flag = s.manifest().get("summarize")
    return cfg.summary.auto if flag is None else bool(flag)


def summarize_session(s: Session, cfg: Config, template: str | None = None,
                      provider: str | None = None) -> Resumen:
    from .. import providers

    data = read_json(s.transcript_json)
    segs = data["segments"]
    if not segs:
        raise PermanentError("la transcripción está vacía; no hay nada que resumir")

    provider = provider or session_provider(s, cfg)
    tpl = _template(cfg, template or s.manifest().get("template") or cfg.summary.template)
    system = "\n\n".join(x for x in (SYSTEM, tpl, _glossary(cfg)) if x)
    text = transcript_text(segs, s.manifest().get("speaker_names"))
    header = f"Título de la sesión: {s.title}\n"
    limit = providers.chunk_chars(cfg, provider)
    log.info("[%s] resumiendo con %s", s.id, provider)

    def gen(user: str) -> Resumen:
        return providers.generate(cfg, provider, system, user)

    if len(text) <= limit:
        return gen(f"{header}\n<transcripcion>\n{text}\n</transcripcion>")

    # Transcripción más larga que el contexto del modelo: por bloques y luego consolidar.
    parts = _chunks(text.splitlines(), limit)
    log.info("[%s] transcripción larga: resumen en %d bloques", s.id, len(parts))
    partials = [gen(f"{header}Parte {i} de {len(parts)} de la transcripción.\n"
                    f"<transcripcion>\n{part}\n</transcripcion>").model_dump()
                for i, part in enumerate(parts, 1)]
    return gen(
        f"{header}Estos son resúmenes parciales (JSON) de partes consecutivas de una misma reunión. "
        f"Consolídalos en un único resumen, sin duplicar puntos.\n<parciales>\n"
        f"{json.dumps(partials, ensure_ascii=False)}\n</parciales>"
    )


def to_markdown(s: Session, r: Resumen) -> str:
    m = s.manifest()
    out = [f"# {s.title}", ""]
    meta = [x for x in (m.get("started_at"), ", ".join(m.get("source_apps") or [])) if x]
    if meta:
        out += [f"_{' · '.join(meta)}_", ""]
    out += ["## Resumen", "", r.resumen_ejecutivo, ""]
    if r.decisiones:
        out += ["## Decisiones", "", *[f"- {d}" for d in r.decisiones], ""]
    if r.action_items:
        out += ["## Action items", "", "| Tarea | Responsable | Fecha | Min. |", "|---|---|---|---|"]
        for a in r.action_items:
            cell = lambda v: (v or "—").replace("|", "/")  # noqa: E731
            out.append(f"| {cell(a.tarea)} | {cell(a.responsable)} | {cell(a.fecha_limite)} | {cell(a.timestamp)} |")
        out.append("")
    if r.temas:
        out += ["## Temas", ""]
        for t in r.temas:
            out += [f"### {t.titulo} `{t.inicio}`", *[f"- {p}" for p in t.puntos_clave], ""]
    if r.preguntas_abiertas:
        out += ["## Preguntas abiertas", "", *[f"- {q}" for q in r.preguntas_abiertas], ""]
    if r.riesgos:
        out += ["## Riesgos", "", *[f"- {q}" for q in r.riesgos], ""]
    if r.participantes_mencionados:
        out += ["## Participantes mencionados", "", ", ".join(r.participantes_mencionados), ""]
    out += ["---", f"Transcripción completa: [transcript.md]({s.transcript_md.name})", ""]
    return "\n".join(out)


class Summarize:
    name = "summarize"

    def is_done(self, s: Session, cfg: Config) -> bool:
        if not summary_requested(s, cfg):
            return True  # sólo transcripción: no se gasta en LLM
        m = s.manifest()
        if m.get("summarize") is None and m.get("summary_status") == "failed":
            return True  # el automático ya falló: se reintenta a mano desde la app
        return s.summary_json.is_file() and s.summary_md.is_file()

    def run(self, s: Session, cfg: Config, template: str | None = None) -> None:
        if s.manifest().get("summarize") is None:
            # Resumen automático: si falla, la transcripción sigue valiendo; se anota el error.
            try:
                write_summary(s, cfg, template)
            except (PermanentError, StepError) as e:
                log.warning("[%s] resumen automático falló: %s", s.id, e)
                s.update_manifest(summary_status="failed", summary_error=str(e).splitlines()[0][:300])
            return
        write_summary(s, cfg, template)


def save_summary(s: Session, r: Resumen, provider: str) -> None:
    atomic_write_json(s.summary_json, {**r.model_dump(), "_provider": provider})
    atomic_write_text(s.summary_md, to_markdown(s, r) + f"\n_Resumen generado con: {provider}_\n")
    fields = {"summary_status": "done", "summary_error": None, "summary_provider": provider}
    if not s.manifest().get("title_user_set") and r.titulo_sugerido:
        fields["suggested_title"] = r.titulo_sugerido
    s.update_manifest(**fields)


def write_summary(s: Session, cfg: Config, template: str | None = None, provider: str | None = None) -> None:
    from ..providers import describe
    provider = provider or session_provider(s, cfg)
    r = summarize_session(s, cfg, template, provider)
    save_summary(s, r, describe(cfg, provider))
