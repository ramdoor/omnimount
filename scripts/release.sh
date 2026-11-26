#!/bin/bash
# Release completa de Omnimount: compilar → app firmada → pkg → notarizar →
# grapar. Con certificados Developer ID y el perfil de notarización creado
# ("omnimount-notary", ver notarize.sh), esto produce un pkg distribuible.
#
# Uso: ./scripts/release.sh [--skip-notarize]
set -euo pipefail
# shellcheck source=l10n.sh
. "$(cd "$(dirname "$0")" && pwd)/l10n.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
VERSION="0.4.9"
SKIP_NOTARIZE="${1:-}"
if [ "$#" -gt 1 ] || { [ -n "$SKIP_NOTARIZE" ] && [ "$SKIP_NOTARIZE" != --skip-notarize ]; }; then
    terr sh.release.usage
    exit 2
fi

t sh.release.stepApp
./scripts/make-app.sh

# Capturar toda la salida evita el SIGPIPE de codesign | grep -q bajo pipefail.
APP_SIGNATURE="$(codesign -dvv dist/Omnimount.app 2>&1)"
case "$APP_SIGNATURE" in
    *"Authority=Developer ID Application:"*) ;;
    *) terr sh.release.needAppId; exit 1 ;;
esac
codesign --verify --deep --strict dist/Omnimount.app
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Omnimount.app/Contents/Info.plist)"
[ "$APP_VERSION" = "$VERSION" ] || { terr sh.release.versionMismatch "$APP_VERSION" "$VERSION"; exit 1; }

echo ""
t sh.release.stepPkg
./scripts/make-pkg.sh

PKG="dist/Omnimount-$VERSION.pkg"
PKG_SIGNATURE="$(pkgutil --check-signature "$PKG")"
case "$PKG_SIGNATURE" in
    *"Developer ID Installer:"*) ;;
    *) terr sh.release.needInstallerId; exit 1 ;;
esac

if [ "$SKIP_NOTARIZE" = "--skip-notarize" ]; then
    echo ""
    t sh.release.skipNotarize
    t sh.release.readyUnsigned "$PKG"
    exit 0
fi

echo ""
t sh.release.stepNotarize
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
t sh.release.stepFeed
mkdir -p dist/updates
if [ -f "releases/Omnimount-$VERSION.html" ]; then
    cp "releases/Omnimount-$VERSION.html" "dist/updates/Omnimount-$VERSION.html"
fi
ditto -c -k --keepParent dist/Omnimount.app "dist/updates/Omnimount-$VERSION.zip"
./vendor/bin/generate_appcast --account Omnimount \
    --download-url-prefix "https://omnimount.es/updates/" dist/updates
t sh.release.appcast

echo ""
t sh.release.stepCheck
t sh.release.gatekeeper
echo ""
t sh.release.ready "$PKG"
