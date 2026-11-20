from pathlib import Path

from recorder_worker.config import Config, Paths
from recorder_worker.queue import Queue
from recorder_worker.steps.merge import is_echo, merge_tracks, to_markdown
from recorder_worker.steps.transcribe import _split_segment, clean_segments, is_hallucination


def tok(text, a, b):
    return {"text": text, "offsets": {"from": a, "to": b}}


def test_split_segment_projects_vad_timeline():
    # Segmento real 10s-20s; tokens en línea de tiempo VAD (0-1000ms)
    seg = {
        "offsets": {"from": 10000, "to": 20000},
        "text": " Hola a todos. Empecemos la reunión ahora.",
        "tokens": [tok("[_BEG_]", 0, 0), tok(" Hola", 0, 100), tok(" a", 100, 200), tok(" todos", 200, 400),
                   tok(".", 400, 500), tok(" Empecemos", 500, 700), tok(" la", 700, 800),
                   tok(" reunión", 800, 900), tok(" ahora", 900, 950), tok(".", 950, 1000)],
    }
    parts = _split_segment(seg)
    assert [p["text"] for p in parts] == ["Hola a todos.", "Empecemos la reunión ahora."]
    assert parts[0]["start"] == 10.0 and parts[-1]["end"] == 20.0
    assert 14.0 < parts[1]["start"] < 16.0  # 500/1000 → mitad del rango


def test_split_does_not_cut_numbers():
    seg = {"offsets": {"from": 0, "to": 3000}, "text": " Soporta 5.000 usuarios sin errores.",
           "tokens": [tok(" Soporta", 0, 100), tok(" 5", 100, 200), tok(".", 200, 250), tok("000", 250, 300),
                      tok(" usuarios", 300, 400), tok(" sin", 400, 500), tok(" errores", 500, 600), tok(".", 600, 700)]}
    assert [p["text"] for p in _split_segment(seg)] == ["Soporta 5.000 usuarios sin errores."]


def test_hallucinations_and_repeats():
    assert is_hallucination("Subtítulos realizados por la comunidad de Amara.org")
    assert is_hallucination("¡Gracias por ver el video!")
    assert is_hallucination("[BLANK_AUDIO]")
    assert not is_hallucination("Gracias por ver el informe, Carlos, lo revisamos el jueves.")
    segs = [{"start": i, "end": i + 1, "text": "Vale."} for i in range(5)]
    assert len(clean_segments(segs)) == 2


def test_echo_removed_but_real_speech_kept():
    system = [{"start": 6.9, "end": 11.8, "text": "Gracias. El equipo de backend terminó la integración."}]
    echo = {"start": 6.3, "end": 11.8, "text": "Gracias, el equipo de backend terminó la integración."}
    mine = {"start": 12.0, "end": 15.0, "text": "Perfecto, ¿y las pruebas de carga?"}
    short = {"start": 7.0, "end": 7.5, "text": "Sí."}
    assert is_echo(echo, system)
    assert not is_echo(mine, system)
    assert not is_echo(short, system)
    merged, n = merge_tracks({"mic": [echo, mine], "system": system})
    assert n == 1
    assert [m["speaker"] for m in merged] == ["Participantes", "Yo"]


def test_markdown_groups_turns():
    segs = [{"start": 0, "end": 2, "speaker": "Yo", "text": "Hola."},
            {"start": 2.5, "end": 4, "speaker": "Yo", "text": "¿Empezamos?"},
            {"start": 5, "end": 6, "speaker": "Participantes", "text": "Sí."}]
    md = to_markdown("T", segs)
    assert "**[00:00:00] Yo:** Hola. ¿Empezamos?" in md
    assert "**[00:00:05] Participantes:** Sí." in md


def test_queue_lifecycle(tmp_path: Path):
    q = Queue(tmp_path / "q.db")
    assert q.add("s1", tmp_path)
    assert not q.add("s1", tmp_path)  # idempotente
    assert q.next_ready()["session_id"] == "s1"
    q.running("s1", "transcribe")
    assert q.recover_orphans() == 1  # worker murió → vuelve a pending
    q.retry_later("s1", "boom", attempts=1, delay_s=3600)
    assert q.next_ready() is None  # en backoff
    q.reset("s1")
    q.done("s1")
    assert q.get("s1")["status"] == "done"


def test_config_defaults(tmp_path: Path):
    cfg = Config(paths=Paths(home=tmp_path))
    assert cfg.paths.sessions == tmp_path / "sessions"
    assert cfg.claude.model == "claude-opus-5-5"


