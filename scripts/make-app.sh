#!/bin/bash
# Empaqueta OmnimountApp como bundle Omnimount.app (con helper SMAppService).
set -euo pipefail
# shellcheck source=l10n.sh
. "$(cd "$(dirname "$0")" && pwd)/l10n.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# Fallar antes de compilar o reemplazar dist si los motores NTFS usan macFUSE.
bash "$REPO_DIR/scripts/check-ntfs-backend.sh" "$REPO_DIR/vendor/bin"

# Compilar fuera del árbol del repo: si el proyecto vive en una carpeta
# sincronizada (OneDrive/Dropbox), .build/ la satura y bloquea ficheros.
SCRATCH="${OMNIMOUNT_SCRATCH:-$HOME/.omnimount-build}"

t sh.makeApp.building
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"
# SwiftPM cambió la ruta de productos universales entre motores de compilación.
# Consultar la misma configuración evita depender de apple/ u out/.
RELEASE_DIR="$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)"
for product in OmnimountApp OmnimountHelper omnimount; do
    [ -x "$RELEASE_DIR/$product" ] || { terr sh.makeApp.missingProduct "$RELEASE_DIR/$product"; exit 1; }
    for arch in arm64 x86_64; do
        lipo -verify_arch "$arch" "$RELEASE_DIR/$product"
    done
done

APP="$REPO_DIR/dist/Omnimount.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons"

cp "$RELEASE_DIR/OmnimountApp" "$APP/Contents/MacOS/Omnimount"
cp "$RELEASE_DIR/OmnimountHelper" "$APP/Contents/MacOS/OmnimountHelper"

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
    <key>CFBundleVersion</key>           <string>0.4.9</string>
    <key>CFBundleShortVersionString</key><string>0.4.9</string>
    <key>CFBundleExecutable</key>        <string>Omnimount</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>es</string>
    </array>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>GPL-3.0-or-later</string>
    <key>SUFeedURL</key>                 <string>https://omnimount.es/updates/appcast.xml</string>
    <key>SUPublicEDKey</key>             <string>UusfwC7mWB9GwKXd96RdAqtEiwCXmQI87JbrtEWmvs0=</string>
    <key>SUEnableAutomaticChecks</key>   <true/>
</dict>
</plist>
PLIST

cp "$REPO_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Binarios autocontenidos: el CLI y fuse2fs viajan dentro del bundle
# (ToolLocator busca junto al ejecutable). Así el .pkg solo instala la app.
cp "$RELEASE_DIR/omnimount" "$APP/Contents/MacOS/omnimount-cli"
if [ -f "$REPO_DIR/vendor/bin/fuse2fs" ]; then
    cp "$REPO_DIR/vendor/bin/fuse2fs" "$APP/Contents/MacOS/fuse2fs"
else
    t sh.makeApp.missingFuse2fs
fi

# Resto de herramientas autocontenidas (0.4.6): NTFS compilado contra FUSE-T
# y utilidades ext4 estáticas. mke2fs se copia también con los nombres
# mkfs.ext* porque elige el tipo de FS según argv[0].
for tool in ntfs-3g mkntfs ntfsfix e2fsck mke2fs tune2fs; do
    if [ -f "$REPO_DIR/vendor/bin/$tool" ]; then
        cp "$REPO_DIR/vendor/bin/$tool" "$APP/Contents/MacOS/$tool"
    else
        t sh.makeApp.missingTool "$tool"
    fi
done
for name in mkfs.ext2 mkfs.ext3 mkfs.ext4; do
    [ -f "$APP/Contents/MacOS/mke2fs" ] && cp "$APP/Contents/MacOS/mke2fs" "$APP/Contents/MacOS/$name"
done

