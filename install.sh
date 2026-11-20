#!/bin/zsh
# All Meetings Recorder — instalación en este Mac.
#
#   ./install.sh            instala dependencias, el worker y la app
#   ./install.sh --models        además descarga los modelos (calidad máxima, ≈ 3,1 GB)
#   ./install.sh --models-fast   o sólo el modelo rápido (turbo, 574 MB: Macs de 8 GB o poco disco)
#
# Se puede volver a ejecutar cuando quieras (actualiza lo que haga falta).
# Si mueves esta carpeta, vuelve a ejecutarlo: la app apunta al worker de aquí.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"
MODELS="$HOME/RecorderJT/models"

ok()   { print -P "%F{green}✓%f $1"; }
step() { print -P "\n%F{cyan}▸%f %B$1%b"; }
fail() { print -P "%F{red}✗%f $1"; exit 1; }

step "Comprobando el Mac"
[[ "$(uname -m)" == "arm64" ]] || print -P "%F{yellow}!%f Mac con Intel: funcionará, pero la transcripción será muy lenta."
ver="$(sw_vers -productVersion)"
autoload -Uz is-at-least
is-at-least 14.4 "$ver" || fail "Hace falta macOS 14.4 o más nuevo (tienes $ver): es lo que permite grabar el audio de Teams/Zoom/Meet."
ok "macOS $ver"
ram=$(( $(sysctl -n hw.memsize) / 1073741824 ))
(( ram >= 16 )) || print -P "%F{yellow}!%f ${ram} GB de RAM: funciona, pero cierra otras apps pesadas mientras transcribe."
ok "${ram} GB de RAM"

if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  fail "Instala las herramientas de línea de comandos de Xcode (se abrió la ventana) y vuelve a ejecutar ./install.sh"
fi
ok "Herramientas de Xcode"

BREW="$(command -v brew || true)"
[[ -z "$BREW" && -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
[[ -z "$BREW" && -x /usr/local/bin/brew ]] && BREW=/usr/local/bin/brew
[[ -n "$BREW" ]] || fail "Falta Homebrew. Instálalo desde https://brew.sh/es/ y vuelve a ejecutar ./install.sh"
eval "$("$BREW" shellenv)"
ok "Homebrew"

step "Programas: whisper, ffmpeg y uv"
export PATH="$HOME/.local/bin:$PATH"   # uv instalado con su propio instalador
for pair in whisper-cli:whisper-cpp ffmpeg:ffmpeg uv:uv; do
  cmd="${pair%%:*}" formula="${pair##*:}"
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd ya instalado"
  else "$BREW" install "$formula"; ok "$cmd instalado"; fi
done

step "Worker de transcripción (Python)"
(cd worker && uv sync --quiet --inexact)
ok "worker listo: $REPO/worker/.venv/bin/recorder"

if [[ "${1:-}" == "--models" || "${1:-}" == "--models-fast" ]]; then
  step "Modelos"
  mkdir -p "$MODELS"
  get() {
    [[ -f "$MODELS/$1" ]] && { ok "$1 ya descargado"; return; }
    curl -L --fail --progress-bar -o "$MODELS/$1.part" "$2" && mv "$MODELS/$1.part" "$MODELS/$1"
    ok "$1"
  }
  get ggml-silero-v6.2.0.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
  get wespeaker_en_voxceleb_resnet34.onnx https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx
  get pyannote-segmentation-3.0.onnx https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx
  if [[ "$1" == "--models-fast" ]]; then
    get ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
  else
    get ggml-large-v3.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin
  fi
fi

step "App"
recorder-app/scripts/bundle_app.sh
open "$HOME/Applications/All Meetings Recorder.app"

print -P "\n%F{green}%BListo.%b%f All Meetings Recorder está en ~/Applications."
[[ -f "$MODELS/ggml-large-v3.bin" || -f "$MODELS/ggml-large-v3-turbo-q5_0.bin" ]] || print "Falta un paso: en la app abre Configuración (⌘,) y pulsa Descargar en los modelos."
print "La primera vez macOS pedirá permiso para el micrófono y para grabar el audio del sistema."