def test_vad_map_exact():
    from recorder_worker.steps.transcribe import VadMap
    vm = VadMap([(6.98, 7.65), (7.94, 11.93), (20.35, 21.57)])
    assert vm.real(0.0) == 6.98
    assert abs(vm.real(0.87) - 7.94) < 1e-6  # 0.67 de voz + 0.2 de solape → 2º intervalo
    assert abs(vm.real(5.06) - 20.35) < 1e-6  # 3er intervalo
    assert abs(vm.real(5.2) - 20.49) < 1e-6
    assert abs(vm.real(4.95, snap_forward_s=0.25) - 20.35) < 1e-6
    # palabra cuyo inicio cae en el intervalo previo pero termina en el siguiente
    assert abs(vm.real_start(4.70, 5.30) - 20.35) < 1e-6
    # palabra que termina justo antes del siguiente intervalo → pertenece a él
    assert abs(vm.real_start(4.70, 4.85) - 20.35) < 1e-6
    # palabra normal dentro de un intervalo
    assert abs(vm.real_start(1.0, 1.5) - 8.07) < 1e-6


def test_provider_json_parsing():
    from recorder_worker.providers import _parse
    raw = ('<think>pensando…</think>Aquí va: {"titulo_sugerido":"T","resumen_ejecutivo":"R",'
           '"participantes_mencionados":[],"temas":[],"decisiones":["D"],"action_items":[],'
           '"preguntas_abiertas":[],"riesgos":[]}')
    assert _parse(raw).decisiones == ["D"]


def test_audio_echo_detection():
    """El eco sigue la envolvente del sistema con retraso; la voz propia no."""
    import numpy as np
    from recorder_worker.steps.echo import TrackEnvelope, echo_score

    rng = np.random.default_rng(0)
    n = 500  # 10 s en tramas de 20 ms
    system = np.where(rng.random(n) > 0.4, -20 + 8 * rng.standard_normal(n), -70).astype(np.float32)
    echo = np.concatenate([np.full(5, -80), system[:-5] - 18]).astype(np.float32)  # 100 ms tarde, más bajo
    own = np.where(rng.random(n) > 0.5, -25 + 6 * rng.standard_normal(n), -75).astype(np.float32)
    sys_e = TrackEnvelope([(0.0, system)])
    assert echo_score(TrackEnvelope([(0.0, echo)]), sys_e, 1.0, 8.0) > 0.9
    assert echo_score(TrackEnvelope([(0.0, own)]), sys_e, 1.0, 8.0) < 0.3
    # sistema en silencio: nunca es eco
    quiet = TrackEnvelope([(0.0, np.full(n, -100, np.float32))])
    assert echo_score(TrackEnvelope([(0.0, own)]), quiet, 1.0, 8.0) == 0.0


