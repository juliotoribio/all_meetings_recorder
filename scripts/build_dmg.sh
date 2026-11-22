#!/bin/zsh
# Arma «All Meetings Recorder.app» autocontenida y su .dmg, para quien no use la Terminal.
#
#   scripts/build_dmg.sh            todo: dependencias (si faltan), app y .dmg
#   scripts/build_dmg.sh deps       sólo compila Whisper y FFmpeg (build/vendor/bin)
#   scripts/build_dmg.sh app        sólo arma la app (build/All Meetings Recorder.app)
#
# Dentro de la app van: el ejecutable de Swift, Whisper (whisper-cli con Metal),
# FFmpeg/FFprobe (sólo códecs propios, sin librerías externas), un Python
# independiente con el worker y sus dependencias, y config/ (plantillas, glosario).
# Los modelos de voz NO van dentro: se descargan desde la app (Configuración).
#
# La app se firma «ad hoc» (sin cuenta de Apple): la primera vez macOS pide
# «Abrir igualmente» en Ajustes del Sistema → Privacidad y seguridad.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
BUILD="$REPO/build"
VENDOR="$BUILD/vendor"
CACHE="$BUILD/cache"
APP="$BUILD/All Meetings Recorder.app"
DMG="$BUILD/AllMeetingsRecorder.dmg"
PY_VERSION="${PY_VERSION:-3.12}"
WHISPER_VERSION="${WHISPER_VERSION:-1.9.5}"
FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=14.0

step() { print -P "\n%F{cyan}▸%f %B$1%b"; }
ok()   { print -P "%F{green}✓%f $1"; }

fetch() {  # fetch <url> <archivo>
  [[ -f "$CACHE/$2" ]] && return
  mkdir -p "$CACHE"
  curl -fL --retry 3 -o "$CACHE/$2.part" "$1"
  mv "$CACHE/$2.part" "$CACHE/$2"
}

build_whisper() {
  [[ -x "$VENDOR/bin/whisper-cli" ]] && { ok "Whisper ya compilado"; return; }
  step "Compilando Whisper $WHISPER_VERSION (Metal, estático)"
  fetch "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WHISPER_VERSION.tar.gz" "whisper-$WHISPER_VERSION.tar.gz"
  rm -rf "$BUILD/src/whisper" && mkdir -p "$BUILD/src/whisper"
  tar -xzf "$CACHE/whisper-$WHISPER_VERSION.tar.gz" -C "$BUILD/src/whisper" --strip-components 1
  cmake -S "$BUILD/src/whisper" -B "$BUILD/src/whisper/build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
  cmake --build "$BUILD/src/whisper/build" --target whisper-cli -j "$JOBS" >/dev/null
  mkdir -p "$VENDOR/bin"
  cp "$BUILD/src/whisper/build/bin/whisper-cli" "$VENDOR/bin/"
  ok "whisper-cli"
}

build_ffmpeg() {
  [[ -x "$VENDOR/bin/ffmpeg" && -x "$VENDOR/bin/ffprobe" ]] && { ok "FFmpeg ya compilado"; return; }
  step "Compilando FFmpeg $FFMPEG_VERSION (sólo códecs propios)"
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"
  rm -rf "$BUILD/src/ffmpeg" && mkdir -p "$BUILD/src/ffmpeg"
  tar -xJf "$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$BUILD/src/ffmpeg" --strip-components 1
  ( cd "$BUILD/src/ffmpeg"
    # --disable-autodetect: no enlaza nada de Homebrew; el binario sólo depende de macOS.
    ./configure --prefix="$BUILD/src/ffmpeg/out" --cc=clang --arch=arm64 \
      --disable-autodetect --disable-doc --disable-debug --disable-network --disable-ffplay \
      --enable-static --disable-shared --enable-pthreads \
      --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" >/dev/null
    make -j "$JOBS" >/dev/null
    make install >/dev/null )
  mkdir -p "$VENDOR/bin"
  cp "$BUILD/src/ffmpeg/out/bin/ffmpeg" "$BUILD/src/ffmpeg/out/bin/ffprobe" "$VENDOR/bin/"
  ok "ffmpeg y ffprobe"
}

check_portable() {  # ningún binario debe depender de Homebrew
  local bad=0
  for f in "$@"; do
    if otool -L "$f" | tail -n +2 | grep -E "/opt/homebrew|/usr/local" >/dev/null; then
      print -P "%F{red}✗%f $f depende de Homebrew:"; otool -L "$f"; bad=1
    fi
  done
  (( bad == 0 )) || exit 1
}

