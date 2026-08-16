#!/bin/bash
# Compila fuse2fs (de e2fsprogs) y lo deja en vendor/bin/.
#
# ¿Por qué? El bottle de Homebrew de e2fsprogs para macOS NO incluye fuse2fs,
# porque necesita cabeceras FUSE en tiempo de compilación y Homebrew no puede
# depender de un cask. Este script descarga el código fuente de e2fsprogs y
# compila solo fuse2fs.
#
# Backends soportados (variable BACKEND):
#   fuse-t  (por defecto) — FUSE sin kext: no requiere Recovery ni reinicios.
#                           Requiere: brew install --cask macos-fuse-t/cask/fuse-t
#   macfuse               — el clásico con kext (API fuse3).
#                           Requiere: brew install --cask macfuse
set -euo pipefail

E2FSPROGS_VERSION="${E2FSPROGS_VERSION:-1.47.3}"
BACKEND="${BACKEND:-fuse-t}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_BIN="$REPO_DIR/vendor/bin"
BUILD_DIR="${TMPDIR:-/tmp}/omnimount-fuse2fs-build"

case "$BACKEND" in
fuse-t)
    if [ ! -f /usr/local/lib/libfuse-t.dylib ]; then
        echo "ERROR: FUSE-T no está instalado." >&2
        echo "  brew install --cask macos-fuse-t/cask/fuse-t" >&2
        exit 1
    fi
    ;;
macfuse)
    if [ ! -d /Library/Filesystems/macfuse.fs ]; then
        echo "ERROR: macFUSE no está instalado." >&2
        echo "  brew install --cask macfuse (y aprueba la extensión en Ajustes del Sistema)" >&2
        exit 1
    fi
    if [ ! -f /usr/local/lib/pkgconfig/fuse3.pc ]; then
        echo "ERROR: no se encuentra fuse3.pc (¿instalación de macFUSE incompleta?)" >&2
        exit 1
    fi
    ;;
*)
    echo "BACKEND desconocido: $BACKEND (usa fuse-t o macfuse)" >&2
    exit 1
    ;;
esac

echo "==> Backend: $BACKEND"
echo "==> Descargando e2fsprogs $E2FSPROGS_VERSION"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
TARBALL="e2fsprogs-$E2FSPROGS_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
    curl -fL -o "$TARBALL" \
        "https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FSPROGS_VERSION/$TARBALL"
fi
rm -rf "e2fsprogs-$E2FSPROGS_VERSION"
tar xf "$TARBALL"
cd "e2fsprogs-$E2FSPROGS_VERSION"

echo "==> Aplicando parche Darwin (la API xattr de macOS lleva un parámetro 'position')"
python3 - misc/fuse2fs.c <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()
if "op_setxattr_darwin" in src:
    print("   (ya aplicado)")
    sys.exit(0)

wrappers = """
#if FUSE_VERSION < FUSE_MAKE_VERSION(3, 0)
/* macFUSE/FUSE-T (Darwin, API fuse2): la API de xattr lleva un parametro
 * extra "position" (solo lo usa el resource fork de HFS+); delegamos en las
 * versiones POSIX. */
static int op_setxattr_darwin(const char *path, const char *key,
			      const char *value, size_t len, int flags,
			      uint32_t position)
{
	if (position)
		return -EINVAL;
	return op_setxattr(path, key, value, len, flags);
}

static int op_getxattr_darwin(const char *path, const char *key, char *value,
			      size_t len, uint32_t position)
{
	if (position)
		return -EINVAL;
	return op_getxattr(path, key, value, len);
}
#endif

"""
anchor = "static struct fuse_operations fs_ops = {"
assert anchor in src, "no se encontró fs_ops en fuse2fs.c"
src = src.replace(anchor, wrappers + anchor)
src = src.replace(".setxattr = op_setxattr,", """#if FUSE_VERSION < FUSE_MAKE_VERSION(3, 0)
	.setxattr = op_setxattr_darwin,
#else
	.setxattr = op_setxattr,
#endif""")
src = src.replace(".getxattr = op_getxattr,", """#if FUSE_VERSION < FUSE_MAKE_VERSION(3, 0)
	.getxattr = op_getxattr_darwin,
#else
	.getxattr = op_getxattr,
#endif""")
open(path, "w").write(src)
print("   parche aplicado")
PY

mkdir -p build && cd build

if [ "$BACKEND" = "macfuse" ]; then
    # OJO: no añadir -I/usr/local/include a CPPFLAGS — ahí vive el fuse.h de
    # la API fuse2 y taparía las cabeceras de fuse3, produciendo un binario
    # fuse2 enlazado contra libfuse3 (falla en ejecución con "unknown option
    # use_ino").
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
    CPPFLAGS="-D_FILE_OFFSET_BITS=64" \
    LDFLAGS="-L/usr/local/lib" \
    ../configure --enable-fuse2fs --disable-nls --disable-uuidd --disable-fsck
    echo "==> Compilando (fuse3/macFUSE)"
    make -j"$(sysctl -n hw.ncpu)"
else
    # FUSE-T: API fuse2. Anular pkg-config para que configure no elija fuse3,
    # y enlazar explícitamente libfuse-t (su install name usa @rpath).
    PKG_CONFIG=/usr/bin/false \
    CPPFLAGS="-I/usr/local/include -D_FILE_OFFSET_BITS=64" \
    LDFLAGS="-L/usr/local/lib" \
    ../configure --enable-fuse2fs --disable-nls --disable-uuidd --disable-fsck
    echo "==> Compilando (fuse2/FUSE-T)"
    make -j"$(sysctl -n hw.ncpu)" libs
    make -C misc fuse2fs \
        LIBFUSE="/usr/local/lib/libfuse-t.dylib -Wl,-rpath,/usr/local/lib"
fi

FUSE2FS="misc/fuse2fs"
if [ ! -x "$FUSE2FS" ]; then
    echo "ERROR: la compilación terminó pero no existe $FUSE2FS" >&2
    exit 1
fi

mkdir -p "$VENDOR_BIN"
cp "$FUSE2FS" "$VENDOR_BIN/fuse2fs"
echo ""
echo "==> fuse2fs ($BACKEND) instalado en $VENDOR_BIN/fuse2fs"
"$VENDOR_BIN/fuse2fs" --version 2>&1 | head -2 || true
echo ""
echo "Instálalo en el sistema con: make fuse2fs   (o cp a /opt/homebrew/sbin/)"