def test_speakers_chunk_without_voiceprints(tmp_path: Path):
    """Un bloque sin frases largas (silencio, sólo "Sí.") no debe romper la sesión."""
    import json
    import wave

    import numpy as np
    import pytest

    from recorder_worker.config import load_config
    from recorder_worker.session import Session
    from recorder_worker.steps.speakers import assign_speakers, embed_track, enabled

    cfg = load_config()
    if not enabled(cfg):
        pytest.skip("modelo de voces no instalado")
    (tmp_path / "work").mkdir()
    (tmp_path / "manifest.json").write_text(json.dumps({"id": "t", "tracks": {}}))
    s = Session(tmp_path)
    with wave.open(str(s.wav16k("system.000")), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(np.zeros(16000 * 3, dtype=np.int16).tobytes())
    segs = [{"start": 0.5, "end": 0.9, "text": "Sí."}]
    s.segments("system.000").write_text(json.dumps({"segments": segs}))
    embed_track(cfg, s, "system.000")
    data = np.load(s.work / "system.000.emb.npz")
    assert len(data["idx"]) == 0
    assert assign_speakers(cfg, s, {"system.000": segs}) == 0


def test_cut_points_auto_language():
    from recorder_worker.steps.transcribe import cut_points

    # corto: no se corta
    assert cut_points([(0, 100)], 200, target_s=180) == []
    # corta en mitad del primer silencio a partir de ~180 s
    iv = [(0, 170), (175, 190), (194, 400), (402, 600)]
    assert cut_points(iv, 600, target_s=180) == [192.0, 401.0]
    # sin silencios: corte fijo
    assert cut_points([(0, 600)], 600, target_s=180) == [180, 360]
    assert cut_points([], 600, target_s=180) == [180, 360]


def test_glossary_prompt_language(tmp_path):
    from recorder_worker.config import load_config
    from recorder_worker.steps.transcribe import glossary_prompt

    cfg = load_config()
    g = tmp_path / "g.txt"
    g.write_text("Laura\nOKR\n", encoding="utf-8")
    cfg.whisper.glossary_file = g
    assert glossary_prompt(cfg, "es") == "Glosario: Laura, OKR."
    assert glossary_prompt(cfg, "auto") == "Laura, OKR."


def test_split_by_turns_cuts_at_speaker_change_and_marks_overlap():
    from recorder_worker.steps.speakers import rejoin, split_by_turns

    words = [[0.0, 0.4, "Creo"], [0.4, 0.8, "que"], [0.8, 1.2, "sí."], [1.3, 1.7, "Pues"],
             [1.7, 2.1, "yo"], [2.1, 2.5, "no"], [2.5, 2.9, "estoy"], [2.9, 3.3, "seguro."]]
    seg = {"start": 0.0, "end": 3.3, "text": "Creo que sí. Pues yo no estoy seguro.", "words": words}
    turns = [(0.0, 1.25, 0), (1.25, 3.4, 1), (2.0, 3.4, 0)]  # al final hablan los dos
    out = split_by_turns([seg], turns)
    assert [x["text"] for x in out] == ["Creo que sí.", "Pues yo no estoy seguro."]
    assert out[1].get("overlap") and not out[0].get("overlap")
    assert all("words" not in x for x in out)
    # si al final resultan ser la misma voz, la frase vuelve a quedar entera
    for x in out:
        x["speaker"] = "Persona 1"
    assert [x["text"] for x in rejoin(out)] == ["Creo que sí. Pues yo no estoy seguro."]


def test_split_by_turns_ignores_tiny_fragments():
    from recorder_worker.steps.speakers import split_by_turns

    words = [[0.0, 0.3, "Vale,"], [0.3, 0.7, "lo"], [0.7, 1.1, "reviso"], [1.1, 1.5, "mañana."]]
    seg = {"start": 0.0, "end": 1.5, "text": "Vale, lo reviso mañana.", "words": words}
    out = split_by_turns([seg], [(0.0, 0.25, 0), (0.25, 1.6, 1)])
    assert [x["text"] for x in out] == ["Vale, lo reviso mañana."]


def test_voice_memory_recalls_named_voice(tmp_path):
    import json

    import numpy as np

    from recorder_worker.config import load_config
    from recorder_worker.session import Session
    from recorder_worker.steps.speakers import load_profiles, recall

    cfg = load_config()
    cfg.paths.sessions = tmp_path
    rng = np.random.default_rng(0)
    laura, carlos = rng.normal(size=192), rng.normal(size=192)
    old = tmp_path / "old"
    (old / "work").mkdir(parents=True)
    (old / "work" / "voices.json").write_text(json.dumps({"Persona 1": laura.tolist(), "Persona 2": carlos.tolist()}))
    (old / "manifest.json").write_text(json.dumps({"speaker_names": {"Persona 1": "Laura"}}))
    assert set(load_profiles(cfg)) == {"Laura"}  # Persona 2 sin nombre: no se recuerda

    new = tmp_path / "new"
    (new / "work").mkdir(parents=True)
    (new / "manifest.json").write_text("{}")
    unit = lambda v: v / np.linalg.norm(v)  # noqa: E731
    cents = {0: unit(carlos), 1: unit(laura + rng.normal(scale=0.3, size=192))}
    assert recall(cfg, Session(new), cents) == {1: "Laura"}


def test_pick_model_by_quality(tmp_path):
    import pytest

    from recorder_worker.config import load_config
    from recorder_worker.steps.transcribe import pick_model
    from recorder_worker.util import PermanentError

    cfg = load_config()
    cfg.whisper.model, cfg.whisper.fast_model = tmp_path / "large.bin", tmp_path / "turbo.bin"
    with pytest.raises(PermanentError):
        pick_model(cfg, "max")
    cfg.whisper.fast_model.write_bytes(b"x")          # sólo el rápido: se usa siempre
    assert pick_model(cfg, "max") == cfg.whisper.fast_model
    cfg.whisper.model.write_bytes(b"x")               # los dos: según la calidad
    assert pick_model(cfg, "max") == cfg.whisper.model
    assert pick_model(cfg, "fast") == cfg.whisper.fast_model
