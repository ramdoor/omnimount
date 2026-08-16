#!/bin/bash
# Genera el instalador dist/Omnimount-<versión>.pkg.
#
# El pkg instala Omnimount.app (con CLI, fuse2fs y helper embebidos) en
# /Applications y crea el enlace /usr/local/bin/omnimount. Las dependencias
# externas (FUSE-T, e2fsprogs, ntfs-3g) NO se empaquetan: el asistente de
# configuración de la app guía su instalación al primer arranque.
#
# Para distribuir fuera de tu Mac necesitas firma "Developer ID Installer"
# y notarización (ver scripts/notarize.sh).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

VERSION="0.1.0"
APP="$REPO_DIR/dist/Omnimount.app"
PKG="$REPO_DIR/dist/Omnimount-$VERSION.pkg"

[ -d "$APP" ] || { echo "No existe dist/Omnimount.app — ejecuta antes: make app"; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/root/Applications" "$STAGING/scripts"
cp -R "$APP" "$STAGING/root/Applications/"

# postinstall: enlace del CLI al bundle y aviso de primeros pasos.
cat > "$STAGING/scripts/postinstall" <<'POST'
#!/bin/bash
mkdir -p /usr/local/bin
ln -sf "/Applications/Omnimount.app/Contents/MacOS/omnimount-cli" /usr/local/bin/omnimount
# Abrir la app para que el asistente de configuración guíe los permisos.
CONSOLE_USER="$(stat -f%Su /dev/console)"
[ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && \
    launchctl asuser "$(id -u "$CONSOLE_USER")" open /Applications/Omnimount.app || true
exit 0
POST
chmod +x "$STAGING/scripts/postinstall"

# Identidad "Developer ID Installer" si existe; si no, pkg sin firmar (dev).
INSTALLER_ID="$(security find-identity -v 2>/dev/null | grep "Developer ID Installer" | head -1 | awk -F '"' '{print $2}' || true)"

ARGS=(
    --root "$STAGING/root"
    --scripts "$STAGING/scripts"
    --identifier org.omnimount.pkg
    --version "$VERSION"
    --install-location /
)
if [ -n "$INSTALLER_ID" ]; then
    pkgbuild "${ARGS[@]}" --sign "$INSTALLER_ID" "$PKG"
    echo "==> Firmado con: $INSTALLER_ID"
else
    pkgbuild "${ARGS[@]}" "$PKG"
    echo "AVISO: sin identidad 'Developer ID Installer' — pkg SIN firmar (válido solo para pruebas locales)."
fi

echo "==> Creado $PKG"
