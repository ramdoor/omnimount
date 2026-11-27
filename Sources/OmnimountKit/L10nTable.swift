import Foundation

/// Inglés y español de cada clave `área.ámbito.nombre`. Ver `L10n`.
enum L10nTable {
    struct Text {
        let en: String
        let es: String
    }

    static let entries: [String: Text] = [
        // app.textSize
        "app.textSize.normal": .init(en: "Normal", es: "Normal"),
        // retro.pi
        "retro.pi.name": .init(en: "Raspberry Pi (generic)", es: "Raspberry Pi (genérico)"),
        // cli.detect
        "cli.detect.yes": .init(en: "yes", es: "sí"),
        "cli.detect.corrupt": .init(en: "NO (corrupt)", es: "NO (corrupta)"),
        // cli.common
        "cli.common.unnamed": .init(en: "unnamed", es: "sin nombre"),
        // error.format
        "error.format.empty": .init(en: "empty", es: "vacía"),
        // disk.fs
        "disk.fs.unknown": .init(en: "unknown", es: "desconocido"),
        // retro.arkos
        "retro.arkos.advice": .init(en: "ArkOS card. The EASYROMS partition holds your roms; the system partition is ext4 and should not be edited by hand. Back it up with `omnimount clone` before touching anything.", es: "Tarjeta de ArkOS. La partición EASYROMS contiene tus roms; la partición del sistema es ext4 y no debe modificarse a mano. Haz una copia con `omnimount clone` antes de tocar nada."),
        // retro.batocera
        "retro.batocera.advice": .init(en: "Batocera card. The user partition (SHARE) is ext4; mount it with Omnimount to manage roms and saves.", es: "Tarjeta de Batocera. La partición de usuario (SHARE) es ext4; móntala con Omnimount para gestionar roms y saves."),
        "retro.batocera.share": .init(en: "Likely a Batocera data partition (roms/saves on ext4).", es: "Posible partición de datos de Batocera (roms/saves en ext4)."),
        // retro.rocknix
        "retro.rocknix.advice": .init(en: "ROCKNIX card (formerly JELOS). The games partition is usually ext4.", es: "Tarjeta de ROCKNIX (antes JELOS). La partición de juegos suele ser ext4."),
        "retro.rocknix.games": .init(en: "Likely a ROCKNIX/JELOS games partition (ext4).", es: "Posible partición de juegos de ROCKNIX/JELOS (ext4)."),
        // retro.muos
        "retro.muos.advice": .init(en: "Typical muOS or Knulli roms partition.", es: "Partición de roms típica de muOS o Knulli."),
        // retro.retropie
        "retro.retropie.advice": .init(en: "RetroPie card. The system is ext4; roms live at /home/pi/RetroPie/roms inside the system partition.", es: "Tarjeta de RetroPie. El sistema es ext4; los roms viven en /home/pi/RetroPie/roms dentro de la partición del sistema."),
        // retro.recalbox
        "retro.recalbox.advice": .init(en: "Recalbox card. The data partition is ext4.", es: "Tarjeta de Recalbox. La partición de datos es ext4."),
        // retro.pi
        "retro.pi.advice": .init(en: "Boot partition of a Raspberry Pi-style image; the companion system partition is usually ext4.", es: "Partición de arranque de una imagen tipo Raspberry Pi; la partición del sistema acompañante suele ser ext4."),
        // error.mount
        "error.mount.notRoot": .init(en: "Mounting requires root privileges. Run the command with sudo.", es: "Montar requiere privilegios de root. Ejecuta el comando con sudo."),
        "error.mount.noFuse": .init(en: "No FUSE layer installed. Recommended: brew install --cask macos-fuse-t/cask/fuse-t (kext-free). Alternative: brew install --cask macfuse.", es: "No hay capa FUSE instalada. Recomendado: brew install --cask macos-fuse-t/cask/fuse-t (sin kext). Alternativa: brew install --cask macfuse."),
        "error.mount.toolMissing": .init(en: "%@ not found. See the README to install it.", es: "No se encontró %@. Consulta el README para instalarlo."),
        "error.mount.unsupported": .init(en: "Omnimount cannot mount %@.", es: "Omnimount no puede montar %@."),
        "error.mount.failed": .init(en: "%@ failed to mount: %@", es: "%@ falló al montar: %@"),
        "error.mount.unmount": .init(en: "Could not unmount: %@", es: "No se pudo desmontar: %@"),
        "error.mount.fsck": .init(en: "Verification (fsck) found problems: %@", es: "La verificación (fsck) encontró problemas: %@"),
        "error.mount.needsRepair": .init(en: "Cannot mount %@ for writing: e2fsck did not finish with a safe result. Check the unmounted disk with e2fsck or from Linux before retrying. Detail: %@", es: "No se puede montar %@ en escritura: e2fsck no terminó con un resultado seguro. Comprueba el disco desmontado con e2fsck o desde Linux antes de volver a intentarlo. Detalle: %@"),
        "error.mount.quota": .init(en: "This disk uses ext4 internal quotas (common on NAS disks), which fuse2fs does not support. Disable them (no data loss) with: sudo omnimount mount %@ --fix-quota — or with tune2fs -O ^quota,^project.", es: "Este disco usa cuotas internas de ext4 (habitual en discos de NAS), que fuse2fs no soporta. Desactívalas (no borra datos) con: sudo omnimount mount %@ --fix-quota — o con tune2fs -O ^quota,^project."),
        "error.mount.notVisible": .init(en: "%@ exited cleanly but the volume is not mounted. Usual cause: the FUSE layer is not operational (blocked kext or incomplete install). Output: %@ %@", es: "%@ terminó sin error pero el volumen no aparece montado. Causa habitual: la capa FUSE no está operativa (kext bloqueado o instalación incompleta). Salida: %@ %@"),
        "error.mount.stillMounted": .init(en: "The volume is still mounted at %@.", es: "El volumen sigue montado en %@."),
        // error.shell
        "error.shell.launch": .init(en: "Could not run %@: %@", es: "No se pudo ejecutar %@: %@"),
        // disk.hint
        "disk.hint.linux": .init(en: "Linux (likely ext4)", es: "Linux (posible ext4)"),
        "disk.hint.hiddenFat": .init(en: "Hidden FAT (%@); mount it after `omnimount unhide`", es: "FAT oculta (%@); móntala tras `omnimount unhide`"),
        // error.disk
        "error.disk.diskutil": .init(en: "diskutil failed: %@", es: "diskutil falló: %@"),
        "error.disk.plist": .init(en: "Could not parse diskutil output.", es: "No se pudo interpretar la salida de diskutil."),
        // error.detect
        "error.detect.read": .init(en: "Cannot read %@. Reading the device node requires privileges: run with sudo.", es: "No se puede leer %@. Leer el nodo de dispositivo requiere privilegios: ejecuta con sudo."),
        // error.clone
        "error.clone.notRoot": .init(en: "Cloning/restoring accesses the raw device: run with sudo.", es: "Clonar/restaurar accede al dispositivo en bruto: ejecuta con sudo."),
        "error.clone.open": .init(en: "Could not open %@.", es: "No se pudo abrir %@."),
        "error.clone.size": .init(en: "Could not determine the size of %@.", es: "No se pudo determinar el tamaño de %@."),
        "error.clone.tooBig": .init(en: "The image (%@) does not fit in the target (%@).", es: "La imagen (%@) no cabe en el destino (%@)."),
        "error.clone.unmount": .init(en: "Could not unmount the disk before the operation: %@", es: "No se pudo desmontar el disco antes de la operación: %@"),
        "error.clone.io": .init(en: "I/O error: %@", es: "Error de E/S: %@"),
        "error.clone.missing": .init(en: "External target %@ was not found.", es: "No se encontró el objetivo externo %@."),
        "error.clone.ambiguous": .init(en: "Possible FUSE-T mount at %@. Eject the volume in Omnimount and try again; its label does not uniquely identify the disk.", es: "Posible montaje FUSE-T en %@. Expulsa el volumen desde Omnimount y vuelve a intentarlo; la etiqueta no identifica el disco de forma inequívoca."),
        "error.clone.stillMounted": .init(en: "%@ is still mounted or has an unidentified FUSE-T mount at %@. Eject it in Omnimount and try again.", es: "%@ sigue montado o tiene un montaje FUSE-T sin identificar en %@. Expúlsalo desde Omnimount y vuelve a intentarlo."),
        "error.clone.empty": .init(en: "The image is empty and cannot be restored.", es: "La imagen está vacía; no se puede restaurar."),
        "error.clone.shortRead": .init(en: "Unexpected end of file: copied %@ of %@ bytes.", es: "Fin de archivo inesperado: copiados %@ de %@ bytes."),
        "error.clone.read": .init(en: "read at offset %@: %@", es: "lectura en offset %@: %@"),
        "error.clone.write": .init(en: "write at offset %@: %@", es: "escritura en offset %@: %@"),
        // disk.fs
        "disk.fs.ext4": .init(en: "ext4 (Linux/retro consoles)", es: "ext4 (Linux/consolas retro)"),
        "disk.fs.fat32": .init(en: "FAT32 (works everywhere, files <4 GB)", es: "FAT32 (compatible con todo, ficheros <4 GB)"),
        "disk.fs.exfat": .init(en: "exFAT (compatible, no 4 GB limit)", es: "exFAT (compatible, sin límite de 4 GB)"),
        // error.format
        "error.format.notRoot": .init(en: "Formatting requires root privileges.", es: "Formatear requiere privilegios de root."),
        "error.format.toolMissing": .init(en: "%@ not found. Check `omnimount doctor`.", es: "No se encontró %@. Revisa `omnimount doctor`."),
        "error.format.unmount": .init(en: "Could not unmount before formatting: %@", es: "No se pudo desmontar antes de formatear: %@"),
        "error.format.failed": .init(en: "%@ failed: %@", es: "%@ falló: %@"),
        "error.format.label": .init(en: "Invalid label: %@", es: "Etiqueta no válida: %@"),
        "error.format.slash": .init(en: "cannot contain '/'", es: "no puede contener '/'"),
        "error.format.extLength": .init(en: "at most 16 bytes on ext*", es: "máximo 16 bytes en ext*"),
        "error.format.fatLength": .init(en: "at most 11 characters on FAT32", es: "máximo 11 caracteres en FAT32"),
        "error.format.stillMounted": .init(en: "%@ is still mounted", es: "%@ sigue montada"),
        "error.format.mbrType": .init(en: ", MBR type %@", es: ", tipo MBR %@"),
        "error.format.summary": .init(en: "%@ formatted as %@ «%@»%@", es: "%@ formateada como %@ «%@»%@"),
        // error.helper
        "error.helper.missingPartition": .init(en: "External partition %@ does not exist", es: "No existe la partición externa %@"),
        // error.unmount
        "error.unmount.notMounted": .init(en: "%@ is not mounted.", es: "%@ no está montada."),
        // error.helper
        "error.helper.noQuota": .init(en: "The partition has no quotas enabled.", es: "La partición no tiene cuotas activadas."),
        // error.format
        "error.format.unknown": .init(en: "Unknown format: %@", es: "Formato desconocido: %@"),
        // error.helper
        "error.helper.fda": .init(en: "If the helper is enabled, grant Full Disk Access to OmnimountHelper in System Settings → Privacy & Security.", es: "Si el helper está activo, concede Acceso total al disco a OmnimountHelper en Ajustes → Privacidad y seguridad."),
        "error.helper.needsMacOS13": .init(en: "requires macOS 13 or later", es: "requiere macOS 13 o posterior"),
        "error.helper.notResponding": .init(en: "The helper is not responding: %@", es: "El helper no responde: %@"),
        "error.helper.noProxy": .init(en: "Could not create the XPC proxy.", es: "No se pudo crear el proxy XPC."),
        "error.helper.timeout": .init(en: "The helper did not respond in time.", es: "El helper no respondió a tiempo."),
        // disk.list
        "disk.list.empty": .init(en: "No external disks connected.", es: "No hay discos externos conectados."),
        // app.menu
        "app.menu.quota": .init(en: "%@ uses ext4 internal quotas (typical of NAS disks). fuse2fs cannot mount them, but they can be disabled without touching your data. If the disk goes back into a NAS, it will rebuild its quotas.", es: "%@ usa cuotas internas de ext4 (típico de discos de NAS). fuse2fs no puede montarlas, pero se pueden desactivar sin borrar datos. Si el disco vuelve a un NAS, este recalculará sus cuotas."),
        "app.menu.disableQuotas": .init(en: "Disable quotas and mount", es: "Desactivar cuotas y montar"),
        // app.common
        "app.common.cancel": .init(en: "Cancel", es: "Cancelar"),
        // app.menu
        "app.menu.refresh": .init(en: "Refresh disk list", es: "Refrescar la lista de discos"),
        "app.menu.updates": .init(en: "Updates…", es: "Actualizaciones…"),
        "app.menu.setup": .init(en: "Setup…", es: "Configuración…"),
        "app.menu.quit": .init(en: "Quit", es: "Salir"),
        "app.menu.helperOn": .init(en: "Helper active: password-free mounting", es: "Helper activo: montaje sin contraseñas"),
        "app.menu.approveHelper": .init(en: "Approve the helper in Settings → Login Items", es: "Falta aprobar el helper en Ajustes → Elementos de inicio"),
        "app.menu.openSettings": .init(en: "Open Settings", es: "Abrir Ajustes"),
        "app.menu.enableHelperHint": .init(en: "Enable the helper to mount without passwords", es: "Activa el helper para montar sin contraseñas"),
        // app.common
        "app.common.enableHelper": .init(en: "Enable helper", es: "Activar helper"),
        // app.menu
        "app.menu.helperUnavailable": .init(en: "Helper unavailable: %@", es: "Helper no disponible: %@"),
        "app.menu.dependenciesOk": .init(en: "All dependencies OK", es: "Dependencias correctas"),
        "app.menu.fuseMissing": .init(en: "FUSE layer missing (open Setup…)", es: "Falta la capa FUSE (abre Configuración…)"),
        "app.menu.fuse2fsMissing": .init(en: "fuse2fs missing (reinstall the app)", es: "Falta fuse2fs (reinstala la app)"),
        "app.menu.ntfsMissing": .init(en: "ntfs-3g missing (reinstall the app)", es: "Falta ntfs-3g (reinstala la app)"),
        "app.menu.cliMissing": .init(en: "omnimount CLI missing (make install)", es: "Falta el CLI omnimount (make install)"),
        "app.menu.cloneDisk": .init(en: "Clone disk to image…", es: "Clonar disco a imagen…"),
        "app.menu.restoreDisk": .init(en: "Restore image onto disk…", es: "Restaurar imagen en el disco…"),
        "app.menu.cloneHelp": .init(en: "Clone / restore the whole disk", es: "Clonar / restaurar el disco entero"),
        // app.common
        "app.common.makeWritable": .init(en: "Make writable", es: "Hacer escribible"),
        // app.menu
        "app.menu.readOnlyHelp": .init(en: "Read-only: Windows left this NTFS disk in an unclean state. Click to make it writable.", es: "Solo lectura: Windows dejó el disco NTFS en estado inconsistente. Pulsa para hacerlo escribible."),
        "app.menu.reveal": .init(en: "Reveal in Finder", es: "Mostrar en Finder"),
        "app.menu.eject": .init(en: "Eject", es: "Expulsar"),
        "app.menu.mount": .init(en: "Mount", es: "Montar"),
        "app.menu.clonePartition": .init(en: "Clone partition to image…", es: "Clonar partición a imagen…"),
        "app.menu.format": .init(en: "Format…", es: "Formatear…"),
        "app.menu.more": .init(en: "More actions", es: "Más acciones"),
        // app.textSize
        "app.textSize.large": .init(en: "Large", es: "Grande"),
        "app.textSize.extraLarge": .init(en: "Extra large", es: "Muy grande"),
        // app.setup
        "app.setup.title": .init(en: "Omnimount Setup", es: "Configuración de Omnimount"),
        "app.setup.intro": .init(en: "Every row is checked live. Complete the red ones, in order.", es: "Cada fila se comprueba en vivo. Completa las que estén en rojo, en orden."),
        "app.setup.fuseDetail": .init(en: "The layer that mounts filesystems in user space. FUSE-T needs no kext and no reboots.", es: "La capa que permite montar sistemas de ficheros en espacio de usuario. FUSE-T no necesita kext ni reinicios."),
        "app.setup.installing": .init(en: "Installing…", es: "Instalando…"),
        "app.setup.installFuse": .init(en: "Install FUSE-T", es: "Instalar FUSE-T"),
        "app.setup.fuse2fsTitle": .init(en: "fuse2fs (ext2/3/4 mounting)", es: "fuse2fs (montaje ext2/3/4)"),
        "app.setup.bundled": .init(en: "Bundled inside the app.", es: "Incluido dentro de la app."),
        "app.setup.copyCommand": .init(en: "Copy command", es: "Copiar comando"),
        "app.setup.ntfsTitle": .init(en: "ntfs-3g (NTFS mounting)", es: "ntfs-3g (montaje NTFS)"),
        "app.setup.ntfsDetail": .init(en: "Bundled inside the app, built against FUSE-T (no macFUSE needed).", es: "Incluido dentro de la app, compilado contra FUSE-T (sin macFUSE)."),
        "app.setup.e2fsTitle": .init(en: "e2fsprogs (ext4 checking and formatting)", es: "e2fsprogs (verificación y formateo ext4)"),
        "app.setup.e2fsDetail": .init(en: "e2fsck, mkfs.ext4 and friends — bundled inside the app.", es: "e2fsck, mkfs.ext4 y compañía — incluidos dentro de la app."),
        "app.setup.helperTitle": .init(en: "Privileged helper (password-free operations)", es: "Helper privilegiado (operaciones sin contraseña)"),
        "app.setup.helperDetail": .init(en: "A daemon you approve once in Settings → Login Items.", es: "Daemon aprobado una única vez en Ajustes → Elementos de inicio."),
        "app.setup.openLoginItems": .init(en: "Open Login Items", es: "Abrir Elementos de inicio"),
        "app.setup.helperStuck": .init(en: "The helper is registered but won't start (usually after updating the app). \"Repair helper\" re-registers it; then check again.", es: "El helper está registrado pero no arranca (suele pasar tras actualizar la app). \"Reparar helper\" lo re-registra; después vuelve a comprobar."),
        "app.setup.fdaHint": .init(en: "Add the binary /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper with + (Cmd+Shift+G to paste the path).", es: "Añade con + el binario /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper (Cmd+Mayús+G para pegar la ruta)."),
        "app.setup.repairHelper": .init(en: "Repair helper", es: "Reparar helper"),
        "app.setup.openFda": .init(en: "Open Full Disk Access", es: "Abrir Acceso total al disco"),
        "app.setup.adminTitle": .init(en: "Mounting with an admin password", es: "Montaje con contraseña de administrador"),
        "app.setup.adminDetail": .init(en: "Password-free mounting needs macOS 13 or later. On Monterey, Omnimount asks for your admin password each time you mount or eject. Everything else works the same.", es: "El montaje sin contraseña necesita macOS 13 o posterior. En Monterey, Omnimount te pedirá tu contraseña de administrador cada vez que montes o expulses. El resto funciona igual."),
        "app.setup.copied": .init(en: "Copied: %@ — paste it in Terminal", es: "Copiado: %@ — pégalo en Terminal"),
        "app.setup.preferences": .init(en: "Preferences", es: "Preferencias"),
        "app.setup.textSize": .init(en: "Menu text size", es: "Tamaño del texto del menú"),
        "app.setup.newWindow": .init(en: "Open each disk in a new Finder window", es: "Abrir cada disco en una ventana nueva del Finder"),
        "app.setup.ready": .init(en: "All set. Omnimount is fully operational.", es: "Todo listo. Omnimount está completamente operativo."),
        "app.setup.checkAgain": .init(en: "Check again", es: "Volver a comprobar"),
        "app.setup.fuseT": .init(en: "FUSE layer — FUSE-T (kext-free) ✓", es: "Capa FUSE — FUSE-T (sin kext) ✓"),
        "app.setup.macFuse": .init(en: "FUSE layer — macFUSE (kext)", es: "Capa FUSE — macFUSE (kext)"),
        "app.setup.fuseNeeded": .init(en: "FUSE layer (FUSE-T recommended)", es: "Capa FUSE (FUSE-T recomendado)"),
        "app.setup.fdaWaiting": .init(en: "Helper Full Disk Access (helper not available yet)", es: "Acceso total al disco del helper (helper no disponible aún)"),
        "app.setup.fdaOk": .init(en: "Helper Full Disk Access ✓", es: "Acceso total al disco del helper ✓"),
        "app.setup.fdaMissing": .init(en: "Helper Full Disk Access — MISSING", es: "Acceso total al disco del helper — FALTA"),
        // app.alert
        "app.alert.notCli": .init(en: "This is the Omnimount menu bar app, not the CLI. Use the omnimount command (/usr/local/bin/omnimount).", es: "Esto es la app de menú Omnimount, no el CLI. Usa el comando omnimount (/usr/local/bin/omnimount)."),
        "app.alert.adminPrompt": .init(en: "Omnimount needs administrator permission to access the disk.", es: "Omnimount necesita permisos de administrador para acceder al disco."),
        "app.alert.cloneNeedsHelper": .init(en: "Cloning from the app requires the helper. Alternative: sudo omnimount clone %@ image.img", es: "Clonar desde la app requiere el helper activo. Alternativa: sudo omnimount clone %@ imagen.img"),
        "app.alert.saveImage": .init(en: "Save disk image", es: "Guardar imagen del disco"),
        "app.alert.cloning": .init(en: "Cloning %@ → %@…", es: "Clonando %@ → %@…"),
        "app.alert.imageSaved": .init(en: "Image saved to %@", es: "Imagen guardada en %@"),
        "app.alert.restoreNeedsHelper": .init(en: "Restoring from the app requires the helper. Alternative: sudo omnimount restore image.img %@", es: "Restaurar desde la app requiere el helper activo. Alternativa: sudo omnimount restore imagen.img %@"),
        "app.alert.chooseImage": .init(en: "Choose image to restore", es: "Elegir imagen a restaurar"),
        "app.alert.restoreTitle": .init(en: "Restore over %@?", es: "¿Restaurar sobre %@?"),
        "app.alert.restoreBody": .init(en: "ALL contents of %@ will be overwritten with %@. This cannot be undone.", es: "Se sobrescribirá TODO el contenido de %@ con %@. Esta operación no se puede deshacer."),
        // app.common
        "app.common.restore": .init(en: "Restore", es: "Restaurar"),
        // app.alert
        "app.alert.restoring": .init(en: "Restoring %@ → %@…", es: "Restaurando %@ → %@…"),
        "app.alert.imageRestored": .init(en: "Image restored to %@", es: "Imagen restaurada en %@"),
        "app.alert.formatNeedsHelper": .init(en: "Formatting from the app requires the helper. Alternative: sudo omnimount format.", es: "Formatear desde la app requiere el helper activo. Alternativa: sudo omnimount format."),
        "app.alert.writableNeedsHelper": .init(en: "Making it writable requires the helper enabled.", es: "Hacerlo escribible requiere el helper activo."),
        "app.alert.writableTitle": .init(en: "Make %@ writable?", es: "¿Hacer escribible %@?"),
        "app.alert.writableBody": .init(en: "Windows left this NTFS disk read-only (Fast Startup/hibernation, or unplugged without ejecting). That state will be cleared so you can write. Your files are untouched; only a suspended Windows session, if any, is discarded.", es: "Windows dejó este disco NTFS en solo lectura (Inicio rápido/hibernación o desconexión sin expulsar). Se limpiará ese estado para poder escribir. Tus ficheros no se tocan; solo se descarta una sesión de Windows en suspensión, si la hubiera."),
        "app.alert.writableFailed": .init(en: "Could not make it writable; the disk needs repair on Windows (chkdsk).", es: "No se pudo hacer escribible; el disco necesita repararse en Windows (chkdsk)."),
        "app.alert.quotaNeedsHelper": .init(en: "One-click fix needs the helper enabled; or run: sudo omnimount mount %@ --fix-quota", es: "Para el arreglo con un clic activa el helper; o ejecuta: sudo omnimount mount %@ --fix-quota"),
        "app.alert.cliMissing": .init(en: "The `omnimount` CLI was not found. Install it with `make install` (see README).", es: "No se encontró el CLI `omnimount`. Instálalo con `make install` (ver README)."),
        // app.format
        "app.format.title": .init(en: "Format partition", es: "Formatear partición"),
        "app.format.erase": .init(en: "⚠️ This operation will PERMANENTLY ERASE ALL DATA on the partition. It cannot be undone.", es: "⚠️ Esta operación BORRARÁ TODOS LOS DATOS de la partición de forma permanente. No se puede deshacer."),
        "app.format.console": .init(en: "If this card belongs to a console (ArkOS, Batocera…), formatting the wrong partition can make it unbootable. Back it up first with `omnimount clone`.", es: "Si la tarjeta es de una consola (ArkOS, Batocera…), formatear la partición equivocada puede dejarla sin arrancar. Haz antes una copia con `omnimount clone`."),
        "app.format.picker": .init(en: "Format", es: "Formato"),
        "app.format.volumeLabel": .init(en: "Volume label", es: "Etiqueta del volumen"),
        "app.format.confirm": .init(en: "I understand all content of %@ will be erased", es: "Entiendo que se borrará todo el contenido de %@"),
        "app.format.eraseButton": .init(en: "Format (erases everything)", es: "Formatear (borra todo)"),
        // cli.root
        "cli.root.abstract": .init(en: "Read/write access to ext2/3/4 and NTFS on macOS, wrapping fuse2fs and ntfs-3g.", es: "Acceso de lectura/escritura a ext2/3/4 y NTFS en macOS, envolviendo fuse2fs y ntfs-3g."),
        // cli.common
        "cli.common.partitionMissing": .init(en: "External partition %@ was not found. Use `omnimount list` to see the available ones.", es: "No se encontró la partición externa %@. Usa `omnimount list` para ver las disponibles."),
        "cli.common.needsRoot": .init(en: "This operation needs to read/write /dev/diskXsY. Run it with sudo.", es: "Esta operación necesita leer/escribir /dev/diskXsY. Ejecútala con sudo."),
        // cli.list
        "cli.list.abstract": .init(en: "Lists external disks and their partitions, with the filesystem detected when permissions allow.", es: "Lista discos externos y sus particiones, con el FS detectado si hay permisos."),
        "cli.list.sudo": .init(en: "%@ (sudo to detect)", es: "%@ (sudo para detectar)"),
        "cli.list.mounted": .init(en: "mounted at %@", es: "montada en %@"),
        "cli.list.unmounted": .init(en: "not mounted", es: "sin montar"),
        "cli.list.card": .init(en: "Detected a %@ card: %@", es: "Detectada tarjeta de %@: %@"),
        // cli.detect
        "cli.detect.abstract": .init(en: "Detects a partition's filesystem by reading its magic bytes.", es: "Detecta el sistema de ficheros de una partición leyendo sus magic bytes."),
        // cli.common
        "cli.common.partition": .init(en: "Partition identifier, e.g. disk4s1", es: "Identificador de la partición, p. ej. disk4s1"),
        // cli.detect
        "cli.detect.verbose": .init(en: "Dump boot sector parameters (diagnostics).", es: "Volcar parámetros del boot sector (diagnóstico)."),
        "cli.detect.label": .init(en: "Label: %@", es: "Etiqueta: %@"),
        "cli.detect.mountable": .init(en: "Mountable with Omnimount ✓", es: "Montable con Omnimount ✓"),
        "cli.detect.native": .init(en: "macOS supports it natively.", es: "macOS lo soporta de forma nativa."),
        "cli.detect.unsupported": .init(en: "Not supported by Omnimount.", es: "No soportado por Omnimount."),
        "cli.detect.permissions": .init(en: "Cannot read %@ (permissions?).", es: "No se puede leer %@ (¿permisos?)."),
        "cli.detect.shortSector": .init(en: "Incomplete boot sector (%@ bytes).", es: "Boot sector incompleto (%@ bytes)."),
        "cli.detect.signature": .init(en: "signature 0x55AA:", es: "firma 0x55AA:"),
        // cli.mount
        "cli.mount.abstract": .init(en: "Mounts an ext2/3/4 (fuse2fs) or NTFS (ntfs-3g) partition.", es: "Monta una partición ext2/3/4 (fuse2fs) o NTFS (ntfs-3g)."),
        "cli.mount.point": .init(en: "Mount point (default /Volumes/<label>).", es: "Punto de montaje (por defecto /Volumes/<etiqueta>)."),
        "cli.mount.readOnly": .init(en: "Mount read-only.", es: "Montar en solo lectura."),
        "cli.mount.fixQuota": .init(en: "Disables ext4 internal quotas (NAS disks) before mounting. Does not delete data.", es: "Desactiva las cuotas internas ext4 (discos de NAS) antes de montar. No borra datos."),
        "cli.mount.makeWritable": .init(en: "NTFS: clears the Windows 'dirty' state (ntfsfix + remove_hiberfile) and mounts read-write.", es: "NTFS: limpia el estado 'sucio' de Windows (ntfsfix + remove_hiberfile) y monta en escritura."),
        "cli.mount.disabling": .init(en: "Disabling internal quotas on %@…", es: "Desactivando cuotas internas de %@…"),
        "cli.mount.mounted": .init(en: "Mounted %@ (%@) at %@", es: "Montado %@ (%@) en %@"),
        "cli.mount.readOnlyWarning": .init(en: "WARNING: mounted READ-ONLY — Windows left the NTFS volume 'dirty' (Fast Startup/hibernation). Mount again with --make-writable, or repair it on Windows with chkdsk.", es: "AVISO: montado en SOLO LECTURA — Windows dejó el NTFS 'sucio' (Inicio rápido/hibernación). Vuelve a montar con --make-writable, o repáralo en Windows con chkdsk."),
        // cli.unmount
        "cli.unmount.abstract": .init(en: "Cleanly unmounts a partition mounted by Omnimount.", es: "Desmonta limpiamente una partición montada por Omnimount."),
        "cli.unmount.target": .init(en: "Identifier (disk4s1) or mount point (/Volumes/X).", es: "Identificador (disk4s1) o punto de montaje (/Volumes/X)."),
        "cli.unmount.done": .init(en: "Unmounted %@", es: "Desmontado %@"),
        // cli.test
        "cli.test.abstract": .init(en: "Full test: mount, write a file, unmount, and verify with fsck.", es: "Prueba completa: monta, escribe un fichero, desmonta y verifica con fsck."),
        "cli.test.stepMount": .init(en: "1/4 Mounting %@ (%@)…", es: "1/4 Montando %@ (%@)…"),
        "cli.test.mounted": .init(en: "Mounted at %@", es: "Montado en %@"),
        "cli.test.stepWrite": .init(en: "2/4 Write test…", es: "2/4 Prueba de escritura…"),
        "cli.test.mismatch": .init(en: "What was read does not match what was written.", es: "Lo leído no coincide con lo escrito."),
        "cli.test.ok": .init(en: "Write and read-back succeeded ✓", es: "Escritura y relectura correctas ✓"),
        "cli.test.failed": .init(en: "Write failed: %@", es: "FALLO de escritura: %@"),
        "cli.test.stepUnmount": .init(en: "3/4 Unmounting…", es: "3/4 Desmontando…"),
        "cli.test.unmounted": .init(en: "Unmounted ✓", es: "Desmontado ✓"),
        "cli.test.stepVerify": .init(en: "4/4 Verifying with fsck…", es: "4/4 Verificando con fsck…"),
        "cli.test.clean": .init(en: "Filesystem is clean ✓", es: "Sistema de ficheros limpio ✓"),
        // cli.clone
        "cli.clone.abstract": .init(en: "Clones a whole disk (e.g. an SD card) to an .img file with a progress bar.", es: "Clona un disco completo (p. ej. una SD) a un fichero .img con barra de progreso."),
        "cli.clone.disk": .init(en: "Whole disk, e.g. disk4", es: "Disco entero, p. ej. disk4"),
        "cli.clone.output": .init(en: "Output .img file path.", es: "Ruta del fichero .img de salida."),
        "cli.clone.progress": .init(en: "Cloning %@ → %@", es: "Clonando %@ → %@"),
        "cli.clone.done": .init(en: "Clone completed.", es: "Clonado completado."),
        // cli.restore
        "cli.restore.abstract": .init(en: "Restores an .img onto a disk. DESTRUCTIVE: erases the entire target disk.", es: "Restaura una imagen .img sobre un disco. DESTRUCTIVO: borra todo el disco destino."),
        "cli.restore.input": .init(en: "Input .img file path.", es: "Ruta del fichero .img de entrada."),
        "cli.restore.disk": .init(en: "Whole target disk, e.g. disk4", es: "Disco entero de destino, p. ej. disk4"),
        // cli.common
        "cli.common.force": .init(en: "Do not ask for interactive confirmation.", es: "No pedir confirmación interactiva."),
        // cli.restore
        "cli.restore.notExternal": .init(en: "%@ is not an external disk. For safety, restore only works on external disks.", es: "%@ no es un disco externo. Por seguridad solo se restaura sobre discos externos."),
        "cli.restore.warning": .init(en: "⚠️  ALL content of %@ (%@, %@) will be ERASED.", es: "⚠️  Se BORRARÁ TODO el contenido de %@ (%@, %@)."),
        "cli.restore.confirm": .init(en: "Type the disk identifier (%@) to confirm: ", es: "Escribe el identificador del disco (%@) para confirmar: "),
        // cli.common
        "cli.common.cancelled": .init(en: "Cancelled.", es: "Cancelado."),
        // cli.restore
        "cli.restore.progress": .init(en: "Restoring %@ → %@", es: "Restaurando %@ → %@"),
        "cli.restore.done": .init(en: "Restore completed.", es: "Restauración completada."),
        // cli.format
        "cli.format.abstract": .init(en: "Formats a partition. DESTRUCTIVE: erases all of its content.", es: "Formatea una partición. DESTRUCTIVO: borra todo su contenido."),
        "cli.format.discussion": .init(en: "Formats: ext2, ext3, ext4, ntfs, fat32, exfat. Also updates the MBR type when applicable.", es: "Formatos: ext2, ext3, ext4, ntfs, fat32, exfat. Ajusta también el tipo MBR si procede."),
        "cli.format.target": .init(en: "Target format: ext2|ext3|ext4|ntfs|fat32|exfat", es: "Formato destino: ext2|ext3|ext4|ntfs|fat32|exfat"),
        "cli.format.label": .init(en: "Volume label.", es: "Etiqueta del volumen."),
        "cli.format.unknown": .init(en: "Unknown format: %@. Use ext2|ext3|ext4|ntfs|fat32|exfat.", es: "Formato desconocido: %@. Usa ext2|ext3|ext4|ntfs|fat32|exfat."),
        "cli.format.warning": .init(en: "⚠️  ALL content of %@%@ (%@) will be ERASED.", es: "⚠️  Se BORRARÁ TODO el contenido de %@%@ (%@)."),
        "cli.format.confirm": .init(en: "Type the identifier (%@) to confirm: ", es: "Escribe el identificador (%@) para confirmar: "),
        // cli.unhide
        "cli.unhide.abstract": .init(en: "Clears the 'hidden' flag of a FAT partition in the MBR table.", es: "Quita la marca 'oculta' de una partición FAT en la tabla MBR."),
        "cli.unhide.discussion": .init(en: "macOS refuses to mount FAT partitions with a hidden MBR type (0x1C, 0x16, 0x1B, 0x1E), which is common on retro-console cards: ArkOS marks EASYROMS as 0x1C so Windows won't offer to format it. This command changes the type to its visible equivalent (0x1C → 0x0C…), a single byte that Linux and the console ignore. Back up the MBR before touching anything.", es: "macOS se niega a montar particiones FAT con tipo MBR oculto (0x1C, 0x16, 0x1B, 0x1E), algo habitual en tarjetas de consolas retro: ArkOS marca EASYROMS como 0x1C para que Windows no ofrezca formatearla. Este comando cambia el tipo a su equivalente visible (0x1C → 0x0C…), un único byte que Linux y la consola ignoran. Guarda copia del MBR antes de tocar nada."),
        "cli.unhide.notMbr": .init(en: "%@ does not use an MBR (FDisk) partition table; nothing to do.", es: "%@ no usa tabla de particiones MBR (FDisk); nada que hacer."),
        "cli.unhide.primaryOnly": .init(en: "Only primary MBR partitions (s1…s4).", es: "Solo particiones primarias MBR (s1…s4)."),
        "cli.unhide.read": .init(en: "Cannot read %@.", es: "No se puede leer %@."),
        "cli.unhide.badMbr": .init(en: "Unreadable MBR or missing 0x55AA signature.", es: "MBR ilegible o sin firma 0x55AA."),
        "cli.unhide.badType": .init(en: "Partition type is %@, which is not a hidden FAT type.", es: "La partición tiene tipo %@, que no es un tipo FAT oculto."),
        "cli.unhide.changing": .init(en: "Current type of %@: %@ (hidden) → new type: %@", es: "Tipo actual de %@: %@ (oculta) → nuevo tipo: %@"),
        "cli.unhide.backup": .init(en: "MBR backup saved to %@", es: "Copia del MBR guardada en %@"),
        "cli.unhide.confirm": .init(en: "Continue? 1 byte of the partition table on %@ will be modified. [y/N]: ", es: "¿Continuar? Se modificará 1 byte de la tabla de particiones de %@. [s/N]: "),
        "cli.unhide.write": .init(en: "Cannot write to %@.", es: "No se puede escribir en %@."),
        "cli.unhide.updated": .init(en: "Partition table updated ✓", es: "Tabla de particiones actualizada ✓"),
        "cli.unhide.done": .init(en: "Done. If the volume does not appear within a few seconds: diskutil mount %@", es: "Listo. Si el volumen no aparece en unos segundos: diskutil mount %@"),
        // cli.doctor
        "cli.doctor.abstract": .init(en: "Checks dependency status (macFUSE, fuse2fs, ntfs-3g).", es: "Comprueba el estado de las dependencias (macFUSE, fuse2fs, ntfs-3g)."),
        "cli.doctor.missing": .init(en: "not found — %@", es: "no encontrado — %@"),
        "cli.doctor.fuseT": .init(en: "✓ FUSE layer: FUSE-T (kext-free)", es: "✓ Capa FUSE: FUSE-T (sin kext)"),
        "cli.doctor.macFuse": .init(en: "✓ FUSE layer: macFUSE (kext)", es: "✓ Capa FUSE: macFUSE (kext)"),
        "cli.doctor.noFuse": .init(en: "✗ FUSE layer: none — recommended: brew install --cask macos-fuse-t/cask/fuse-t", es: "✗ Capa FUSE: ninguna — recomendado: brew install --cask macos-fuse-t/cask/fuse-t"),
        "cli.doctor.fuse2fsHint": .init(en: "build it with scripts/build-fuse2fs.sh (see README)", es: "compílalo con scripts/build-fuse2fs.sh (ver README)"),
        "cli.doctor.e2fsck": .init(en: "e2fsck (ext checking)", es: "e2fsck (verificación ext)"),
        "cli.doctor.ntfsfix": .init(en: "ntfsfix (NTFS checking)", es: "ntfsfix (verificación NTFS)"),
        "cli.doctor.ready": .init(en: "All set: Omnimount can mount ext2/3/4 and NTFS.", es: "Todo listo: Omnimount puede montar ext2/3/4 y NTFS."),
        "cli.doctor.noExt": .init(en: "ext2/3/4 still cannot be mounted.", es: "Aún no se puede montar ext2/3/4."),
        "cli.doctor.noNtfs": .init(en: "NTFS still cannot be mounted.", es: "Aún no se puede montar NTFS."),
        // audit/app: estado ocupado por disco, identidad del disco, firma, doctor
        "app.alert.diskBusy": .init(en: "%@ is busy with another operation. Wait for it to finish.", es: "%@ está ocupado con otra operación. Espera a que termine."),
        "app.alert.repairBusy": .init(en: "Wait for the running operations to finish before repairing the helper.", es: "Espera a que terminen las operaciones en curso antes de reparar el helper."),
    ]
}
