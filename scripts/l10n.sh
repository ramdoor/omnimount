#!/bin/bash
# Textos de los scripts. Claves `sh.<script>.<nombre>`, inglés de respaldo.
# El idioma es el primero de AppleLanguages (el mismo que usa la app);
# OMNIMOUNT_LANG=es|en lo sustituye. Cualquier otro valor fuerza inglés.
# Ejecutar este fichero comprueba que cada `t`/`terr` tiene entrada y al revés.

om_preferred_language() {
    if [ -n "${OM_LANG_CACHED+x}" ]; then
        printf '%s' "$OM_LANG_CACHED"
        return
    fi
    local raw=""
    if [ -n "${OMNIMOUNT_LANG+x}" ] && [ -n "$OMNIMOUNT_LANG" ]; then
        raw=$(printf '%s' "$OMNIMOUNT_LANG" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    else
        raw=$(defaults read -g AppleLanguages 2>/dev/null | awk -F'"' '/"/ { print $2; exit }' | tr '[:upper:]' '[:lower:]' || true)
    fi
    case "$raw" in
        es|es-*|es_*) OM_LANG_CACHED=es ;;
        *) OM_LANG_CACHED=en ;;
    esac
    printf '%s' "$OM_LANG_CACHED"
}

# key, inglés, español. Un campo por tabulador.
om_catalog() {
    cat <<'EOF'
sh.common.unknown	unknown	desconocido
sh.common.noFuseT	ERROR: FUSE-T is not installed.	ERROR: FUSE-T no está instalado.
sh.common.installFuseT	  brew install --cask macos-fuse-t/cask/fuse-t	  brew install --cask macos-fuse-t/cask/fuse-t
sh.common.compilingArch	==> Compiling %@	==> Compilando %@
sh.common.universalBinaries	==> Universal binaries in %@:	==> Binarios universales en %@:
sh.make.cliInstalled	CLI installed at %@ (signed: %@)	CLI instalado en %@ (firmado: %@)
sh.make.appInstalled	App installed at /Applications/Omnimount.app	App instalada en /Applications/Omnimount.app
sh.make.restartHelper	Remember: if the helper was active, restart it:	Recuerda: si el helper estaba activo, reinícialo:
sh.make.restartCommand	  sudo launchctl kickstart -k system/org.omnimount.helper	  sudo launchctl kickstart -k system/org.omnimount.helper
sh.make.fuse2fsInstalled	fuse2fs installed at %@	fuse2fs instalado en %@
sh.makeApp.building	==> Compiling in release mode	==> Compilando en modo release
sh.makeApp.missingProduct	ERROR: built product %@ does not exist	ERROR: no existe el producto compilado %@
sh.makeApp.missingFuse2fs	WARNING: vendor/bin/fuse2fs is missing (run 'make fuse2fs'); the bundle will not include fuse2fs.	AVISO: vendor/bin/fuse2fs no existe (ejecuta 'make fuse2fs'); el bundle no incluirá fuse2fs.
sh.makeApp.missingTool	WARNING: vendor/bin/%@ is missing (scripts/build-ntfs3g.sh / build-fuse2fs.sh)	AVISO: vendor/bin/%@ no existe (scripts/build-ntfs3g.sh / build-fuse2fs.sh)
sh.makeApp.signingDist	==> Signing for distribution: %@	==> Firmando para distribución: %@
sh.makeApp.signingDev	==> Development signature: %@	==> Firma de desarrollo: %@
sh.makeApp.created	==> Created %@	==> Creado %@
sh.makeApp.openHint	Open it with: open "%@"	Ábrela con: open "%@"
sh.release.usage	Usage: release.sh [--skip-notarize]	Uso: release.sh [--skip-notarize]
sh.release.noAppcastTool	ERROR: vendor/bin/generate_appcast is missing (it ships with Sparkle). Place it there before releasing.	ERROR: falta vendor/bin/generate_appcast (se distribuye con Sparkle). Colócalo ahí antes de la release.
sh.release.stepApp	=== 1/4 Signed app ===	=== 1/4 App firmada ===
sh.release.needAppId	ERROR: the release requires a Developer ID Application signature.	ERROR: la release requiere firma Developer ID Application.
sh.release.versionMismatch	ERROR: app %@ and release %@ do not match.	ERROR: app %@ y release %@ no coinciden.
sh.release.stepPkg	=== 2/4 Installer .pkg ===	=== 2/4 Instalador .pkg ===
sh.release.needInstallerId	ERROR: the release requires a Developer ID Installer signature.	ERROR: la release requiere firma Developer ID Installer.
sh.release.skipNotarize	=== 3-4/4 Notarization skipped (--skip-notarize) ===	=== 3-4/4 Notarización omitida (--skip-notarize) ===
sh.release.readyUnsigned	Done: %@ (not notarized)	Listo: %@ (sin notarizar)
sh.release.stepNotarize	=== 3/4 Notarization ===	=== 3/4 Notarización ===
sh.release.stepFeed	=== Update feed (Sparkle) ===	=== Feed de actualizaciones (Sparkle) ===
sh.release.appcast	appcast written to dist/updates/	appcast generado en dist/updates/
sh.release.stepCheck	=== 4/4 Final check ===	=== 4/4 Verificación final ===
sh.release.gatekeeper	Gatekeeper: app and pkg accepted ✓	Gatekeeper: app y pkg aceptados ✓
sh.release.ready	Release ready: %@	Release lista: %@
sh.notarize.usage	Usage: notarize.sh <path.pkg>	Uso: notarize.sh <ruta.pkg>
sh.notarize.badSignature	ERROR: the pkg does not have a valid Developer ID Installer signature.	ERROR: el pkg no tiene una firma Developer ID Installer válida.
sh.notarize.submitting	==> Submitting for notarization (profile: %@)	==> Enviando a notarización (perfil: %@)
sh.notarize.rejected	ERROR: notarization was not accepted; see %@	ERROR: notarización no aceptada; revisa %@
sh.notarize.stapling	==> Stapling the ticket to the pkg	==> Grapando el ticket al pkg
sh.notarize.done	==> Done: %@ notarized and stapled. It can be distributed.	==> Listo: %@ notarizado y grapado. Se puede distribuir.
sh.makePkg.missingApp	dist/Omnimount.app does not exist — run first: make app	No existe dist/Omnimount.app — ejecuta antes: make app
sh.makePkg.signed	==> Signed with: %@	==> Firmado con: %@
sh.makePkg.unsigned	WARNING: no 'Developer ID Installer' identity — pkg UNSIGNED (local testing only).	AVISO: sin identidad 'Developer ID Installer' — pkg SIN firmar (válido solo para pruebas locales).
sh.makePkg.created	==> Created %@	==> Creado %@
sh.checkNtfs.usage	Usage: check-ntfs-backend.sh binary-directory	Uso: check-ntfs-backend.sh directorio-de-binarios
sh.checkNtfs.missingArch	ERROR: %@ does not contain the %@ architecture.	ERROR: %@ no contiene la arquitectura %@.
sh.checkNtfs.badArch	ERROR: %@ does not contain a valid %@ architecture.	ERROR: %@ no contiene una arquitectura %@ válida.
sh.checkNtfs.linksMacfuse	ERROR: %@ (%@) links macFUSE/libfuse, not FUSE-T. Run make ntfs3g and package again.	ERROR: %@ (%@) enlaza macFUSE/libfuse, no FUSE-T. Ejecuta make ntfs3g y vuelve a empaquetar.
sh.checkNtfs.missingFuseT	ERROR: %@ (%@) does not link libfuse-t.dylib. Run make ntfs3g and package again.	ERROR: %@ (%@) no enlaza libfuse-t.dylib. Ejecuta make ntfs3g y vuelve a empaquetar.
sh.checkNtfs.oldMacOS	ERROR: %@ (%@) requires macOS %@; Omnimount supports 13+. Rebuild with MACOSX_DEPLOYMENT_TARGET=13.0 make ntfs3g.	ERROR: %@ (%@) requiere macOS %@; Omnimount soporta 13+. Recompila con MACOSX_DEPLOYMENT_TARGET=13.0 make ntfs3g.
sh.buildNtfs.downloading	==> Downloading ntfs-3g %@	==> Descargando ntfs-3g %@
sh.buildNtfs.noConfigure	ERROR: ntfs-3g source has no configure: %@	ERROR: fuente ntfs-3g sin configure: %@
sh.buildNtfs.noPkgConfig	ERROR: pkg-config is not installed (brew install pkg-config).	ERROR: pkg-config no está instalado (brew install pkg-config).
sh.buildNtfs.noFuseTPc	ERROR: pkg-config cannot find fuse-t.pc (expected in /usr/local/lib/pkgconfig). Reinstall FUSE-T.	ERROR: pkg-config no encuentra fuse-t.pc (debería estar en /usr/local/lib/pkgconfig). Reinstala FUSE-T.
sh.buildFuse.noMacFuse	ERROR: macFUSE is not installed.	ERROR: macFUSE no está instalado.
sh.buildFuse.installMacFuse	  brew install --cask macfuse (and approve the extension in System Settings)	  brew install --cask macfuse (y aprueba la extensión en Ajustes del Sistema)
sh.buildFuse.noFuse3	ERROR: fuse3.pc was not found (incomplete macFUSE install?)	ERROR: no se encuentra fuse3.pc (¿instalación de macFUSE incompleta?)
sh.buildFuse.badBackend	Unknown BACKEND: %@ (use fuse-t or macfuse)	BACKEND desconocido: %@ (usa fuse-t o macfuse)
sh.buildFuse.backend	==> Backend: %@	==> Backend: %@
sh.buildFuse.downloading	==> Downloading e2fsprogs %@	==> Descargando e2fsprogs %@
sh.buildFuse.darwinPatch	==> Applying Darwin patch (the macOS xattr API takes a 'position' parameter)	==> Aplicando parche Darwin (la API xattr de macOS lleva un parámetro 'position')
sh.buildFuse.patchAlready	   (already applied)	   (ya aplicado)
sh.buildFuse.patchApplied	   patch applied	   parche aplicado
sh.buildFuse.missingFsOps	fs_ops was not found in fuse2fs.c	no se encontró fs_ops en fuse2fs.c
sh.buildFuse.readOnlyPatch	==> Applying read-only patch (no metadata or journal writes)	==> Aplicando parche de solo lectura (sin escrituras de metadatos ni journal)
sh.buildFuse.missingAnchor	a unique option-parsing site was not found	no se encontró un punto único de parseo de opciones
sh.buildFuse.compilingIntel	==> Compiling x86_64 (configure runs its tests under Rosetta)	==> Compilando x86_64 (configure corre sus tests bajo Rosetta)
sh.buildFuse.oldMacOS	ERROR: %@ (%@) requires macOS %@; rebuild with MACOSX_DEPLOYMENT_TARGET=13.0.	ERROR: %@ (%@) requiere macOS %@; recompila con MACOSX_DEPLOYMENT_TARGET=13.0.
sh.buildFuse.notFuseT	ERROR: fuse2fs (%@) is not linked exclusively against FUSE-T.	ERROR: fuse2fs (%@) no está enlazado exclusivamente contra FUSE-T.
sh.buildFuse.noHeaders	ERROR: FUSE-T headers (fuse.h) not found in %@ or %@.	ERROR: no se encuentran las cabeceras de FUSE-T (fuse.h) en %@ ni en %@.
sh.buildFuse.spaceInPath	ERROR: the build directory must not contain spaces: %@	ERROR: el directorio de compilación no puede contener espacios: %@
sh.buildFuse.badChecksum	ERROR: SHA-256 mismatch for %@ (expected %@, got %@); file removed.	ERROR: SHA-256 no coincide para %@ (esperado %@, obtenido %@); fichero eliminado.
sh.buildFuse.unpinned	WARNING: no pinned SHA-256 for e2fsprogs %@; download integrity not verified.	AVISO: no hay SHA-256 fijado para e2fsprogs %@; no se verifica la integridad de la descarga.
sh.buildFuse.failedLog	ERROR: build step failed. Full log: %@ (last lines below):	ERROR: falló un paso de la compilación. Log completo: %@ (últimas líneas abajo):
EOF
}

