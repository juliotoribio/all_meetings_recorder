"""Pipeline de punta a punta con whisper REAL y Claude simulado."""

import shutil
from pathlib import Path

import pytest

from recorder_worker import pipeline, providers
from recorder_worker.config import Config, Paths
from recorder_worker.queue import Queue
from recorder_worker.session import Session
from recorder_worker.steps import summarize as summ
from recorder_worker.util import StepError, read_json

FIXTURE = Path(__file__).parent / "fixtures" / "dialog"


def fake_resumen(*_a, **_k):
    return summ.Resumen(
        titulo_sugerido="Revisión de lanzamiento",
        resumen_ejecutivo="Se revisó el lanzamiento.",
        participantes_mencionados=["Carlos"],
        temas=[summ.Tema(titulo="Pruebas de carga", inicio="00:00:12", puntos_clave=["5.000 usuarios"])],
        decisiones=["Mover el lanzamiento al 15 de diciembre"],
        action_items=[summ.ActionItem(tarea="Revisar consultas", responsable="Carlos",
                                      fecha_limite="jueves", timestamp="00:00:27")],
        preguntas_abiertas=["¿Aprobación de seguridad?"],
        riesgos=["Latencia de 2 s"],
    )


@pytest.fixture
def env(tmp_path, monkeypatch):
    cfg = Config(paths=Paths(home=tmp_path / "home"))
    cfg.worker.notify = False
    cfg.paths.ensure()
    sdir = cfg.paths.sessions / "2026-11-17_1003_test_ab12"
    shutil.copytree(FIXTURE, sdir)
    calls = []
    monkeypatch.setattr(providers, "generate", lambda *a, **k: calls.append(a[1]) or fake_resumen())
    q = Queue(cfg.paths.db)
    s = Session(sdir)
    s.calls = calls
    return cfg, q, s


@pytest.mark.slow
def test_end_to_end(env):
    cfg, q, s = env
    s.update_manifest(summarize=True, provider="local")
    assert pipeline.discover(cfg, q) == 1
    assert pipeline.process_job(cfg, q, s.id)
    assert q.get(s.id)["status"] == "done"

    t = read_json(s.transcript_json)
    speakers = {x["speaker"] for x in t["segments"]}
    assert speakers == {"Yo", "Persona 1", "Persona 2"}  # 2 voces distintas del otro lado
    assert t["echo_removed"] >= 3  # el fixture tiene eco de los participantes en el mic
    mine = " ".join(x["text"] for x in t["segments"] if x["speaker"] == "Yo").lower()
    assert "carga" in mine and "diciembre" in mine
    assert "transacciones" not in mine  # eso lo dijo un participante: no debe quedar como "Yo"

    md = s.summary_md.read_text()
    assert "## Action items" in md and "Carlos" in md and "local" in md
    assert s.calls == ["local"]
    exported = list(cfg.paths.inbox.glob("*.md"))
    assert len(exported) == 1 and "Revisión de lanzamiento" in exported[0].name


@pytest.mark.slow
def test_resume_after_crash_does_not_redo_work(env, monkeypatch):
    cfg, q, s = env
    s.update_manifest(summarize=True)
    pipeline.discover(cfg, q)

    def boom(*_a, **_k):
        raise StepError("API caída")

    monkeypatch.setattr(providers, "generate", boom)
    assert not pipeline.process_job(cfg, q, s.id)
    job = q.get(s.id)
    assert job["status"] == "pending" and job["attempts"] == 1 and job["step"] == "summarize"
    seg_mtime = s.segments("mic").stat().st_mtime

    # vuelve la API: se retoma en summarize sin re-transcribir
    monkeypatch.setattr(providers, "generate", lambda *a, **k: fake_resumen())
    q.reset(s.id)
    assert pipeline.process_job(cfg, q, s.id)
    assert s.segments("mic").stat().st_mtime == seg_mtime


def test_silent_session_fails_permanently(env):
    cfg, q, s = env
    for name in ("mic.wav", "system.wav"):
        import subprocess
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                        "-t", "5", str(s.path / name)], check=True)
    pipeline.discover(cfg, q)
    assert not pipeline.process_job(cfg, q, s.id)
    assert q.get(s.id)["status"] == "failed"
    assert "ninguna pista" in q.get(s.id)["last_error"]


@pytest.mark.slow
def test_turn_order_matches_dialog(env):
    """Con el mapa VAD, los turnos quedan en el orden real de la conversación."""
    cfg, q, s = env
    pipeline.discover(cfg, q)
    assert pipeline.process_job(cfg, q, s.id)
    segs = read_json(s.transcript_json)["segments"]
    turns = []
    for x in segs:  # agrupar turnos consecutivos (cualquier Persona N = la otra parte)
        who = "Otros" if x["speaker"].startswith("Persona") else x["speaker"]
        if not turns or turns[-1] != who:
            turns.append(who)
    expected = ["Yo", "Otros"] * 5
    assert turns == expected, turns


