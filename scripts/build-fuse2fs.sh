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
# shellcheck source=l10n.sh
. "$(cd "$(dirname "$0")" && pwd)/l10n.sh"

E2FSPROGS_VERSION="${E2FSPROGS_VERSION:-1.47.3}"
BACKEND="${BACKEND:-fuse-t}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_BIN="${E2FSPROGS_OUTPUT_DIR:-$REPO_DIR/vendor/bin}"
BUILD_DIR="${E2FSPROGS_BUILD_DIR:-${TMPDIR:-/tmp}/omnimount-fuse2fs-build}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
FUSE_T_INCLUDE_PRIMARY="${FUSE_T_INCLUDE_PRIMARY:-/usr/local/include/fuse}"
FUSE_T_INCLUDE_FALLBACK="/Library/Application Support/fuse-t/include/fuse"
FUSE_T_INCLUDE=""

case "$BACKEND" in
fuse-t)
    if [ ! -f /usr/local/lib/libfuse-t.dylib ]; then
        terr sh.common.noFuseT
        terr sh.common.installFuseT
        exit 1
    fi
    # Cabeceras de FUSE-T: el instalador enlaza /usr/local/include/fuse al
    # directorio real, pero ese enlace puede faltar; probar también el real.
    for dir in "$FUSE_T_INCLUDE_PRIMARY" "$FUSE_T_INCLUDE_FALLBACK"; do
        if [ -f "$dir/fuse.h" ]; then
            FUSE_T_INCLUDE="$dir"
            break
        fi
    done
    if [ -z "$FUSE_T_INCLUDE" ]; then
        terr sh.buildFuse.noHeaders "$FUSE_T_INCLUDE_PRIMARY" "$FUSE_T_INCLUDE_FALLBACK"
        terr sh.common.installFuseT
        exit 1
    fi
    ;;
macfuse)
    if [ ! -d /Library/Filesystems/macfuse.fs ]; then
        terr sh.buildFuse.noMacFuse
        terr sh.buildFuse.installMacFuse
        exit 1
    fi
    if [ ! -f /usr/local/lib/pkgconfig/fuse3.pc ]; then
        terr sh.buildFuse.noFuse3
        exit 1
    fi
    ;;
*)
    terr sh.buildFuse.badBackend "$BACKEND"
    exit 1
    ;;
esac

t sh.buildFuse.backend "$BACKEND"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
cd "$BUILD_DIR"
if [ "$BACKEND" = fuse-t ]; then
    # configure parte CPPFLAGS/LDFLAGS por espacios: el directorio de
    # compilación y las rutas de FUSE-T (que tiene un espacio) no pueden ir
    # directamente. Se llega a ellas por enlaces simbólicos dentro del shim:
    #   include -> cabeceras de FUSE-T; lib/libfuse.dylib -> libfuse-t.dylib
    # (configure sondea -lfuse; el enlace final sigue usando libfuse-t).
    case "$BUILD_DIR" in
    *[[:space:]]*) terr sh.buildFuse.spaceInPath "$BUILD_DIR"; exit 1 ;;
    esac
    FUSE_T_SHIM="$BUILD_DIR/fuse-t-shim"
    rm -rf "$FUSE_T_SHIM"
    mkdir -p "$FUSE_T_SHIM/lib"
    ln -s "$FUSE_T_INCLUDE" "$FUSE_T_SHIM/include"
    ln -s /usr/local/lib/libfuse-t.dylib "$FUSE_T_SHIM/lib/libfuse.dylib"
fi
if [ -n "${E2FSPROGS_SOURCE_DIR:-}" ]; then
    # Copiar antes de parchear: no modificar unas fuentes facilitadas por el llamante.
    rm -rf "e2fsprogs-$E2FSPROGS_VERSION.source-copy"
    cp -R "$E2FSPROGS_SOURCE_DIR" "e2fsprogs-$E2FSPROGS_VERSION.source-copy"
    rm -rf "e2fsprogs-$E2FSPROGS_VERSION"
    mv "e2fsprogs-$E2FSPROGS_VERSION.source-copy" "e2fsprogs-$E2FSPROGS_VERSION"
else
    t sh.buildFuse.downloading "$E2FSPROGS_VERSION"
    TARBALL="e2fsprogs-$E2FSPROGS_VERSION.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        # Descargar a un nombre temporal: una descarga interrumpida no debe
        # quedar con el nombre final ni reutilizarse.
        rm -f "$TARBALL.part"
        curl -fL -o "$TARBALL.part" \
            "https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FSPROGS_VERSION/$TARBALL"
        mv "$TARBALL.part" "$TARBALL"
    fi
    # SHA-256 de la versión por defecto, de sha256sums.asc que kernel.org
    # publica junto a esa release (.../tytso/e2fsprogs/v1.47.3/sha256sums.asc).
    case "$E2FSPROGS_VERSION" in
    1.47.3) EXPECTED_SHA256=857e6ef800feaa2bb4578fbc810214be5d3c88b072ea53c5384733a965737329 ;;
    *) EXPECTED_SHA256="" ;;
    esac
    if [ -n "$EXPECTED_SHA256" ]; then
        ACTUAL_SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
        if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
            rm -f "$TARBALL"
            terr sh.buildFuse.badChecksum "$TARBALL" "$EXPECTED_SHA256" "$ACTUAL_SHA256"
            exit 1
        fi
    else
        terr sh.buildFuse.unpinned "$E2FSPROGS_VERSION"
    fi
    rm -rf "e2fsprogs-$E2FSPROGS_VERSION"
    tar xf "$TARBALL"
fi
cd "e2fsprogs-$E2FSPROGS_VERSION"

