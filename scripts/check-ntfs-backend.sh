#!/bin/bash
# Comprueba sin ejecutar/montar que los binarios NTFS usan el backend esperado.
set -euo pipefail

BIN_DIR="${1:?Uso: check-ntfs-backend.sh directorio-de-binarios}"
for tool in ntfs-3g mkntfs ntfsfix; do
    binary="$BIN_DIR/$tool"
    [ -f "$binary" ] || continue
    for arch in arm64 x86_64; do
        if ! lipo -verify_arch "$arch" "$binary"; then
            echo "ERROR: $binary no contiene la arquitectura $arch." >&2
            exit 1
        fi
        if ! dependencies="$(otool -arch "$arch" -L "$binary" 2>&1)"; then
            echo "ERROR: $binary no contiene una arquitectura $arch válida." >&2
            exit 1
        fi
        if printf '%s\n' "$dependencies" | grep -Eq 'libfuse[.][^[:space:]]*|libosxfuse|macfuse'; then
            echo "ERROR: $binary ($arch) enlaza macFUSE/libfuse, no FUSE-T. Ejecuta make ntfs3g y vuelve a empaquetar." >&2
            exit 1
        fi
        if [ "$tool" = ntfs-3g ] && ! printf '%s\n' "$dependencies" | grep -Fq 'libfuse-t.dylib'; then
            echo "ERROR: $binary ($arch) no enlaza libfuse-t.dylib. Ejecuta make ntfs3g y vuelve a empaquetar." >&2
            exit 1
        fi
        minimum="$(otool -arch "$arch" -l "$binary" | awk '
            $1 == "cmd" { build = ($2 == "LC_BUILD_VERSION"); legacy = ($2 == "LC_VERSION_MIN_MACOSX") }
            !found && ((build && $1 == "minos") || (legacy && $1 == "version")) { minimum = $2; found = 1 }
            END { print minimum }
        ')"
        if [ -z "$minimum" ] || ! awk -v version="$minimum" 'BEGIN {
            split(version, part, ".");
            exit !(part[1] < 13 || (part[1] == 13 && part[2] == 0 && part[3] == 0));
        }'; then
            echo "ERROR: $binary ($arch) requiere macOS ${minimum:-desconocido}; Omnimount soporta 13+. Recompila con MACOSX_DEPLOYMENT_TARGET=13.0 make ntfs3g." >&2
            exit 1
        fi
    done
done