om_lookup() {
    local key=$1 lang line k en es
    lang=$(om_preferred_language)
    while IFS=$'\t' read -r k en es; do
        [ -n "$k" ] || continue
        [ "$k" = "$key" ] || continue
        if [ "$lang" = es ]; then printf '%s' "$es"; else printf '%s' "$en"; fi
        return 0
    done < <(om_catalog)
    printf '%s' "$key"
}

# Sustituye cada %@ en orden. El texto insertado no se reinterpreta.
om_fill() {
    local rest=$1 out=""
    shift
    while [ "$#" -gt 0 ]; do
        case "$rest" in
            *%@*)
                out="${out}${rest%%%@*}$1"
                rest="${rest#*%@}"
                shift
                ;;
            *) break ;;
        esac
    done
    printf '%s' "${out}${rest}"
}

t() {
    local key=$1
    shift
    printf '%s\n' "$(om_fill "$(om_lookup "$key")" "$@")"
}

terr() {
    t "$@" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    root=$(cd "$(dirname "$0")/.." && pwd)
    declare -a catalog_keys=()
    while IFS=$'\t' read -r k en es; do
        [ -n "${k:-}" ] || continue
        [[ "$k" =~ ^sh\.[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*$ ]] || { echo "bad key: $k" >&2; exit 1; }
        en_n=${en//%@/}
        es_n=${es//%@/}
        en_count=$(( (${#en} - ${#en_n}) / 2 ))
        es_count=$(( (${#es} - ${#es_n}) / 2 ))
        [ "$en_count" = "$es_count" ] || { echo "placeholder mismatch: $k" >&2; exit 1; }
        [ -n "$en" ] && [ -n "$es" ] || { echo "empty text: $k" >&2; exit 1; }
        catalog_keys+=("$k")
    done < <(om_catalog)

    used=$(grep -h -o -E 't(err)? sh\.[A-Za-z0-9.]+' \
        "$root/Makefile" "$root"/scripts/*.sh | sed -E 's/^terr /t /; s/^t //' | sort -u)
    missing=0
    for key in $used; do
        found=0
        for have in "${catalog_keys[@]}"; do
            [ "$have" = "$key" ] && found=1 && break
        done
        [ "$found" = 1 ] || { echo "missing catalog entry: $key" >&2; missing=1; }
    done
    for have in "${catalog_keys[@]}"; do
        if ! printf '%s\n' "$used" | grep -qx "$have"; then
            echo "unused catalog entry: $have" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ]
    OMNIMOUNT_LANG=en
    OM_LANG_CACHED=en
    [ "$(t sh.common.unknown)" = "unknown" ]
    [ "$(t sh.makeApp.missingProduct "/tmp/x")" = "ERROR: built product /tmp/x does not exist" ]
    [ "$(t sh.checkNtfs.oldMacOS a b "100% %@")" = "ERROR: a (b) requires macOS 100% %@; Omnimount supports 13+. Rebuild with MACOSX_DEPLOYMENT_TARGET=13.0 make ntfs3g." ]
    unset OM_LANG_CACHED
    OMNIMOUNT_LANG=es
    OM_LANG_CACHED=es
    [ "$(t sh.common.unknown)" = "desconocido" ]
    [ "$(t sh.makeApp.building)" = "==> Compilando en modo release" ]
    unset OM_LANG_CACHED
    OMNIMOUNT_LANG=fr
    OM_LANG_CACHED=en
    # fr is not a supported override: the cached value above is what om_preferred_language
    # would store. Recompute it for real.
    unset OM_LANG_CACHED
    [ "$(om_preferred_language)" = "en" ]
    for override in es-ES es_MX " ES "; do
        OMNIMOUNT_LANG=$override
        unset OM_LANG_CACHED
        [ "$(t sh.common.unknown)" = "desconocido" ]
    done
    OMNIMOUNT_LANG=esperanto
    unset OM_LANG_CACHED
    [ "$(t sh.common.unknown)" = "unknown" ]
    echo "l10n ok"
fi
