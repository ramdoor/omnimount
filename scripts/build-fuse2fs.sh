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
VENDOR_BIN="${E2FSPROGS_OUTPUT_DIR:-$REPO_DIR/vendor/bin}"
BUILD_DIR="${E2FSPROGS_BUILD_DIR:-${TMPDIR:-/tmp}/omnimount-fuse2fs-build}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

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
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
cd "$BUILD_DIR"
if [ -n "${E2FSPROGS_SOURCE_DIR:-}" ]; then
    # Copiar antes de parchear: no modificar unas fuentes facilitadas por el llamante.
    rm -rf "e2fsprogs-$E2FSPROGS_VERSION.source-copy"
    cp -R "$E2FSPROGS_SOURCE_DIR" "e2fsprogs-$E2FSPROGS_VERSION.source-copy"
    rm -rf "e2fsprogs-$E2FSPROGS_VERSION"
    mv "e2fsprogs-$E2FSPROGS_VERSION.source-copy" "e2fsprogs-$E2FSPROGS_VERSION"
else
    echo "==> Descargando e2fsprogs $E2FSPROGS_VERSION"
    TARBALL="e2fsprogs-$E2FSPROGS_VERSION.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        curl -fL -o "$TARBALL" \
            "https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FSPROGS_VERSION/$TARBALL"
    fi
    rm -rf "e2fsprogs-$E2FSPROGS_VERSION"
    tar xf "$TARBALL"
fi
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

echo "==> Aplicando parche de solo lectura (sin escrituras de metadatos ni journal)"
python3 - misc/fuse2fs.c <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text()
marker = "/* Omnimount: read-only means no writes to the backing device. */"
anchor = "\tfuse_opt_parse(&args, &fctx, fuse2fs_opts, fuse2fs_opt_proc);"
if marker not in src:
    assert src.count(anchor) == 1, "no se encontró un punto único de parseo de opciones"
    src = src.replace(anchor, anchor + """

	/* Omnimount: read-only means no writes to the backing device. */
	if (fctx.ro) {
		flags &= ~EXT2_FLAG_RW;
		/* A dirty journal must not be replayed onto a read-only image. */
		fctx.norecovery = 1;
	}
""")
    path.write_text(src)
    print("   parche aplicado")
else:
    print("   (ya aplicado)")
PY

# --- Build universal: una pasada por arquitectura y lipo al final ---
build_one() {
    ARCH="$1"
    mkdir -p "build-$ARCH" && cd "build-$ARCH"
    HOSTFLAG=""
    [ "$ARCH" = "x86_64" ] && HOSTFLAG="--host=x86_64-apple-darwin"
    if [ "$BACKEND" = "macfuse" ]; then
        # OJO: sin -I/usr/local/include (taparía las cabeceras fuse3).
        PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
        CC="clang -arch $ARCH" \
        CPPFLAGS="-D_FILE_OFFSET_BITS=64" \
        LDFLAGS="-L/usr/local/lib" \
        ../configure --enable-fuse2fs --disable-nls --disable-uuidd --disable-fsck $HOSTFLAG >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
    else
        # FUSE-T (fuse2): anular pkg-config y enlazar libfuse-t explícita.
        PKG_CONFIG=/usr/bin/false \
        CC="clang -arch $ARCH" \
        CPPFLAGS="-I/usr/local/include -D_FILE_OFFSET_BITS=64" \
        LDFLAGS="-L/usr/local/lib" \
        ../configure --enable-fuse2fs --disable-nls --disable-uuidd --disable-fsck $HOSTFLAG >/dev/null
        make -j"$(sysctl -n hw.ncpu)" libs >/dev/null
        make -C misc fuse2fs \
            LIBFUSE="/usr/local/lib/libfuse-t.dylib -Wl,-rpath,/usr/local/lib" >/dev/null
    fi
    make -C e2fsck e2fsck >/dev/null
    make -C misc mke2fs tune2fs >/dev/null
    cd ..
}

echo "==> Compilando arm64"
build_one arm64
echo "==> Compilando x86_64 (configure corre sus tests bajo Rosetta)"
build_one x86_64

STAGED_BIN="$BUILD_DIR/universal-bin"
mkdir -p "$STAGED_BIN"
for pair in fuse2fs:misc/fuse2fs e2fsck:e2fsck/e2fsck mke2fs:misc/mke2fs tune2fs:misc/tune2fs; do
    name="${pair%%:*}"; rel="${pair#*:}"
    lipo -create "build-arm64/$rel" "build-x86_64/$rel" -output "$STAGED_BIN/$name"
    for ARCH in arm64 x86_64; do
        lipo -verify_arch "$ARCH" "$STAGED_BIN/$name"
        minimum="$(otool -arch "$ARCH" -l "$STAGED_BIN/$name" | awk '
            $1 == "cmd" { build = ($2 == "LC_BUILD_VERSION"); legacy = ($2 == "LC_VERSION_MIN_MACOSX") }
            !found && ((build && $1 == "minos") || (legacy && $1 == "version")) { minimum = $2; found = 1 }
            END { print minimum }
        ')"
        if [ -z "$minimum" ] || ! awk -v version="$minimum" 'BEGIN {
            split(version, part, ".");
            exit !(part[1] < 13 || (part[1] == 13 && part[2] == 0 && part[3] == 0));
        }'; then
            echo "ERROR: $name ($ARCH) requiere macOS ${minimum:-desconocido}; recompila con MACOSX_DEPLOYMENT_TARGET=13.0." >&2
            exit 1
        fi
    done
done
if [ "$BACKEND" = fuse-t ]; then
    for ARCH in arm64 x86_64; do
        dependencies="$(otool -arch "$ARCH" -L "$STAGED_BIN/fuse2fs")"
        if ! printf '%s\n' "$dependencies" | grep -Fq 'libfuse-t.dylib' || \
            printf '%s\n' "$dependencies" | grep -Eq 'libfuse[.][^[:space:]]*|libosxfuse|macfuse'; then
            echo "ERROR: fuse2fs ($ARCH) no está enlazado exclusivamente contra FUSE-T." >&2
            exit 1
        fi
    done
fi
mkdir -p "$VENDOR_BIN"
for name in fuse2fs e2fsck mke2fs tune2fs; do cp "$STAGED_BIN/$name" "$VENDOR_BIN/$name"; done

echo ""
echo "==> Binarios universales en $VENDOR_BIN:"
for t in fuse2fs e2fsck mke2fs tune2fs; do lipo -info "$VENDOR_BIN/$t"; done
"$VENDOR_BIN/fuse2fs" --version 2>&1 | head -2 || true
