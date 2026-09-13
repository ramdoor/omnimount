#!/bin/bash
# Compila ntfs-3g, mkntfs y ntfsfix contra FUSE-T (sin macFUSE) y los deja
# en vendor/bin/ para embeberlos en la app.
#
# ¿Por qué? El ntfs-3g de Homebrew (gromgit/fuse/ntfs-3g-mac) enlaza la
# libfuse.2 de macFUSE — el backend con kext que desaconsejamos. FUSE-T
# instala librerías de compatibilidad fuse2 (libfuse.2.dylib, fuse.pc), así
# que compilando desde el código el binario queda ligado a FUSE-T.
#
# Requiere: FUSE-T instalado (brew install --cask macos-fuse-t/cask/fuse-t)
set -euo pipefail

NTFS3G_VERSION="${NTFS3G_VERSION:-2026.7.7}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_BIN="$REPO_DIR/vendor/bin"
BUILD_DIR="${TMPDIR:-/tmp}/omnimount-ntfs3g-build"

if [ ! -f /usr/local/lib/libfuse-t.dylib ]; then
    echo "ERROR: FUSE-T no está instalado." >&2
    echo "  brew install --cask macos-fuse-t/cask/fuse-t" >&2
    exit 1
fi

echo "==> Descargando ntfs-3g $NTFS3G_VERSION"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
TARBALL="ntfs-3g_ntfsprogs-$NTFS3G_VERSION.tgz"
if [ ! -f "$TARBALL" ]; then
    curl -fL -o "$TARBALL" "https://tuxera.com/opensource/$TARBALL"
fi
rm -rf "ntfs-3g-$NTFS3G_VERSION"
tar xf "$TARBALL"
cd "ntfs-3g-$NTFS3G_VERSION"

echo "==> Configurando (fuse2/FUSE-T, binarios estáticos salvo libfuse)"
# --disable-shared: libntfs-3g se enlaza estática dentro de cada binario.
# El fuse.pc de FUSE-T resuelve la API fuse2; rpath para su @rpath install name.
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
CPPFLAGS="-I/usr/local/include -D_FILE_OFFSET_BITS=64" \
LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
./configure --with-fuse=external --disable-shared --enable-static \
            --disable-nls --disable-ldconfig >/dev/null

echo "==> Compilando"
make -j"$(sysctl -n hw.ncpu)" >/dev/null

for bin in src/ntfs-3g ntfsprogs/mkntfs ntfsprogs/ntfsfix; do
    [ -x "$bin" ] || { echo "ERROR: falta $bin tras compilar" >&2; exit 1; }
done

mkdir -p "$VENDOR_BIN"
cp src/ntfs-3g ntfsprogs/mkntfs ntfsprogs/ntfsfix "$VENDOR_BIN/"
echo ""
echo "==> Instalados en $VENDOR_BIN: ntfs-3g, mkntfs, ntfsfix"
"$VENDOR_BIN/ntfs-3g" --version 2>&1 | head -1 || true
otool -L "$VENDOR_BIN/ntfs-3g" | grep -i fuse || true
