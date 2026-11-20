"""Genera una reunión sintética de dos pistas con `say` (macOS) + ffmpeg.

Salida (en OUT_DIR):
  mic.wav     -> voz "Yo" + eco atenuado de los participantes (simula altavoces)
  system.wav  -> voces de los participantes
  manifest.json

Uso: python scripts/make_dialog.py OUT_DIR [--repeat N] [--echo]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

DIALOG = [
    ("yo", "Paulina", "Buenos días a todos. Empecemos con la revisión del lanzamiento de la aplicación móvil."),
    ("otros", "Eddy (Español (México))", "Gracias. El equipo de backend terminó la integración con el sistema de pagos el viernes."),
    ("yo", "Paulina", "Perfecto. ¿Qué pasó con las pruebas de carga? La semana pasada teníamos errores con más de mil usuarios."),
    ("otros", "Flo (Español (México))", "Las repetimos ayer. Ahora soporta cinco mil usuarios concurrentes sin errores, pero la latencia sube a dos segundos."),
    ("yo", "Paulina", "Dos segundos es demasiado. Carlos, ¿puedes revisar las consultas a la base de datos antes del jueves?"),
    ("otros", "Eddy (Español (México))", "Sí, me encargo. Creo que falta un índice en la tabla de transacciones."),
    ("yo", "Paulina", "Bien. Entonces decidimos mover el lanzamiento al quince de diciembre para tener margen."),
    ("otros", "Flo (Español (México))", "De acuerdo. Yo preparo el comunicado para marketing y lo envío el lunes."),
    ("yo", "Paulina", "Una pregunta abierta: ¿necesitamos aprobación de seguridad antes de publicar en la tienda?"),
    ("otros", "Eddy (Español (México))", "No estoy seguro. Lo consulto con el equipo de seguridad y les aviso."),
]
GAP = 0.6  # segundos entre turnos
SR = 16000


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, capture_output=True)


def duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return float(out.strip())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--repeat", type=int, default=1, help="repetir el diálogo N veces (audios largos)")
    ap.add_argument("--echo", action="store_true", help="añadir eco de los participantes en el mic")
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmpd = Path(tmp)
        clips: list[tuple[str, Path, float]] = []  # (track, file, start)
        t = 1.0
        for r in range(args.repeat):
            for i, (track, voice, text) in enumerate(DIALOG):
                f = tmpd / f"{r:03d}_{i:02d}.aiff"
                run(["say", "-v", voice, "-o", str(f), text])
                clips.append((track, f, t))
                t += duration(f) + GAP
        total = t + 1.0

        def build(track_files: list[tuple[Path, float, float]], out: Path) -> None:
            # track_files: (file, start_s, gain)
            inputs: list[str] = []
            filters: list[str] = []
            for k, (f, start, gain) in enumerate(track_files):
                inputs += ["-i", str(f)]
                ms = int(start * 1000)
                filters.append(f"[{k}:a]aresample={SR},adelay={ms}:all=1,volume={gain}[a{k}]")
            mix = "".join(f"[a{k}]" for k in range(len(track_files)))
            filters.append(
                f"{mix}amix=inputs={len(track_files)}:normalize=0,apad=whole_dur={total}[out]"
            )
            run(["ffmpeg", "-y", *inputs, "-filter_complex", ";".join(filters),
                 "-map", "[out]", "-ac", "1", "-ar", str(SR), str(out)])

        mic = [(f, s, 1.0) for tr, f, s in clips if tr == "yo"]
        if args.echo:
            mic += [(f, s + 0.05, 0.25) for tr, f, s in clips if tr == "otros"]
        system = [(f, s, 1.0) for tr, f, s in clips if tr == "otros"]
        build(mic, args.out_dir / "mic.wav")
        build(system, args.out_dir / "system.wav")

    manifest = {
        "id": "fixture",
        "title": "Revisión lanzamiento app (sintético)",
        "status": "recorded",
        "language": "es",
        "tracks": {
            "mic": {"file": "mic.wav", "first_host_time_s": 0.0},
            "system": {"file": "system.wav", "first_host_time_s": 0.0},
        },
    }
    (args.out_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"OK: {args.out_dir} ({total:.1f}s)")


if __name__ == "__main__":
    main()
