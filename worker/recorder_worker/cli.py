"""CLI: recorder {import,resume,copy,status,retry,once,run,set-key,doctor}."""

from __future__ import annotations

import argparse
import datetime as dt
import logging
import logging.handlers
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

from .config import Config, load_config
from .pipeline import STEP_NAMES, WorkerLock, discover, drain, process_job, process_live, reset_from, run_forever
from .providers import PROVIDERS
from .queue import Queue
from .session import Session
from .util import atomic_write_json, ffprobe_duration, fmt_ts

log = logging.getLogger("recorder")

AUDIO_EXT = {".m4a", ".mp3", ".wav", ".caf", ".aiff", ".aif", ".flac", ".ogg", ".opus", ".mp4", ".mov", ".webm", ".mkv"}


def setup_logging(cfg: Config, verbose: bool) -> None:
    cfg.paths.ensure()
    root = logging.getLogger("recorder")
    root.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    fh = logging.handlers.RotatingFileHandler(cfg.paths.logs / "worker.log", maxBytes=5_000_000, backupCount=5)
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    root.handlers[:] = [fh, sh]


def _slug(text: str) -> str:
    s = re.sub(r"[^\w\s-]", "", text.lower()).strip()
    return re.sub(r"[\s_-]+", "-", s)[:40] or "sesion"


def find_session(cfg: Config, q: Queue, ident: str) -> Session:
    if ident in ("last", "ultima", "última"):
        dirs = sorted((p for p in cfg.paths.sessions.glob("*/manifest.json")), key=lambda p: p.parent.name)
        if not dirs:
            raise SystemExit("No hay sesiones todavía.")
        ident = dirs[-1].parent.name
    job = q.get(ident)
    if job:
        return Session(Path(job["path"]))
    matches = [p for p in cfg.paths.sessions.iterdir() if p.is_dir() and ident in p.name]
    if len(matches) == 1:
        q.add(matches[0].name, matches[0])
        return Session(matches[0])
    raise SystemExit(f"Sesión no encontrada o ambigua: {ident} ({len(matches)} coincidencias)")


def pbcopy(path: Path) -> bool:
    try:
        subprocess.run(["pbcopy"], input=path.read_text(encoding="utf-8"), text=True, check=True, timeout=10)
        return True
    except Exception:  # noqa: BLE001
        return False


def process_now_or_enqueue(cfg: Config, q: Queue, session_id: str, copy: str | None = None) -> int:
    lock = WorkerLock(cfg.paths.home / "worker.lock")
    if not lock.acquire():
        print("Hay un worker en segundo plano: la sesión quedó en cola y la procesará él.")
        return 0
    try:
        ok = process_job(cfg, q, session_id)
    finally:
        lock.release()
    job = q.get(session_id)
    s = Session(Path(job["path"]))
    if ok:
        print(f"\n✅ Listo: {s.path}")
        for f in (s.summary_md, s.transcript_txt):
            if f.is_file():
                print(f"   {f}")
        target = {"summary": s.summary_md, "transcript": s.transcript_txt}.get(copy or "")
        if target and target.is_file() and pbcopy(target):
            print(f"📋 {'Resumen' if copy == 'summary' else 'Transcripción'} copiado al portapapeles.")
        return 0
    print(f"\n❌ {job['status']}: {job['last_error']}\n   (recorder retry {session_id})")
    return 1


# ---------------------------------------------------------------- comandos