# Sparkle: framework embebido + rpath para encontrarlo en el bundle.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
SPARKLE_FW="$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { terr sh.makeApp.noSparkle "$SPARKLE_FW"; exit 1; }
cp -R "$SPARKLE_FW" "$FRAMEWORKS/"
# install_name_tool falla si el rpath ya existe: añadirlo solo si falta en
# alguna arquitectura, y comprobar el resultado en vez de ignorar el error.
APP_BIN="$APP/Contents/MacOS/Omnimount"
FW_RPATH="@executable_path/../Frameworks"
has_rpath() {
    local arch load_commands
    for arch in arm64 x86_64; do
        # Capturar antes de buscar: con pipefail, un grep -q que termina pronto
        # puede cortar a otool (SIGPIPE) y dar un falso negativo.
        load_commands="$(otool -arch "$arch" -l "$APP_BIN")" || return 1
        case "$load_commands" in
        *"path $FW_RPATH ("*) ;;
        *) return 1 ;;
        esac
    done
}
if ! has_rpath; then
    install_name_tool -add_rpath "$FW_RPATH" "$APP_BIN"
    has_rpath || { terr sh.makeApp.rpathFailed "$APP_BIN"; exit 1; }
fi

# Firma. Prioridad: Developer ID Application (distribución, con Hardened
# Runtime + timestamp, requisito de notarización) → cualquier identidad de
# desarrollo (el TCC sobrevive a recompilaciones) → ad-hoc.
# Firmar por hash SHA-1: los nombres pueden ser ambiguos si el llavero tiene
# copias duplicadas del certificado (p. ej. la de Xcode y la del CSR manual).
NO_TEAM_ID=""
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)"
if [ -n "$DEVID" ]; then
    SIGN_ID="$DEVID"
    RUNTIME_FLAGS="--options runtime --timestamp"
    t sh.makeApp.signingDist "$SIGN_ID"
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' 'NR==1 {print $2}')"
    RUNTIME_FLAGS=""
    t sh.makeApp.signingDev "${SIGN_ID:-ad-hoc}"
fi

ENTITLEMENTS="$REPO_DIR/scripts/tools.entitlements"
# shellcheck disable=SC2086  # RUNTIME_FLAGS debe expandirse en palabras
# Componentes anidados de Sparkle (requisito de notarización).
SPK="$FRAMEWORKS/Sparkle.framework"
codesign --force $RUNTIME_FLAGS --preserve-metadata=identifier,entitlements,flags,runtime --sign "${SIGN_ID:--}" "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign --force $RUNTIME_FLAGS --preserve-metadata=identifier,entitlements,flags,runtime --sign "${SIGN_ID:--}" "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign --force $RUNTIME_FLAGS --preserve-metadata=identifier,entitlements,flags,runtime --sign "${SIGN_ID:--}" "$SPK/Versions/B/Autoupdate"
codesign --force $RUNTIME_FLAGS --preserve-metadata=identifier,entitlements,flags,runtime --sign "${SIGN_ID:--}" "$SPK/Versions/B/Updater.app"
codesign --force $RUNTIME_FLAGS --sign "${SIGN_ID:--}" "$SPK"

codesign --force $RUNTIME_FLAGS --identifier org.omnimount.helper --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/OmnimountHelper"
# El helper solo acepta clientes firmados con su mismo Team ID: una firma
# ad-hoc o autofirmada (sin Team ID) deja la app sin poder usarlo.
if codesign -dvv "$APP/Contents/MacOS/OmnimountHelper" 2>&1 | grep -q '^TeamIdentifier=not set'; then
    NO_TEAM_ID=1
fi
codesign --force $RUNTIME_FLAGS --identifier org.omnimount.cli --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/omnimount-cli"
# fuse2fs carga libfuse-t (otro equipo): necesita library-validation off.
[ -f "$APP/Contents/MacOS/fuse2fs" ] && codesign --force $RUNTIME_FLAGS --entitlements "$ENTITLEMENTS" --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/fuse2fs"
[ -f "$APP/Contents/MacOS/ntfs-3g" ] && codesign --force $RUNTIME_FLAGS --entitlements "$ENTITLEMENTS" --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/ntfs-3g"
for tool in mkntfs ntfsfix e2fsck mke2fs tune2fs mkfs.ext2 mkfs.ext3 mkfs.ext4; do
    [ -f "$APP/Contents/MacOS/$tool" ] && codesign --force $RUNTIME_FLAGS --sign "${SIGN_ID:--}" "$APP/Contents/MacOS/$tool"
done
codesign --force $RUNTIME_FLAGS --sign "${SIGN_ID:--}" "$APP"
echo ""
t sh.makeApp.created "$APP"
if [ -n "${NO_TEAM_ID:-}" ]; then
    echo ""
    terr sh.makeApp.noTeamId
fi
t sh.makeApp.openHint "$APP"
