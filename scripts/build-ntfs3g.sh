#!/bin/bash
# Compila ntfs-3g, mkntfs y ntfsfix contra FUSE-T (sin macFUSE) y los deja
# en vendor/bin/ para embeberlos en la app.
#
# ¿Por qué? El ntfs-3g de Homebrew (gromgit/fuse/ntfs-3g-mac) enlaza la
# libfuse.2 de macFUSE — el backend con kext que desaconsejamos. FUSE-T
# y macFUSE puede coexistir con FUSE-T. Se selecciona fuse-t.pc explícitamente:
# usar fuse.pc puede volver a enlazar macFUSE aunque FUSE-T esté instalado.
#
# Requiere: FUSE-T instalado (brew install --cask macos-fuse-t/cask/fuse-t)
# NTFS3G_SOURCE_DIR reutiliza fuentes ya extraídas; NTFS3G_BUILD_DIR y
# NTFS3G_OUTPUT_DIR permiten validar una compilación sin sustituir vendor/bin.
set -euo pipefail

NTFS3G_VERSION="${NTFS3G_VERSION:-2026.7.7}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_BIN="${NTFS3G_OUTPUT_DIR:-$REPO_DIR/vendor/bin}"
BUILD_DIR="${NTFS3G_BUILD_DIR:-${TMPDIR:-/tmp}/omnimount-ntfs3g-build}"

if [ ! -f /usr/local/lib/libfuse-t.dylib ]; then
    echo "ERROR: FUSE-T no está instalado." >&2
    echo "  brew install --cask macos-fuse-t/cask/fuse-t" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
if [ -n "${NTFS3G_SOURCE_DIR:-}" ]; then
    SRC="$(cd "$NTFS3G_SOURCE_DIR" && pwd)"
else
    echo "==> Descargando ntfs-3g $NTFS3G_VERSION"
    TARBALL="$BUILD_DIR/ntfs-3g_ntfsprogs-$NTFS3G_VERSION.tgz"
    if [ ! -f "$TARBALL" ]; then
        curl -fL -o "$TARBALL" "https://tuxera.com/opensource/$(basename "$TARBALL")"
    fi
    SRC="$BUILD_DIR/ntfs-3g-$NTFS3G_VERSION"
    rm -rf "$SRC"
    tar xf "$TARBALL" -C "$BUILD_DIR"
fi
[ -f "$SRC/configure" ] || { echo "ERROR: fuente ntfs-3g sin configure: $SRC" >&2; exit 1; }

# configure consulta normalmente el módulo "fuse". Estas dos variables son
# sus overrides oficiales y evitan esa selección ambigua sin tocar /usr/local.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
FUSE_T_CFLAGS="$(pkg-config --cflags fuse-t)"
FUSE_T_LIBS="$(pkg-config --libs fuse-t)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# --- Build universal: árbol limpio por arquitectura y lipo al final ---
for ARCH in arm64 x86_64; do
    echo "==> Compilando $ARCH"
    ARCH_DIR="$BUILD_DIR/ntfs-3g-$NTFS3G_VERSION-$ARCH"
    rm -rf "$ARCH_DIR"
    cp -R "$SRC" "$ARCH_DIR"
    cd "$ARCH_DIR"
    HOSTFLAG=""
    [ "$ARCH" = "x86_64" ] && HOSTFLAG="--host=x86_64-apple-darwin"
    FUSE_MODULE_CFLAGS="$FUSE_T_CFLAGS" \
    FUSE_MODULE_LIBS="$FUSE_T_LIBS" \
    CC="clang -arch $ARCH" \
    CPPFLAGS="-I/usr/local/include -D_FILE_OFFSET_BITS=64" \
    LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
    ./configure --with-fuse=external --disable-shared --enable-static \
                --disable-nls --disable-ldconfig $HOSTFLAG >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
done

STAGED_BIN="$BUILD_DIR/universal-bin"
mkdir -p "$STAGED_BIN"
for pair in ntfs-3g:src/ntfs-3g mkntfs:ntfsprogs/mkntfs ntfsfix:ntfsprogs/ntfsfix; do
    name="${pair%%:*}"; rel="${pair#*:}"
    lipo -create "$BUILD_DIR/ntfs-3g-$NTFS3G_VERSION-arm64/$rel" \
                 "$BUILD_DIR/ntfs-3g-$NTFS3G_VERSION-x86_64/$rel" -output "$STAGED_BIN/$name"
done
# No sustituir los binarios existentes si alguna arquitectura enlaza otro backend.
bash "$REPO_DIR/scripts/check-ntfs-backend.sh" "$STAGED_BIN"
mkdir -p "$VENDOR_BIN"
for name in ntfs-3g mkntfs ntfsfix; do cp "$STAGED_BIN/$name" "$VENDOR_BIN/$name"; done

echo ""
echo "==> Binarios universales en $VENDOR_BIN:"
for t in ntfs-3g mkntfs ntfsfix; do lipo -info "$VENDOR_BIN/$t"; done