@pytest.mark.slow
def test_chunk_fallback_when_full_track_fails(env, tmp_path):
    """Si whisper falla con la pista completa, se transcribe por bloques."""
    cfg, q, s = env
    real_bin = cfg.whisper.bin
    wrapper = tmp_path / "whisper-cli"
    # falla con archivos que no son bloques (c0000.wav…), delega el resto
    wrapper.write_text(f'#!/bin/sh\ncase "$*" in *"/c0"*) exec "{real_bin}" "$@";; esac\nexit 3\n')
    wrapper.chmod(0o755)
    (tmp_path / "whisper-vad-speech-segments").symlink_to(real_bin.parent / "whisper-vad-speech-segments")
    cfg.whisper.bin = wrapper
    cfg.whisper.chunk_minutes = 1
    pipeline.discover(cfg, q)
    assert pipeline.process_job(cfg, q, s.id)
    assert any(s.work.glob("system.chunks/c0000.json"))
    text = " ".join(x["text"] for x in read_json(s.transcript_json)["segments"]).lower()
    assert "seguridad" in text  # la última frase (en el 2º bloque) está


@pytest.mark.slow
def test_default_only_transcribes_then_resume_on_demand(env):
    """Por defecto no se llama a ningún LLM; `resume` lo hace bajo pedido."""
    cfg, q, s = env
    pipeline.discover(cfg, q)
    assert pipeline.process_job(cfg, q, s.id)
    assert s.calls == [] and not s.summary_md.exists()
    txt = s.transcript_txt.read_text()
    assert "] Yo: Buenos días" in txt and "**" not in txt  # texto plano copiable
    exported = list(cfg.paths.inbox.glob("*.md"))
    assert len(exported) == 1 and "(transcripción)" in exported[0].name

    # recorder resume --provider deepseek (sin re-transcribir)
    seg_mtime = s.segments("mic").stat().st_mtime
    s.update_manifest(summarize=True, provider="deepseek")
    pipeline.reset_from(s, "summarize")
    q.reset(s.id)
    assert pipeline.process_job(cfg, q, s.id)
    assert s.calls == ["deepseek"] and s.summary_md.is_file()
    assert s.segments("mic").stat().st_mtime == seg_mtime


def _cut_in_silence(cfg, wavs, near_s):
    """Instante cercano a `near_s` donde ninguna pista tiene voz."""
    from recorder_worker.steps.transcribe import vad_intervals
    speech = [iv for w in wavs for iv in vad_intervals(cfg, w)]
    t = near_s
    while any(a - 0.15 <= t <= b + 0.15 for a, b in speech):
        t += 0.05
    return round(t, 2)


@pytest.mark.slow
def test_chunked_recording_live_then_final(env):
    """Grabación por bloques: el 1º se transcribe mientras se graba; al detener sólo falta el último."""
    import subprocess

    cfg, q, s = env
    mic, system = s.path / "mic.wav", s.path / "system.wav"
    cut = _cut_in_silence(cfg, [mic, system], 30.0)
    (s.path / "chunks").mkdir()
    for name, src in (("mic", mic), ("system", system)):
        for i, (ss, to) in enumerate(((0, cut), (cut, None))):
            out = s.path / "chunks" / f"{name}_{i:03d}.wav"
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-ss", str(ss)]
            cmd += (["-to", str(to)] if to else []) + [str(out)]
            subprocess.run(cmd, check=True)
        src.unlink()

    def track(name, i, t0):
        return {"file": f"chunks/{name}_{i:03d}.wav", "first_host_time_s": 1000.0 + t0}

    # 1) grabando: sólo el bloque 0 está cerrado
    s.update_manifest(status="recording", tracks={"mic.000": track("mic", 0, 0), "system.000": track("system", 0, 0)})
    pipeline.process_live(s, cfg)
    partial = s.transcript_txt.read_text()
    assert "Buenos días" in partial and "seguridad" not in partial  # sólo la 1ª parte
    seg0 = s.segments("mic.000").stat().st_mtime

    # 2) detener: llega el último bloque y la sesión pasa a "recorded"
    m = s.manifest()
    m["tracks"].update({"mic.001": track("mic", 1, cut), "system.001": track("system", 1, cut)})
    s.update_manifest(status="recorded", tracks=m["tracks"])
    pipeline.discover(cfg, q)
    assert pipeline.process_job(cfg, q, s.id)
    assert s.segments("mic.000").stat().st_mtime == seg0  # el bloque 0 no se re-transcribió

    segs = read_json(s.transcript_json)["segments"]
    turns = []
    for x in segs:
        who = "Otros" if x["speaker"].startswith("Persona") else x["speaker"]
        if not turns or turns[-1] != who:
            turns.append(who)
    assert turns == ["Yo", "Otros"] * 5, turns
    assert "seguridad" in s.transcript_txt.read_text()
    assert read_json(s.transcript_json)["echo_removed"] >= 3



@pytest.mark.slow
def test_each_remote_voice_keeps_its_number(env):
    """Las 2 voces del sistema (Eddy y Flo) quedan separadas y estables."""
    import sys
    sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
    from make_dialog import DIALOG
    from rapidfuzz import fuzz

    cfg, q, s = env
    pipeline.discover(cfg, q)
    assert pipeline.process_job(cfg, q, s.id)
    theirs = [(t, v) for tr, v, t in DIALOG if tr == "otros"]
    voice_to_label = {}
    for x in read_json(s.transcript_json)["segments"]:
        if not x["speaker"].startswith("Persona") or len(x["text"]) < 10:
            continue
        text, voice = max(theirs, key=lambda tv: fuzz.partial_ratio(x["text"], tv[0]))
        voice_to_label.setdefault(voice, set()).add(x["speaker"])
    assert all(len(v) == 1 for v in voice_to_label.values()), voice_to_label  # cada voz, un número
    assert len({next(iter(v)) for v in voice_to_label.values()}) == 2         # y números distintos
