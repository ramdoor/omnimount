#!/bin/bash
# Release completa de Omnimount: compilar → app firmada → pkg → notarizar →
# grapar. Con certificados Developer ID y el perfil de notarización creado
# ("omnimount-notary", ver notarize.sh), esto produce un pkg distribuible.
#
# Uso: ./scripts/release.sh [--skip-notarize]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
VERSION="0.4.8"
SKIP_NOTARIZE="${1:-}"
if [ "$#" -gt 1 ] || { [ -n "$SKIP_NOTARIZE" ] && [ "$SKIP_NOTARIZE" != --skip-notarize ]; }; then
    echo "Uso: release.sh [--skip-notarize]" >&2
    exit 2
fi

echo "=== 1/4 App firmada ==="
./scripts/make-app.sh

# Capturar toda la salida evita el SIGPIPE de codesign | grep -q bajo pipefail.
APP_SIGNATURE="$(codesign -dvv dist/Omnimount.app 2>&1)"
case "$APP_SIGNATURE" in
    *"Authority=Developer ID Application:"*) ;;
    *) echo "ERROR: la release requiere firma Developer ID Application." >&2; exit 1 ;;
esac
codesign --verify --deep --strict dist/Omnimount.app
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Omnimount.app/Contents/Info.plist)"
[ "$APP_VERSION" = "$VERSION" ] || { echo "ERROR: app $APP_VERSION y release $VERSION no coinciden." >&2; exit 1; }

echo ""
echo "=== 2/4 Instalador .pkg ==="
./scripts/make-pkg.sh

PKG="dist/Omnimount-$VERSION.pkg"
PKG_SIGNATURE="$(pkgutil --check-signature "$PKG")"
case "$PKG_SIGNATURE" in
    *"Developer ID Installer:"*) ;;
    *) echo "ERROR: la release requiere firma Developer ID Installer." >&2; exit 1 ;;
esac

if [ "$SKIP_NOTARIZE" = "--skip-notarize" ]; then
    echo ""
    echo "=== 3-4/4 Notarización omitida (--skip-notarize) ==="
    echo "Listo: $PKG (sin notarizar)"
    exit 0
fi

echo ""
echo "=== 3/4 Notarización ==="
./scripts/notarize.sh "$PKG"

# Apple inspecciona también la app dentro del PKG. El ticket del PKG protege
# esa distribución; el ZIP de Sparkle necesita el ticket grapado a la app.
# Si Apple no emitió un ticket para esta app exacta, stapler falla y se para.
xcrun stapler staple dist/Omnimount.app
xcrun stapler validate dist/Omnimount.app
codesign --verify --deep --strict dist/Omnimount.app
spctl --assess --type execute -v dist/Omnimount.app
spctl --assess --type install -v "$PKG"

echo ""
echo "=== Feed de actualizaciones (Sparkle) ==="
mkdir -p dist/updates
if [ -f "releases/Omnimount-$VERSION.html" ]; then
    cp "releases/Omnimount-$VERSION.html" "dist/updates/Omnimount-$VERSION.html"
fi
ditto -c -k --keepParent dist/Omnimount.app "dist/updates/Omnimount-$VERSION.zip"
./vendor/bin/generate_appcast --account Omnimount \
    --download-url-prefix "https://omnimount.es/updates/" dist/updates
echo "appcast generado en dist/updates/"

echo ""
echo "=== 4/4 Verificación final ==="
echo "Gatekeeper: app y pkg aceptados ✓"
echo ""
echo "Release lista: $PKG"
