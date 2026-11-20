#!/bin/zsh
# Compila la app y la instala en ~/Applications/Recorder JT.app
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(cd .. && pwd)"
APP="$HOME/Applications/Recorder JT.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/RecorderJT"

# cierre ordenado (si está grabando, guarda); si no responde, se fuerza
osascript -e 'tell application id "com.jt.recorderjt" to quit' 2>/dev/null || true
for i in {1..10}; do pgrep -x RecorderJT >/dev/null || break; sleep 0.5; done
pkill -x RecorderJT 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RecorderJT"
sed "s#__WORKER_CLI__#$REPO/worker/.venv/bin/recorder#" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Firma: usa el certificado local "RecorderJT Dev" si existe (los permisos de
# macOS se conservan entre compilaciones); si no, firma ad-hoc.
if security find-identity -v -p codesigning | grep -q "RecorderJT Dev"; then
  codesign --force --deep --sign "RecorderJT Dev" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "✅ Instalada: $APP"