t sh.buildFuse.darwinPatch
export OM_PATCH_ALREADY OM_PATCH_APPLIED OM_MISSING_FS_OPS
OM_PATCH_ALREADY=$(t sh.buildFuse.patchAlready)
OM_PATCH_APPLIED=$(t sh.buildFuse.patchApplied)
OM_MISSING_FS_OPS=$(t sh.buildFuse.missingFsOps)
python3 - misc/fuse2fs.c <<'PY'
import os
import sys

path = sys.argv[1]
src = open(path).read()
if "op_setxattr_darwin" in src:
    print(os.environ["OM_PATCH_ALREADY"])
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
assert anchor in src, os.environ["OM_MISSING_FS_OPS"]
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
print(os.environ["OM_PATCH_APPLIED"])
PY

t sh.buildFuse.readOnlyPatch
export OM_PATCH_ALREADY OM_PATCH_APPLIED OM_MISSING_ANCHOR
OM_PATCH_ALREADY=$(t sh.buildFuse.patchAlready)
OM_PATCH_APPLIED=$(t sh.buildFuse.patchApplied)
OM_MISSING_ANCHOR=$(t sh.buildFuse.missingAnchor)
python3 - misc/fuse2fs.c <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text()
marker = "/* Omnimount: read-only means no writes to the backing device. */"
anchor = "\tfuse_opt_parse(&args, &fctx, fuse2fs_opts, fuse2fs_opt_proc);"
if marker not in src:
    assert src.count(anchor) == 1, os.environ["OM_MISSING_ANCHOR"]
    src = src.replace(anchor, anchor + """

	/* Omnimount: read-only means no writes to the backing device. */
	if (fctx.ro) {
		flags &= ~EXT2_FLAG_RW;
		/* A dirty journal must not be replayed onto a read-only image. */
		fctx.norecovery = 1;
	}
""")
    path.write_text(src)
    print(os.environ["OM_PATCH_APPLIED"])
else:
    print(os.environ["OM_PATCH_ALREADY"])
PY

# Ejecuta un paso de la compilación guardando su salida en un log; si falla,
# muestra el final del log. Todos los pasos siguen siendo fatales, como antes.
run_step() {
    if ! "$@" >>"$BUILD_LOG" 2>&1; then
        terr sh.buildFuse.failedLog "$BUILD_LOG"
        tail -n 40 "$BUILD_LOG" >&2
        exit 1
    fi
}

# --- Build universal: una pasada por arquitectura y lipo al final ---
build_one() {
    ARCH="$1"
    BUILD_LOG="$BUILD_DIR/build-$ARCH.log"
    : >"$BUILD_LOG"
    mkdir -p "build-$ARCH" && cd "build-$ARCH"
    HOSTFLAG=""
    [ "$ARCH" = "x86_64" ] && HOSTFLAG="--host=x86_64-apple-darwin"
    if [ "$BACKEND" = "macfuse" ]; then
        # OJO: sin -I/usr/local/include (taparía las cabeceras fuse3).
        PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
        CC="clang -arch $ARCH" \
        CPPFLAGS="-D_FILE_OFFSET_BITS=64" \
        LDFLAGS="-L/usr/local/lib" \
        run_step ../configure --enable-fuse2fs --disable-nls --disable-uuidd --disable-fsck $HOSTFLAG
        run_step make -j"$(sysctl -n hw.ncpu)"
    else
        # FUSE-T (fuse2): anular pkg-config y enlazar libfuse-t explícita.
        # Cabeceras y libfuse sondeada por configure vía el shim (sin espacios).
        PKG_CONFIG=/usr/bin/false \
        CC="clang -arch $ARCH" \
        CPPFLAGS="-I$FUSE_T_SHIM/include -D_FILE_OFFSET_BITS=64" \
        LDFLAGS="-L/usr/local/lib -L$FUSE_T_SHIM/lib" \
        run_step ../configure --enable-fuse2fs --disable-nls --disable-uuidd --disable-fsck $HOSTFLAG
        run_step make -j"$(sysctl -n hw.ncpu)" libs
        run_step make -C misc fuse2fs \
            LIBFUSE="/usr/local/lib/libfuse-t.dylib -Wl,-rpath,/usr/local/lib"
    fi
    run_step make -C e2fsck e2fsck
    run_step make -C misc mke2fs tune2fs
    cd ..
}

t sh.common.compilingArch arm64
build_one arm64
t sh.buildFuse.compilingIntel
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
            terr sh.buildFuse.oldMacOS "$name" "$ARCH" "${minimum:-$(t sh.common.unknown)}"
            exit 1
        fi
    done
done
if [ "$BACKEND" = fuse-t ]; then
    for ARCH in arm64 x86_64; do
        dependencies="$(otool -arch "$ARCH" -L "$STAGED_BIN/fuse2fs")"
        if ! printf '%s\n' "$dependencies" | grep -Fq 'libfuse-t.dylib' || \
            printf '%s\n' "$dependencies" | grep -Eq 'libfuse[.][^[:space:]]*|libosxfuse|macfuse'; then
            terr sh.buildFuse.notFuseT "$ARCH"
            exit 1
        fi
    done
fi
mkdir -p "$VENDOR_BIN"
for name in fuse2fs e2fsck mke2fs tune2fs; do cp "$STAGED_BIN/$name" "$VENDOR_BIN/$name"; done

echo ""
t sh.common.universalBinaries "$VENDOR_BIN"
for tool in fuse2fs e2fsck mke2fs tune2fs; do lipo -info "$VENDOR_BIN/$tool"; done
"$VENDOR_BIN/fuse2fs" --version 2>&1 | head -2 || true
