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

SIGNATURE="$(pkgutil --check-signature "$PKG")"
case "$SIGNATURE" in
    *"Developer ID Installer:"*) ;;
    *) echo "ERROR: el pkg no tiene una firma Developer ID Installer válida." >&2; exit 1 ;;
esac

echo "==> Enviando a notarización (perfil: $PROFILE)"
RESULT="${PKG%.pkg}.notary.json"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT"
SUBMISSION_ID="$(python3 - "$RESULT" <<'PY'
import json
import sys
with open(sys.argv[1]) as response:
    result = json.load(response)
if result.get("status") != "Accepted" or not result.get("id"):
    raise SystemExit("ERROR: notarización no aceptada; revisa " + sys.argv[1])
print(result["id"])
PY
)"
xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "${PKG%.pkg}.notary-log.json"

echo "==> Grapando el ticket al pkg"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

echo "==> Listo: $PKG notarizado y grapado. Se puede distribuir."