def cmd_import(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    src = Path(a.file).expanduser().resolve()
    if not src.is_file():
        raise SystemExit(f"No existe: {src}")
    if src.suffix.lower() not in AUDIO_EXT:
        print(f"Aviso: extensión {src.suffix} no reconocida; se intentará igual con ffmpeg.")
    mic = Path(a.mic).expanduser().resolve() if a.mic else None
    title = a.title or src.stem
    sid = f"{dt.datetime.now():%Y-%m-%d_%H%M}_{_slug(title)}_{secrets.token_hex(2)}"
    sdir = cfg.paths.sessions / sid
    sdir.mkdir(parents=True)
    tracks = {}
    if mic:
        tracks["system"] = {"file": f"system{src.suffix.lower()}", "first_host_time_s": 0.0}
        tracks["mic"] = {"file": f"mic{mic.suffix.lower()}", "first_host_time_s": float(a.mic_offset)}
        shutil.copyfile(src, sdir / tracks["system"]["file"])
        shutil.copyfile(mic, sdir / tracks["mic"]["file"])
    else:
        tracks["mixed"] = {"file": f"audio{src.suffix.lower()}", "first_host_time_s": 0.0}
        shutil.copyfile(src, sdir / tracks["mixed"]["file"])
    manifest = {
        "id": sid,
        "title": title,
        "title_user_set": bool(a.title),
        "status": "recorded",
        "source": "import",
        "imported_from": str(src),
        "started_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "language": a.language or cfg.whisper.language,
        "quality": a.quality or cfg.whisper.quality,
        "tracks": tracks,
    }
    if a.resume:
        manifest["summarize"] = True
    if a.provider:
        manifest["provider"] = a.provider
    if a.template:
        manifest["template"] = a.template
    atomic_write_json(sdir / "manifest.json", manifest)
    q.add(sid, sdir)
    try:
        dur = ffprobe_duration(src)
        print(f"Sesión creada: {sid} ({fmt_ts(dur)} de audio)")
    except Exception:  # noqa: BLE001
        print(f"Sesión creada: {sid}")
    if a.queue_only:
        return 0
    want = "summary" if (a.resume or cfg.summary.auto) else "transcript"
    return process_now_or_enqueue(cfg, q, sid, copy=None if a.no_copy else want)


def cmd_status(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    discover(cfg, q)
    rows = q.all()
    if not rows:
        print(f"Sin sesiones en {cfg.paths.sessions}")
        return 0
    icon = {"done": "✅", "failed": "❌", "running": "⏳", "pending": "🕓"}
    for r in rows[: a.limit]:
        extra = f" · paso {r['step']}" if r["status"] in ("running", "pending") and r["step"] else ""
        if r["attempts"]:
            extra += f" · intentos {r['attempts']}"
        print(f"{icon.get(r['status'], '?')} {r['session_id']}  [{r['status']}{extra}]")
        if r["last_error"] and r["status"] != "done":
            print(f"     └─ {r['last_error'].splitlines()[0][:160]}")
    return 0


def cmd_retry(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    s = find_session(cfg, q, a.session)
    if a.from_step:
        reset_from(s, a.from_step)
    q.reset(s.id)
    print(f"Reintentando {s.id}" + (f" desde {a.from_step}" if a.from_step else ""))
    return process_now_or_enqueue(cfg, q, s.id)


def cmd_resume(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    """Resume una sesión ya transcrita (sólo aquí se usa un LLM)."""
    s = find_session(cfg, q, a.session)
    if not s.transcript_json.is_file():
        print("La sesión aún no está transcrita; se transcribirá primero.")
    fields = {"summarize": True}
    if a.provider:
        fields["provider"] = a.provider
    if a.template:
        fields["template"] = a.template
    s.update_manifest(**fields)
    reset_from(s, "summarize")
    q.reset(s.id)
    print(f"Resumiendo {s.id} con {a.provider or s.manifest().get('provider') or cfg.summary.provider}…")
    return process_now_or_enqueue(cfg, q, s.id, copy=None if a.no_copy else "summary")


def cmd_forget(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    """Quita de la cola una sesión cuya carpeta se borró (la app la manda a la Papelera)."""
    print("Olvidada." if q.remove(a.session) else "No estaba en la cola.")
    return 0


def cmd_copy(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    s = find_session(cfg, q, a.session)
    f = s.summary_md if a.resumen else s.transcript_txt
    if not f.is_file():
        what = "resumen (usa: recorder resume " + s.id + ")" if a.resumen else "transcripción (aún en proceso)"
        raise SystemExit(f"No hay {what}.")
    if pbcopy(f):
        print(f"📋 Copiado: {f}")
        return 0
    print(f.read_text(encoding="utf-8"))
    return 0


def cmd_chunks(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    """Transcribe en segundo plano los bloques cerrados de una grabación en curso."""
    s = find_session(cfg, q, a.session)
    lock = WorkerLock(cfg.paths.home / "worker.lock")
    if not lock.acquire(wait_s=a.wait):
        print("Worker ocupado; los bloques se procesarán en la próxima pasada.")
        return 0
    try:
        process_live(s, cfg)
    except Exception as e:  # noqa: BLE001  (no es fatal: se reintenta con el siguiente bloque)
        log.warning("[%s] bloque en vivo falló: %s", s.id, e)
        return 1
    finally:
        lock.release()
    return 0


def cmd_once(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    lock = WorkerLock(cfg.paths.home / "worker.lock")
    if not lock.acquire(wait_s=a.wait):
        print("Ya hay un worker corriendo.")
        return 0
    try:
        q.recover_orphans()
        discover(cfg, q)
        n = drain(cfg, q)
    finally:
        lock.release()
    print(f"Sesiones procesadas: {n}")
    return 0


def cmd_run(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    run_forever(cfg, q)
    return 0


def cmd_set_key(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    from .providers import KEYCHAIN
    svc = KEYCHAIN[a.provider]
    print(f"Se guardará la API key de {a.provider} en el Llavero (servicio '{svc}').")
    print("macOS te pedirá la key a continuación (no se muestra al escribir):")
    # `-w` como último argumento hace que `security` la pida de forma interactiva,
    # así la key no aparece en la lista de procesos ni en el historial.
    res = subprocess.run(["security", "add-generic-password", "-U", "-s", svc, "-a", "recorder-jt", "-w"])
    if res.returncode == 0:
        print("✅ Guardada.")
    return res.returncode


def _local_status(cfg: Config) -> tuple[str, bool]:
    import httpx
    try:
        r = httpx.get(f"{cfg.local.base_url.rstrip('/')}/models", timeout=3)
        ids = [m["id"] for m in r.json().get("data", [])]
    except Exception:  # noqa: BLE001
        return "LM Studio no responde (abre LM Studio y activa el servidor)", False
    ok = any(cfg.local.model in i for i in ids)
    return (f"{cfg.local.model} disponible" if ok else f"{cfg.local.model} no está en LM Studio ({', '.join(ids) or 'sin modelos'})"), ok


# Cómo instalar lo que falte (la app lo ofrece en Configuración).
DOWNLOADS = {
    "whisper_model": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
    "fast_model": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
    "vad_model": "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
    "speakers_model": "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
                      "speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx",
    "segmentation_model": "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx",
}


def doctor_components(cfg: Config) -> list[dict]:
    """Estado de cada pieza necesaria para transcribir (para la app)."""
    ffmpeg = shutil.which("ffmpeg")
    vad = cfg.whisper.vad_model
    items = [
        {"id": "whisper_cli", "name": "Whisper (programa)", "detail": "Transcribe la voz a texto",
         "path": str(cfg.whisper.bin), "ok": cfg.whisper.bin.is_file(), "brew": "whisper-cpp"},
        # Basta con uno de los dos modelos: el otro queda como opcional.
        {"id": "whisper_model", "name": "Modelo de voz · calidad máxima", "detail": "large-v3 · ≈ 3,1 GB · el más preciso",
         "path": str(cfg.whisper.model), "ok": cfg.whisper.model.is_file(),
         "url": DOWNLOADS["whisper_model"], "size_mb": 3095, "optional": cfg.whisper.fast_model.is_file()},
        {"id": "fast_model", "name": "Modelo de voz · rápido", "detail": "large-v3-turbo · 574 MB · varias veces más rápido",
         "path": str(cfg.whisper.fast_model), "ok": cfg.whisper.fast_model.is_file(),
         "url": DOWNLOADS["fast_model"], "size_mb": 574, "optional": cfg.whisper.model.is_file() or not cfg.whisper.fast_model.is_file()},
        {"id": "vad_model", "name": "Detector de voz (Silero)", "detail": "Salta silencios y evita frases inventadas",
         "path": str(vad) if vad else "", "ok": bool(vad and vad.is_file()),
         "url": DOWNLOADS["vad_model"] if vad else None, "size_mb": 1},
        {"id": "ffmpeg", "name": "FFmpeg", "detail": "Convierte el audio y prepara la reproducción",
         "path": ffmpeg or "", "ok": bool(ffmpeg), "brew": "ffmpeg"},
    ]
    if cfg.speakers.enabled:
        items.append({"id": "speakers_model", "name": "Separar voces (WeSpeaker)",
                      "detail": "Distingue Persona 1, Persona 2…",
                      "path": str(cfg.speakers.model), "ok": cfg.speakers.model.is_file(),
                      "url": DOWNLOADS["speakers_model"], "size_mb": 26, "optional": True})
        items.append({"id": "segmentation_model", "name": "Cambios de voz (pyannote)",
                      "detail": "Corta donde cambia la persona y marca cuando hablan a la vez",
                      "path": str(cfg.speakers.segmentation), "ok": cfg.speakers.segmentation.is_file(),
                      "url": DOWNLOADS["segmentation_model"], "size_mb": 6, "optional": True})
    return items


def cmd_doctor(cfg: Config, q: Queue, a: argparse.Namespace) -> int:
    from .providers import api_key
    if getattr(a, "json", False):
        import json
        print(json.dumps({"components": doctor_components(cfg)}, ensure_ascii=False))
        return 0

    checks = [
        ("config", str(cfg.source or "(valores por defecto)"), True),
        ("whisper-cli", str(cfg.whisper.bin), cfg.whisper.bin.is_file()),
        ("modelo whisper", str(cfg.whisper.model), cfg.whisper.model.is_file() or cfg.whisper.fast_model.is_file()),
        ("modelo rápido", str(cfg.whisper.fast_model), True),
        ("modelo VAD", str(cfg.whisper.vad_model), bool(cfg.whisper.vad_model and cfg.whisper.vad_model.is_file())),
        ("ffmpeg", shutil.which("ffmpeg") or "no encontrado", bool(shutil.which("ffmpeg"))),
        ("separar voces", str(cfg.speakers.model) if cfg.speakers.enabled else "desactivado",
         (not cfg.speakers.enabled) or cfg.speakers.model.is_file()),
        ("cambios de voz", str(cfg.speakers.segmentation) if cfg.speakers.enabled else "desactivado",
         (not cfg.speakers.enabled) or cfg.speakers.segmentation.is_file()),
        ("glosario", str(cfg.whisper.glossary_file), bool(cfg.whisper.glossary_file and cfg.whisper.glossary_file.is_file())),
        ("sesiones", str(cfg.paths.sessions), cfg.paths.sessions.is_dir()),
        ("bandeja", str(cfg.paths.inbox), True),
    ]
    ok = True
    for name, val, good in checks:
        ok &= good
        print(f"{'✅' if good else '❌'} {name:18} {val}")
    print(f"\nResumen: {'automático' if cfg.summary.auto else 'sólo con `recorder resume`'} · "
          f"proveedor por defecto: {cfg.summary.provider}")
    local_msg, local_ok = _local_status(cfg)
    providers = [
        ("deepseek", "API key en Llavero" if api_key("deepseek") else "sin API key → recorder set-key deepseek", bool(api_key("deepseek"))),
        ("local", local_msg, local_ok),
        ("claude", "API key configurada" if api_key("claude") else "sin API key → recorder set-key claude", bool(api_key("claude"))),
    ]
    for name, val, good in providers:
        mark = "✅" if good else ("❌" if name == cfg.summary.provider else "➖")
        print(f"{mark} {name:18} {val}")
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="recorder", description="Transcribe y resume sesiones grabadas.")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--config", type=Path)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("import", help="importar un audio y procesarlo")
    sp.add_argument("file")
    sp.add_argument("--title")
    sp.add_argument("--mic", help="pista separada de tu micrófono (el archivo principal queda como 'Participantes')")
    sp.add_argument("--mic-offset", default=0.0, type=float, help="segundos de retraso de la pista mic")
    sp.add_argument("--language", help="es, en, auto…")
    sp.add_argument("--quality", choices=["max", "fast"], help="max = large-v3; fast = turbo (más rápido)")
    sp.add_argument("--template", help="plantilla de resumen (config/templates/<nombre>.md)")
    sp.add_argument("--resume", action="store_true", help="además de transcribir, resumir con un LLM")
    sp.add_argument("--provider", choices=PROVIDERS, help="proveedor del resumen (deepseek, local, claude)")
    sp.add_argument("--no-copy", action="store_true", help="no copiar el resultado al portapapeles")
    sp.add_argument("--queue-only", action="store_true", help="dejar en cola para el worker")
    sp.set_defaults(fn=cmd_import)

    sp = sub.add_parser("status", help="estado de la cola")
    sp.add_argument("-n", "--limit", type=int, default=20)
    sp.set_defaults(fn=cmd_status)

    sp = sub.add_parser("retry", help="reintentar una sesión")
    sp.add_argument("session")
    sp.add_argument("--from", dest="from_step", choices=STEP_NAMES)
    sp.set_defaults(fn=cmd_retry)

    sp = sub.add_parser("resume", help="resumir una sesión (único comando que usa un LLM)")
    sp.add_argument("session", nargs="?", default="last", help="id de sesión o 'last' (por defecto)")
    sp.add_argument("--provider", choices=PROVIDERS)
    sp.add_argument("--template", help="general, comercial, tecnica, one-on-one…")
    sp.add_argument("--no-copy", action="store_true")
    sp.set_defaults(fn=cmd_resume)

    sp = sub.add_parser("copy", help="copiar transcripción (o resumen) al portapapeles")
    sp.add_argument("session", nargs="?", default="last")
    sp.add_argument("--resumen", action="store_true", help="copiar el resumen en vez de la transcripción")
    sp.set_defaults(fn=cmd_copy)

    sp = sub.add_parser("forget", help="quitar de la cola una sesión borrada")
    sp.add_argument("session")
    sp.set_defaults(fn=cmd_forget)
    sp = sub.add_parser("once", help="procesar lo pendiente y salir")
    sp.add_argument("--wait", type=float, default=1800, help="segundos a esperar si otro proceso está trabajando")
    sp.set_defaults(fn=cmd_once)

    sp = sub.add_parser("chunks", help="transcribir los bloques cerrados de una grabación en curso")
    sp.add_argument("session")
    sp.add_argument("--wait", type=float, default=1800)
    sp.set_defaults(fn=cmd_chunks)
    sub.add_parser("run", help="worker continuo (para launchd)").set_defaults(fn=cmd_run)
    sp = sub.add_parser("set-key", help="guardar una API key en el Llavero de macOS")
    sp.add_argument("provider", nargs="?", default="deepseek", choices=["deepseek", "claude"])
    sp.set_defaults(fn=cmd_set_key)
    sp = sub.add_parser("doctor", help="verificar dependencias y configuración")
    sp.add_argument("--json", action="store_true", help="estado en JSON (para la app)")
    sp.set_defaults(fn=cmd_doctor)

    a = p.parse_args(argv)
    cfg = load_config(a.config)
    setup_logging(cfg, a.verbose)
    q = Queue(cfg.paths.db)
    return a.fn(cfg, q, a)


if __name__ == "__main__":
    sys.exit(main())
