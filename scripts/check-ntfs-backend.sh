#!/bin/bash
# Comprueba sin ejecutar/montar que los binarios NTFS usan el backend esperado.
set -euo pipefail
# shellcheck source=l10n.sh
. "$(cd "$(dirname "$0")" && pwd)/l10n.sh"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
    terr sh.checkNtfs.usage
    exit 1
fi
BIN_DIR=$1
for tool in ntfs-3g mkntfs ntfsfix; do
    binary="$BIN_DIR/$tool"
    [ -f "$binary" ] || continue
    for arch in arm64 x86_64; do
        if ! lipo -verify_arch "$arch" "$binary"; then
            terr sh.checkNtfs.missingArch "$binary" "$arch"
            exit 1
        fi
        if ! dependencies="$(otool -arch "$arch" -L "$binary" 2>&1)"; then
            terr sh.checkNtfs.badArch "$binary" "$arch"
            exit 1
        fi
        if printf '%s\n' "$dependencies" | grep -Eq 'libfuse[.][^[:space:]]*|libosxfuse|macfuse'; then
            terr sh.checkNtfs.linksMacfuse "$binary" "$arch"
            exit 1
        fi
        if [ "$tool" = ntfs-3g ] && ! printf '%s\n' "$dependencies" | grep -Fq 'libfuse-t.dylib'; then
            terr sh.checkNtfs.missingFuseT "$binary" "$arch"
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
            terr sh.checkNtfs.oldMacOS "$binary" "$arch" "${minimum:-$(t sh.common.unknown)}"
            exit 1
        fi
    done
done
