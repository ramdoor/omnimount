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

# --- Build universal: árbol limpio por arquitectura y lipo al final ---
SRC="ntfs-3g-$NTFS3G_VERSION"
for ARCH in arm64 x86_64; do
    echo "==> Compilando $ARCH"
    rm -rf "$SRC-$ARCH"
    cp -R "$SRC" "$SRC-$ARCH"
    cd "$SRC-$ARCH"
    HOSTFLAG=""
    [ "$ARCH" = "x86_64" ] && HOSTFLAG="--host=x86_64-apple-darwin"
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
    CC="clang -arch $ARCH" \
    CPPFLAGS="-I/usr/local/include -D_FILE_OFFSET_BITS=64" \
    LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
    ./configure --with-fuse=external --disable-shared --enable-static \
                --disable-nls --disable-ldconfig $HOSTFLAG >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
    cd ..
done

mkdir -p "$VENDOR_BIN"
for pair in ntfs-3g:src/ntfs-3g mkntfs:ntfsprogs/mkntfs ntfsfix:ntfsprogs/ntfsfix; do
    name="${pair%%:*}"; rel="${pair#*:}"
    lipo -create "$SRC-arm64/$rel" "$SRC-x86_64/$rel" -output "$VENDOR_BIN/$name"
done

echo ""
echo "==> Binarios universales en $VENDOR_BIN:"
for t in ntfs-3g mkntfs ntfsfix; do lipo -info "$VENDOR_BIN/$t"; done
