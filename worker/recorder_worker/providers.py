"""Proveedores de resumen. Todos devuelven un `Resumen` validado.

- deepseek: API de DeepSeek (compatible con OpenAI), modo JSON.
- local:    LM Studio en este Mac (gratis, privado), JSON con esquema estricto.
- claude:   API de Anthropic, salida estructurada.

Las API keys se guardan en el Llavero: `recorder set-key deepseek|claude`.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
from typing import TYPE_CHECKING

import httpx
from pydantic import ValidationError

from .util import PermanentError, StepError

if TYPE_CHECKING:
    from .config import Config
    from .steps.summarize import Resumen

log = logging.getLogger("recorder")

PROVIDERS = ("deepseek", "local", "claude")
KEYCHAIN = {"deepseek": "recorder-jt-deepseek", "claude": "recorder-jt-anthropic"}
ENV_KEYS = {"deepseek": "DEEPSEEK_API_KEY", "claude": "ANTHROPIC_API_KEY"}


def api_key(provider: str) -> str | None:
    if os.environ.get(ENV_KEYS.get(provider, "")):
        return os.environ[ENV_KEYS[provider]]
    svc = KEYCHAIN.get(provider)
    if not svc:
        return None
    try:
        res = subprocess.run(["security", "find-generic-password", "-s", svc, "-w"],
                             capture_output=True, text=True, timeout=10)
        return res.stdout.strip() or None if res.returncode == 0 else None
    except Exception:  # noqa: BLE001
        return None


def chunk_chars(cfg: Config, provider: str) -> int:
    """Caracteres de transcripción por llamada (≈ 3,5 caracteres por token)."""
    return {"deepseek": cfg.deepseek.max_input_chars, "local": cfg.local.max_input_chars,
            "claude": cfg.claude.max_chars_single_call}[provider]


def generate(cfg: Config, provider: str, system: str, user: str) -> Resumen:
    if provider == "claude":
        from .steps.summarize import call_claude, make_client
        return call_claude(make_client(cfg), cfg, system, user)
    if provider == "deepseek":
        return _deepseek(cfg, system, user)
    if provider == "local":
        return _local(cfg, system, user)
    raise PermanentError(f"proveedor desconocido: {provider} (usa {', '.join(PROVIDERS)})")


# ---------------------------------------------------------------- compatibles OpenAI


def _schema_hint() -> str:
    from .steps.summarize import Resumen
    return json.dumps(Resumen.model_json_schema(), ensure_ascii=False)


def _parse(content: str) -> Resumen:
    from .steps.summarize import Resumen
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.S).strip()
    m = re.search(r"\{.*\}", content, flags=re.S)
    if not m:
        raise ValueError("la respuesta no contiene JSON")
    return Resumen.model_validate_json(m.group(0))


def _chat(url: str, headers: dict, body: dict, timeout: float) -> str:
    try:
        r = httpx.post(url, headers=headers, json=body, timeout=timeout)
    except httpx.TimeoutException as e:
        raise StepError(f"timeout llamando a {url}") from e
    except httpx.TransportError as e:
        raise StepError(f"sin conexión con {url}: {e}") from e
    if r.status_code in (401, 403):
        raise PermanentError(f"API key inválida o sin permisos ({r.status_code})")
    if r.status_code == 402:
        raise PermanentError("sin saldo en la cuenta del proveedor (402)")
    if r.status_code == 429 or r.status_code >= 500:
        raise StepError(f"{url} respondió {r.status_code}; se reintentará")
    if r.status_code >= 400:
        raise PermanentError(f"petición rechazada ({r.status_code}): {r.text[:300]}")
    data = r.json()
    choice = data["choices"][0]
    if choice.get("finish_reason") == "length":
        raise StepError("respuesta truncada por longitud")
    usage = data.get("usage") or {}
    log.info("%s: %s tokens entrada, %s salida", data.get("model"), usage.get("prompt_tokens"),
             usage.get("completion_tokens"))
    msg = choice["message"]
    # Con modelos "pensantes" (Qwen 3.x), LM Studio a veces deja la salida
    # estructurada en reasoning_content y content vacío.
    return msg.get("content") or msg.get("reasoning_content") or ""


def _with_validation_retry(call, messages: list[dict]) -> Resumen:
    """Si el JSON no valida, se reintenta una vez indicando el error."""
    content = call(messages)
    try:
        return _parse(content)
    except (ValueError, ValidationError) as e:
        log.warning("JSON inválido del modelo (%s); reintentando una vez", str(e)[:200])
        retry = messages + [{"role": "assistant", "content": content},
                            {"role": "user", "content": f"El JSON no es válido: {str(e)[:500]}. "
                                                        "Devuelve SOLO el JSON corregido."}]
        try:
            return _parse(call(retry))
        except (ValueError, ValidationError) as e2:
            raise StepError(f"el modelo no devolvió un JSON válido: {str(e2)[:200]}") from e2


def _deepseek(cfg: Config, system: str, user: str) -> Resumen:
    key = api_key("deepseek")
    if not key:
        raise PermanentError("No hay API key de DeepSeek. Guárdala con: recorder set-key deepseek")
    d = cfg.deepseek
    # Modo JSON de DeepSeek: exige mencionar "json" y dar el formato en el prompt.
    sys_msg = f"{system}\n\nResponde únicamente con un objeto json que cumpla este JSON Schema:\n{_schema_hint()}"

    def call(messages: list[dict]) -> str:
        return _chat(f"{d.base_url.rstrip('/')}/chat/completions",
                     {"Authorization": f"Bearer {key}"},
                     {"model": d.model, "messages": messages, "max_tokens": d.max_tokens,
                      "response_format": {"type": "json_object"}, "stream": False},
                     timeout=d.timeout_s)

    return _with_validation_retry(call, [{"role": "system", "content": sys_msg}, {"role": "user", "content": user}])


def _ensure_local_model(cfg: Config) -> None:
    """Carga el modelo en LM Studio con contexto suficiente (y TTL para liberar RAM)."""
    l = cfg.local
    lms = l.lms_bin
    if not lms.is_file():
        return  # sin CLI: se confía en la carga JIT del servidor
    try:
        ps = subprocess.run([str(lms), "ps", "--json"], capture_output=True, text=True, timeout=30)
        loaded = json.loads(ps.stdout or "[]")
        for m in loaded:
            ident = m.get("identifier") or m.get("modelKey") or m.get("path", "")
            if l.model in ident and int(m.get("contextLength") or 0) >= l.context_length:
                return
        log.info("cargando %s en LM Studio (contexto %d)…", l.model, l.context_length)
        subprocess.run([str(lms), "load", l.model, "-c", str(l.context_length), "--ttl", str(l.ttl_s), "-y"],
                       capture_output=True, text=True, timeout=600, check=True)
    except subprocess.CalledProcessError as e:
        raise StepError(f"LM Studio no pudo cargar {l.model}: {(e.stderr or e.stdout)[-300:]}") from e
    except Exception as e:  # noqa: BLE001
        log.warning("no se pudo verificar el modelo cargado en LM Studio (%s); se intenta igual", e)


def _local(cfg: Config, system: str, user: str) -> Resumen:
    from .steps.summarize import Resumen
    l = cfg.local
    _ensure_local_model(cfg)
    schema = {"type": "json_schema",
              "json_schema": {"name": "resumen", "strict": True, "schema": Resumen.model_json_schema()}}

    def call(messages: list[dict]) -> str:
        return _chat(f"{l.base_url.rstrip('/')}/chat/completions", {},
                     {"model": l.model, "messages": messages, "max_tokens": l.max_tokens,
                      "temperature": 0.2, "response_format": schema, "stream": False},
                     timeout=l.timeout_s)

    return _with_validation_retry(call, [{"role": "system", "content": system}, {"role": "user", "content": user}])