build_app() {
  step "Compilando la app (Swift, release)"
  ( cd recorder-app && swift build -c release >/dev/null )
  BIN="$(cd recorder-app && swift build -c release --show-bin-path)/RecorderJT"

  step "Armando la app"
  rm -rf "$APP"
  local R="$APP/Contents/Resources"
  mkdir -p "$APP/Contents/MacOS" "$R/bin" "$R/worker/bin"
  cp "$BIN" "$APP/Contents/MacOS/RecorderJT"
  cp recorder-app/Resources/AppIcon.icns "$R/"
  # Sin ruta de worker: la app usa el que lleva dentro.
  sed -e "s#__WORKER_CLI__##" \
      -e "s#<string>0.1.0</string>#<string>${VERSION%%-*}</string>#" recorder-app/Resources/Info.plist > "$APP/Contents/Info.plist"
  plutil -lint "$APP/Contents/Info.plist" >/dev/null
  cp "$VENDOR/bin/whisper-cli" "$VENDOR/bin/ffmpeg" "$VENDOR/bin/ffprobe" "$R/bin/"
  check_portable "$R/bin/"*

  step "Python $PY_VERSION independiente + worker"
  local PYSRC
  PYSRC="$(uv python find "$PY_VERSION" --managed-python 2>/dev/null || uv python find "$PY_VERSION")"
  PYSRC="$(cd "$(dirname "$PYSRC")/.." && pwd -P)"
  [[ "$PYSRC" == *"/uv/python/"* ]] || { print "Hace falta un Python de uv (portátil): uv python install $PY_VERSION"; exit 1; }
  cp -R "$PYSRC" "$R/python"
  rm -f "$R/python/lib/python$PY_VERSION/EXTERNALLY-MANAGED"
  uv pip install --quiet --python "$R/python/bin/python3" --break-system-packages \
    "anthropic>=0.70" "pydantic>=2.7" "rapidfuzz>=3.9" "httpx>=0.27" "numpy>=1.26" "scipy>=1.11" "sherpa-onnx>=1.10"
  cp -R worker/recorder_worker "$R/worker/recorder_worker"
  cp -R config "$R/config"
  rm -f "$R/config/config.local.toml"
  # Limpieza: cachés, pruebas y cabeceras que no hacen falta para ejecutar.
  find "$R" -name "__pycache__" -type d -prune -exec rm -rf {} +
  rm -rf "$R/python/include" "$R/python/share" "$R/python/lib/python$PY_VERSION/test" \
         "$R/python/lib/python$PY_VERSION/idlelib" "$R/python/lib/python$PY_VERSION/tkinter" \
         "$R/python/lib/python$PY_VERSION/turtledemo" "$R/python/lib/"tcl* "$R/python/lib/"tk* "$R/python/lib/"itcl* 2>/dev/null || true
  cat > "$R/worker/bin/recorder" <<'EOF'
#!/bin/sh
# Lanza el worker con el Python que va dentro de la app.
HERE="$(cd "$(dirname "$0")/../.." && pwd -P)"
export PYTHONPATH="$HERE/worker" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
export PATH="$HERE/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
exec "$HERE/python/bin/python3" -c 'import sys; from recorder_worker.cli import main; sys.exit(main())' "$@"
EOF
  chmod +x "$R/worker/bin/recorder"
  "$R/worker/bin/recorder" --help >/dev/null && ok "worker responde"

  step "Firma ad hoc"
  # Cada binario de dentro con su propio identificador (Python, .so, whisper, ffmpeg),
  # y después la app entera.
  local n=0
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      codesign --force --sign - --identifier "com.jt.recorderjt.$(basename "$f" | tr -c 'A-Za-z0-9.\n' '-')" "$f" 2>/dev/null
      n=$((n + 1))
    fi
  done < <(find "$R" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0)
  ok "$n binarios internos firmados"
  codesign --force --sign - "$APP" 2>/dev/null
  codesign --verify --deep "$APP" && ok "firmada (ad hoc)"
  du -sh "$APP" | awk '{print "  tamaño: " $1}'
}

build_dmg() {
  step "Creando el .dmg"
  local STAGE="$BUILD/dmg"
  rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Aplicaciones"
  hdiutil create -volname "All Meetings Recorder" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  du -h "$DMG" | awk '{print "  " $1 "  " $2}'
  ok "$DMG"
}

case "${1:-all}" in
  deps) build_whisper; build_ffmpeg ;;
  app)  build_app ;;
  dmg)  build_dmg ;;
  all)  build_whisper; build_ffmpeg; build_app; build_dmg ;;
  *)    print "uso: $0 [deps|app|dmg|all]"; exit 2 ;;
esac
