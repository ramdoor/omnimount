#!/bin/bash
# Empaqueta OmnimountApp como bundle Omnimount.app (con helper SMAppService).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# Compilar fuera del árbol del repo: si el proyecto vive en una carpeta
# sincronizada (OneDrive/Dropbox), .build/ la satura y bloquea ficheros.
SCRATCH="${OMNIMOUNT_SCRATCH:-$HOME/.omnimount-build}"

echo "==> Compilando en modo release"
swift build -c release --scratch-path "$SCRATCH"

APP="$REPO_DIR/dist/Omnimount.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons"

cp "$SCRATCH/release/OmnimountApp" "$APP/Contents/MacOS/Omnimount"
cp "$SCRATCH/release/OmnimountHelper" "$APP/Contents/MacOS/OmnimountHelper"

# Daemon SMAppService: BundleProgram es relativo a la raíz del bundle.
cat > "$APP/Contents/Library/LaunchDaemons/org.omnimount.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.omnimount.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/OmnimountHelper</string>
    <key>MachServices</key>
    <dict>
        <key>org.omnimount.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>org.omnimount.app</string>
    </array>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Omnimount</string>
    <key>CFBundleDisplayName</key>       <string>Omnimount</string>
    <key>CFBundleIdentifier</key>        <string>org.omnimount.app</string>
    <key>CFBundleVersion</key>           <string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key>        <string>Omnimount</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>GPL-3.0-or-later</string>
</dict>
</plist>
PLIST

cp "$REPO_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Binarios autocontenidos: el CLI y fuse2fs viajan dentro del bundle
# (ToolLocator busca junto al ejecutable). Así el .pkg solo instala la app.
cp "$SCRATCH/release/omnimount" "$APP/Contents/MacOS/omnimount-cli"
if [ -f "$REPO_DIR/vendor/bin/fuse2fs" ]; then
    cp "$REPO_DIR/vendor/bin/fuse2fs" "$APP/Contents/MacOS/fuse2fs"
else
    echo "AVISO: vendor/bin/fuse2fs no existe (ejecuta 'make fuse2fs'); el bundle no incluirá fuse2fs."
fi

# Firma. Prioridad: Developer ID Application (distribución, con Hardened
# Runtime + timestamp, requisito de notarización) → cualquier identidad de
# desarrollo (el TCC sobrevive a recompilaciones) → ad-hoc.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F '"' '{print $2}' || true)"
if [ -n "$DEVID" ]; then
    SIGN_ID="$DEVID"
    RUNTIME_FLAGS="--options runtime --timestamp"
    echo "==> Firmando para distribución: $SIGN_ID"
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' 'NR==1 {print $2}')"
    RUNTIME_FLAGS=""
    echo "==> Firma de desarrollo: ${SIGN_ID:-ad-hoc}"
fi

ENTITLEMENTS="$REPO_DIR/scripts/tools.entitlements"
# shellcheck disable=SC2086  # RUNTIME_FLAGS debe expandirse en palabras
codesign --force $RUNTIME_FLAGS --identifier org.omnimount.helper --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/OmnimountHelper"
codesign --force $RUNTIME_FLAGS --identifier org.omnimount.cli --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/omnimount-cli"
# fuse2fs carga libfuse-t (otro equipo): necesita library-validation off.
[ -f "$APP/Contents/MacOS/fuse2fs" ] && codesign --force $RUNTIME_FLAGS --entitlements "$ENTITLEMENTS" --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/fuse2fs"
codesign --force $RUNTIME_FLAGS --sign "${SIGN_ID:--}" "$APP"
echo ""
echo "==> Creado $APP"
echo "Ábrela con: open \"$APP\""
