"""Proveedores de resumen. Todos devuelven un `Resumen` validado.

- none:     ninguna (por defecto): no se envía nada; el resumen lo hace tu agente o nadie.
- cli:      tu suscripción (ChatGPT o Claude) a través de Codex o Claude Code, sin API.
- local:    LM Studio u Ollama en este Mac (gratis, privado), JSON con esquema.
- openai:   cualquier API compatible con OpenAI (OpenAI, Groq, OpenRouter, Mistral, Gemini…).
- claude:   API de Anthropic, salida estructurada.
- deepseek: API de DeepSeek (compatible con OpenAI).

Las API keys se guardan en el Llavero: `recorder set-key openai|claude|deepseek`.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

import httpx
from pydantic import ValidationError

from .util import PermanentError, StepError

if TYPE_CHECKING:
    from .config import Config
    from .steps.summarize import Resumen

log = logging.getLogger("recorder")

PROVIDERS = ("none", "cli", "local", "openai", "claude", "deepseek")
KEYCHAIN = {"openai": "recorder-jt-openai", "deepseek": "recorder-jt-deepseek", "claude": "recorder-jt-anthropic"}
ENV_KEYS = {"openai": "OPENAI_API_KEY", "deepseek": "DEEPSEEK_API_KEY", "claude": "ANTHROPIC_API_KEY"}
NO_PROVIDER = ("No hay ninguna IA conectada. Conéctala en la app (Configuración → IA) "
               "o pide el resumen a tu agente (Configuración → Agentes).")


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
    return {"deepseek": cfg.deepseek.max_input_chars, "openai": cfg.openai.max_input_chars,
            "local": cfg.local.max_input_chars, "claude": cfg.claude.max_chars_single_call,
            "cli": cfg.cli.max_input_chars, "none": 10**9}.get(provider, 300_000)


def generate(cfg: Config, provider: str, system: str, user: str) -> Resumen:
    if provider == "none":
        raise PermanentError(NO_PROVIDER)
    if provider == "claude":
        from .steps.summarize import call_claude, make_client
        return call_claude(make_client(cfg), cfg, system, user)
    if provider == "deepseek":
        return _deepseek(cfg, system, user)
    if provider == "openai":
        return _openai(cfg, system, user)
    if provider == "cli":
        return _cli(cfg, system, user)
    if provider == "local":
        return _local(cfg, system, user)
    raise PermanentError(f"proveedor desconocido: {provider} (usa {', '.join(PROVIDERS)})")


def describe(cfg: Config, provider: str) -> str:
    """Nombre legible para mensajes ("OpenAI-compatible · gpt-4.1-mini")."""
    if provider == "cli":
        name = {"codex": "ChatGPT (Codex)", "claude": "Claude Code"}.get(cfg.cli.tool, cfg.cli.tool)
        return f"tu suscripción · {name}" + (f" · {cfg.cli.model}" if cfg.cli.model else "")
    return {"none": "ninguna", "local": f"local · {cfg.local.model}", "openai": f"{cfg.openai.model} ({cfg.openai.base_url})",
            "claude": f"Claude · {cfg.claude.model}", "deepseek": f"DeepSeek · {cfg.deepseek.model}"}.get(provider, provider)


def ping(cfg: Config, provider: str) -> str:
    """Prueba la conexión con una petición mínima. Devuelve un texto para el usuario o lanza error."""
    if provider == "none":
        raise PermanentError("Elige una IA primero.")
    if provider == "claude":
        import anthropic
        from .steps.summarize import make_client
        try:
            r = make_client(cfg).messages.create(model=cfg.claude.model, max_tokens=8,
                                                 messages=[{"role": "user", "content": "Responde solo: OK"}])
        except anthropic.AuthenticationError as e:
            raise PermanentError("La clave de Anthropic no es válida.") from e
        except anthropic.APIStatusError as e:
            raise PermanentError(f"Anthropic respondió {e.status_code}: {e.message}") from e
        except anthropic.APIConnectionError as e:
            raise StepError("Sin conexión con Anthropic.") from e
        return f"Conectado a {r.model}."
    if provider == "cli":
        r = _cli_text(cfg, "Responde solo con la palabra OK.", timeout=180)
        tool = {"codex": "ChatGPT (Codex)", "claude": "Claude Code"}.get(cfg.cli.tool, cfg.cli.tool)
        if "ok" not in r.lower():
            raise StepError(f"{tool} respondió algo inesperado: {r[:120]}")
        return f"Conectado con tu cuenta a través de {tool}."
    if provider == "local":
        try:
            r = httpx.get(f"{cfg.local.base_url.rstrip('/')}/models", timeout=5)
            ids = [m["id"] for m in r.json().get("data", [])]
        except Exception as e:  # noqa: BLE001
            raise StepError(f"No responde {cfg.local.base_url}. Abre LM Studio u Ollama con el servidor activo.") from e
        if not any(cfg.local.model in i for i in ids):
            raise PermanentError(f"El modelo {cfg.local.model or '(vacío)'} no está. Disponibles: {', '.join(ids) or 'ninguno'}.")
        return f"Conectado. Modelo {cfg.local.model} disponible."
    base, model, key = _compat_target(cfg, provider)
    _chat(f"{base}/chat/completions", {"Authorization": f"Bearer {key}"},
          {"model": model, "messages": [{"role": "user", "content": "Responde solo: OK"}], "max_tokens": 8, "stream": False},
          timeout=30, check_length=False)
    return f"Conectado a {model}."


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


def _chat(url: str, headers: dict, body: dict, timeout: float, check_length: bool = True) -> str:
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
    if check_length and choice.get("finish_reason") == "length":
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


def _compat_target(cfg: Config, provider: str) -> tuple[str, str, str]:
    """URL base, modelo y clave de un proveedor compatible con OpenAI."""
    c = cfg.deepseek if provider == "deepseek" else cfg.openai
    name = "DeepSeek" if provider == "deepseek" else "la IA"
    if not c.base_url or not c.model:
        raise PermanentError(f"Falta la URL o el modelo de {name}. Complétalos en Configuración → IA.")
    key = api_key(provider)
    if not key:
        raise PermanentError(f"No hay clave para {name}. Guárdala en Configuración → IA (o: recorder set-key {provider}).")
    return c.base_url.rstrip("/"), c.model, key


def _compat(cfg: Config, provider: str, system: str, user: str) -> Resumen:
    base, model, key = _compat_target(cfg, provider)
    c = cfg.deepseek if provider == "deepseek" else cfg.openai
    # Modo JSON: casi todas lo aceptan si el prompt menciona "json" y da el formato.
    sys_msg = f"{system}\n\nResponde únicamente con un objeto json que cumpla este JSON Schema:\n{_schema_hint()}"
    json_mode = {"on": True}

    def call(messages: list[dict]) -> str:
        body = {"model": model, "messages": messages, "max_tokens": c.max_tokens, "stream": False}
        if json_mode["on"]:
            body["response_format"] = {"type": "json_object"}
        try:
            return _chat(f"{base}/chat/completions", {"Authorization": f"Bearer {key}"}, body, timeout=c.timeout_s)
        except PermanentError as e:
            # Algunos modelos no aceptan response_format: se repite sin él (el esquema va en el prompt).
            if json_mode["on"] and "response_format" in str(e):
                json_mode["on"] = False
                return call(messages)
            raise

    return _with_validation_retry(call, [{"role": "system", "content": sys_msg}, {"role": "user", "content": user}])


def _openai(cfg: Config, system: str, user: str) -> Resumen:
    return _compat(cfg, "openai", system, user)


def _deepseek(cfg: Config, system: str, user: str) -> Resumen:
    return _compat(cfg, "deepseek", system, user)


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
    if ":1234" in l.base_url:  # LM Studio: se carga el modelo con contexto suficiente
        _ensure_local_model(cfg)
    schema = {"type": "json_schema",
              "json_schema": {"name": "resumen", "strict": True, "schema": Resumen.model_json_schema()}}

    def call(messages: list[dict]) -> str:
        return _chat(f"{l.base_url.rstrip('/')}/chat/completions", {},
                     {"model": l.model, "messages": messages, "max_tokens": l.max_tokens,
                      "temperature": 0.2, "response_format": schema, "stream": False},
                     timeout=l.timeout_s)

    return _with_validation_retry(call, [{"role": "system", "content": system}, {"role": "user", "content": user}])


# ---------------------------------------------------------------- tu suscripción (Codex / Claude Code)

CLI_PATHS = {
    "codex": ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
              "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex", "~/.npm-global/bin/codex"],
    "claude": ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude", "~/.claude/local/claude",
               "~/.npm-global/bin/claude"],
}


def find_cli(tool: str) -> str | None:
    import shutil
    from pathlib import Path
    for c in CLI_PATHS.get(tool, []):
        p = Path(c).expanduser()
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    return shutil.which(tool)


def strict_schema(schema: dict) -> dict:
    """Esquema estricto (salida estructurada de OpenAI): sin propiedades extra y todas requeridas."""
    def fix(node):
        if isinstance(node, dict):
            if node.get("type") == "object" and "properties" in node:
                node["additionalProperties"] = False
                node["required"] = list(node["properties"])
            for k in ("title", "default"):
                node.pop(k, None)
            for v in node.values():
                fix(v)
        elif isinstance(node, list):
            for v in node:
                fix(v)
        return node
    return fix(json.loads(json.dumps(schema)))


def _run_cli(args: list[str], stdin: str, timeout: float, tool: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + env.get("PATH", "")
    # Que la herramienta use la sesión de la cuenta, no una API key del entorno.
    for k in list(env):
        if k in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDECODE") or k.startswith(("CLAUDE_CODE_", "CLAUDE_AGENT_SDK")):
            env.pop(k, None)
    try:
        res = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired as e:
        raise StepError(f"{tool} tardó más de {int(timeout)} s") from e
    if res.returncode != 0:
        err = (res.stderr or res.stdout).strip()
        low = err.lower()
        if any(w in low for w in ("login", "log in", "not logged", "authenticat", "unauthorized", "401")):
            if tool == "claude":
                _check_claude_login("not logged in")
            raise PermanentError("Codex no tiene sesión iniciada. Pulsa «Iniciar sesión en ChatGPT» en Configuración → IA (o ejecuta: codex login).")
        if any(w in low for w in ("usage limit", "rate limit", "limit reached", "quota")):
            raise StepError(f"{tool}: alcanzaste el límite de uso de tu plan; se puede reintentar más tarde")
        raise StepError(f"{tool} terminó con error: {err[-300:]}")
    return res


def _cli_text(cfg: Config, prompt: str, timeout: float) -> str:
    """Petición de texto simple (para probar la conexión)."""
    import tempfile
    tool = cfg.cli.tool
    exe = find_cli(tool)
    if not exe:
        raise PermanentError(_missing_cli(tool))
    with tempfile.TemporaryDirectory(prefix="rjt-cli-") as tmp:
        if tool == "codex":
            out = Path(tmp) / "out.txt"
            args = [exe, "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                    "-C", tmp, "-o", str(out)] + (["-m", cfg.cli.model] if cfg.cli.model else []) + [prompt]
            _run_cli(args, "", timeout, tool)
            return out.read_text(encoding="utf-8") if out.is_file() else ""
        args = [exe, "-p", "--output-format", "text", "--tools", "", "--no-session-persistence",
                "--strict-mcp-config", "--setting-sources", ""] + (["--model", cfg.cli.model] if cfg.cli.model else [])
        out = _run_cli(args, prompt, timeout, tool).stdout
        _check_claude_login(out)
        return out


def _check_claude_login(text: str) -> None:
    if "not logged in" in text.lower() or "/login" in text:
        raise PermanentError("Claude Code no tiene sesión iniciada. Pulsa «Iniciar sesión en Claude» en Configuración → IA (o ejecuta: claude auth login).")


def _missing_cli(tool: str) -> str:
    if tool == "codex":
        return ("No se encontró Codex. Instala la app de ChatGPT (incluye Codex) o el CLI "
                "(npm i -g @openai/codex) e inicia sesión con tu cuenta.")
    return "No se encontró Claude Code. Instálalo desde claude.com/claude-code e inicia sesión con tu cuenta."


def _cli(cfg: Config, system: str, user: str) -> Resumen:
    import tempfile
    from .steps.summarize import Resumen
    tool = cfg.cli.tool
    exe = find_cli(tool)
    if not exe:
        raise PermanentError(_missing_cli(tool))
    schema = strict_schema(Resumen.model_json_schema())
    log.info("resumen con %s (%s)", tool, exe)
    with tempfile.TemporaryDirectory(prefix="rjt-cli-") as tmp:
        if tool == "codex":
            sf, out = Path(tmp) / "schema.json", Path(tmp) / "out.json"
            sf.write_text(json.dumps(schema), encoding="utf-8")
            prompt = (f"{system}\n\nNo uses herramientas ni leas archivos: todo lo que necesitas está en el bloque <stdin>. "
                      "Responde solo con el JSON del resumen.")
            args = [exe, "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                    "-C", tmp, "--output-schema", str(sf), "-o", str(out)] + (["-m", cfg.cli.model] if cfg.cli.model else []) + [prompt]
            _run_cli(args, user, cfg.cli.timeout_s, tool)
            content = out.read_text(encoding="utf-8") if out.is_file() else ""
        else:
            args = [exe, "-p", "--output-format", "json", "--json-schema", json.dumps(schema),
                    "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
                    "--system-prompt", system] + (["--model", cfg.cli.model] if cfg.cli.model else [])
            res = _run_cli(args, user, cfg.cli.timeout_s, tool)
            try:
                data = json.loads(res.stdout)
            except ValueError:
                data = {"result": res.stdout}
            if data.get("is_error"):
                _check_claude_login(str(data.get("result")))
                raise StepError(f"Claude Code: {str(data.get('result'))[:300]}")
            so = data.get("structured_output")
            content = json.dumps(so) if so else str(data.get("result") or "")
    try:
        return _parse(content)
    except (ValueError, ValidationError) as e:
        raise StepError(f"{tool} no devolvió un resumen válido: {str(e)[:200]}") from e


def cli_account(tool: str) -> dict:
    """¿Está la herramienta instalada y con sesión? Y el comando para iniciarla."""
    import shlex
    exe = find_cli(tool)
    info = {"tool": tool, "installed": bool(exe), "logged_in": False, "login_command": None}
    if not exe:
        return info
    q = shlex.quote(exe)
    info["login_command"] = f"{q} auth login" if tool == "claude" else f"{q} login"
    env = {k: v for k, v in os.environ.items()
           if not (k == "CLAUDECODE" or k.startswith(("CLAUDE_CODE_", "CLAUDE_AGENT_SDK")))}
    try:
        if tool == "claude":
            r = subprocess.run([exe, "auth", "status"], capture_output=True, text=True, timeout=30, env=env)
            info["logged_in"] = bool(json.loads(r.stdout or "{}").get("loggedIn"))
        else:
            r = subprocess.run([exe, "login", "status"], capture_output=True, text=True, timeout=30, env=env)
            info["logged_in"] = r.returncode == 0 and "logged in" in (r.stdout + r.stderr).lower()
    except Exception:  # noqa: BLE001
        pass
    return info
