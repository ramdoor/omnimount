#!/bin/bash
# Notariza el .pkg para distribuirlo fuera de la App Store sin avisos de
# Gatekeeper. Requiere estar inscrito en el Apple Developer Program (99 €/año)
# y haber creado los certificados "Developer ID Application" e "Installer".
#
# Preparación (una vez):
#   1. developer.apple.com → inscribirse en el programa.
#   2. Xcode → Settings → Accounts → Manage Certificates → crear
#      "Developer ID Application" y "Developer ID Installer".
#   3. Guardar credenciales de notarización en el llavero:
#        xcrun notarytool store-credentials omnimount-notary \
#            --apple-id TU_APPLE_ID --team-id TU_TEAM_ID
#      (pide una app-specific password de appleid.apple.com)
#
# Uso: ./scripts/notarize.sh dist/Omnimount-0.1.0.pkg
set -euo pipefail

PKG="${1:?Uso: notarize.sh <ruta.pkg>}"
PROFILE="${NOTARY_PROFILE:-omnimount-notary}"

if ! security find-identity -v 2>/dev/null | grep -q "Developer ID"; then
    echo "ERROR: no hay certificados 'Developer ID'. Inscríbete en el Apple" >&2
    echo "Developer Program y crea los certificados (ver cabecera del script)." >&2
    exit 1
fi

echo "==> Enviando a notarización (perfil: $PROFILE)"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait

echo "==> Grapando el ticket al pkg"
xcrun stapler staple "$PKG"

echo "==> Listo: $PKG notarizado y grapado. Se puede distribuir."
