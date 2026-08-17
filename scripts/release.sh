#!/bin/bash
# Release completa de Omnimount: compilar → app firmada → pkg → notarizar →
# grapar. Con certificados Developer ID y el perfil de notarización creado
# ("omnimount-notary", ver notarize.sh), esto produce un pkg distribuible.
#
# Uso: ./scripts/release.sh [--skip-notarize]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
VERSION="0.1.3"
SKIP_NOTARIZE="${1:-}"

echo "=== 1/4 App firmada ==="
./scripts/make-app.sh

if ! codesign -dvv dist/Omnimount.app 2>&1 | grep -q "Authority=Developer ID"; then
    echo ""
    echo "AVISO: la app NO está firmada con Developer ID (¿faltan los certificados?)."
    echo "El pkg resultante solo vale para pruebas locales."
fi

echo ""
echo "=== 2/4 Instalador .pkg ==="
./scripts/make-pkg.sh

PKG="dist/Omnimount-$VERSION.pkg"

if [ "$SKIP_NOTARIZE" = "--skip-notarize" ]; then
    echo ""
    echo "=== 3-4/4 Notarización omitida (--skip-notarize) ==="
    echo "Listo: $PKG (sin notarizar)"
    exit 0
fi

echo ""
echo "=== 3/4 Notarización ==="
./scripts/notarize.sh "$PKG"

echo ""
echo "=== Feed de actualizaciones (Sparkle) ==="
mkdir -p dist/updates
ditto -c -k --keepParent dist/Omnimount.app "dist/updates/Omnimount-$VERSION.zip"
./vendor/bin/generate_appcast --account Omnimount \
    --download-url-prefix "https://omnimount.es/updates/" dist/updates
echo "appcast generado en dist/updates/"

echo ""
echo "=== 4/4 Verificación final ==="
spctl --assess --type install -v "$PKG" && echo "Gatekeeper: aceptado ✓" || true
echo ""
echo "Release lista: $PKG"
