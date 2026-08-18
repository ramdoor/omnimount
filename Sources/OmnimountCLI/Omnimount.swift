import ArgumentParser
import Foundation
import OmnimountKit

@main
struct Omnimount: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omnimount",
        abstract: "Acceso de lectura/escritura a ext2/3/4 y NTFS en macOS, envolviendo fuse2fs y ntfs-3g.",
        version: "0.1.4",
        subcommands: [
            List.self, Detect.self, Mount.self, Unmount.self,
            Test.self, Clone.self, Restore.self, Doctor.self,
            Unhide.self, Format.self,
        ],
        defaultSubcommand: List.self
    )
}

// MARK: - Utilidades compartidas

func resolvePartition(_ identifier: String) throws -> DiskPartition {
    let id = identifier.replacingOccurrences(of: "/dev/", with: "")
    let disks = try DiskLister.externalDisks()
    guard let partition = disks.flatMap(\.partitions).first(where: { $0.deviceIdentifier == id }) else {
        throw ValidationError("No se encontró la partición externa \(id). Usa `omnimount list` para ver las disponibles.")
    }
    return partition
}

func requireRoot() throws {
    guard Mounter.isRoot else {
        throw ValidationError("Esta operación necesita leer/escribir /dev/diskXsY. Ejecútala con sudo.")
    }
}

func printProgressBar(_ progress: CloneProgress) {
    let width = 30
    let filled = Int(progress.fraction * Double(width))
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    let formatter = ByteCountFormatter()
    let copied = formatter.string(fromByteCount: progress.bytesCopied)
    let total = formatter.string(fromByteCount: progress.totalBytes)
    let speed = formatter.string(fromByteCount: Int64(progress.bytesPerSecond))
    let percent = Int(progress.fraction * 100)
    // Solo fflush: fsync sobre stdout revienta con NSException si es una tubería.
    print("\r[\(bar)] \(percent)%  \(copied)/\(total)  \(speed)/s   ", terminator: "")
    fflush(stdout)
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lista discos externos y sus particiones, con el FS detectado si hay permisos.")

    func run() throws {
        let disks = try DiskLister.externalDisks()
        if disks.isEmpty {
            print("No hay discos externos conectados.")
            return
        }

        for disk in disks {
            let media = disk.mediaName.map { " — \($0)" } ?? ""
            print("\(disk.deviceIdentifier) (\(disk.humanSize))\(media)")

            var extLabels: [String: String] = [:]
            for partition in disk.partitions {
                var fsColumn: String
                var labelColumn = partition.volumeName ?? ""
                if let detection = try? FilesystemDetector.detect(devicePath: partition.devicePath) {
                    fsColumn = detection.filesystem.displayName
                    if let label = detection.label {
                        labelColumn = label
                        extLabels[partition.deviceIdentifier] = label
                    }
                } else {
                    fsColumn = "\(partition.contentHint) (sudo para detectar)"
                }
                let state = partition.mountPoint.map { "montada en \($0)" } ?? "sin montar"
                let label = labelColumn.isEmpty ? "" : " «\(labelColumn)»"
                print("  \(partition.deviceIdentifier)  \(partition.humanSize)  \(fsColumn)\(label)  \(state)")
            }

            if let match = RetroCards.identify(partitions: disk.partitions, extLabels: extLabels) {
                print("  🎮 Detectada tarjeta de \(match.firmware): \(match.advice)")
            }
        }
    }
}

// MARK: - detect

struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detecta el sistema de ficheros de una partición leyendo sus magic bytes.")

    @Argument(help: "Identificador de la partición, p. ej. disk4s1")
    var partition: String

    @Flag(name: .long, help: "Volcar parámetros del boot sector (diagnóstico).")
    var verbose = false

    func run() throws {
        let part = try resolvePartition(partition)
        let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
        print("\(part.deviceIdentifier): \(detection.filesystem.displayName)")
        if let label = detection.label { print("Etiqueta: \(label)") }
        if verbose { try dumpBootSector(devicePath: part.devicePath) }
        if detection.filesystem.isMountableByOmnimount {
            print("Montable con Omnimount ✓")
        } else if detection.filesystem.isNativelySupported {
            print("macOS lo soporta de forma nativa.")
        } else {
            print("No soportado por Omnimount.")
        }
    }

    /// Vuelca los campos BPB del boot sector (FAT/exFAT/NTFS) para diagnóstico.
    private func dumpBootSector(devicePath: String) throws {
        guard let handle = FileHandle(forReadingAtPath: devicePath) else {
            throw ValidationError("No se puede leer \(devicePath) (¿permisos?).")
        }
        defer { try? handle.close() }
        let bs = try handle.read(upToCount: 512) ?? Data()
        guard bs.count >= 512 else {
            throw ValidationError("Boot sector incompleto (\(bs.count) bytes).")
        }
        func u8(_ o: Int) -> Int { Int(bs[o]) }
        func u16(_ o: Int) -> Int { Int(bs[o]) | (Int(bs[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            u16(o) | (u16(o + 2) << 16)
        }
        let oem = String(data: bs.subdata(in: 3..<11), encoding: .ascii) ?? "?"
        print("--- boot sector ---")
        print("OEM: \(oem)")
        print("bytesPerSector: \(u16(11))")
        print("sectorsPerCluster: \(u8(13)) (cluster: \(u16(11) * u8(13)) bytes)")
        print("reservedSectors: \(u16(14))")
        print("numFATs: \(u8(16))")
        print("rootEntries(FAT12/16): \(u16(17))")
        print("totalSectors16: \(u16(19))  totalSectors32: \(u32(32))")
        print("mediaDescriptor: 0x\(String(u8(21), radix: 16))")
        print("sectorsPerFAT16: \(u16(22))  sectorsPerFAT32: \(u32(36))")
        let fsType32 = String(data: bs.subdata(in: 82..<90), encoding: .ascii) ?? "?"
        let fsType16 = String(data: bs.subdata(in: 54..<62), encoding: .ascii) ?? "?"
        print("fsType@54: '\(fsType16)'  fsType@82: '\(fsType32)'")
        print("firma 0x55AA: \(u8(510) == 0x55 && u8(511) == 0xAA ? "sí" : "NO (corrupta)")")
    }
}

// MARK: - mount

struct Mount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Monta una partición ext2/3/4 (fuse2fs) o NTFS (ntfs-3g).")

    @Argument(help: "Identificador de la partición, p. ej. disk4s1")
    var partition: String

    @Option(name: .long, help: "Punto de montaje (por defecto /Volumes/<etiqueta>).")
    var point: String?

    @Flag(name: [.customLong("read-only"), .customShort("r")], help: "Montar en solo lectura.")
    var readOnly = false

    /// Tipos MBR/GPT que garantizan FAT: montables vía diskutil sin root.
    private static let fatContentTypes: Set<String> = [
        "Windows_FAT_32", "DOS_FAT_32", "DOS_FAT_16", "DOS_FAT_12",
        "0x0B", "0x0C", "0x0E", "0x1C", "0x01", "0x04", "0x06", "0x14", "0x16", "0x1B", "0x1E",
    ]

    func run() throws {
        let part = try resolvePartition(partition)
        let detection: DetectionResult
        do {
            detection = try FilesystemDetector.detect(devicePath: part.devicePath)
        } catch {
            // Sin root no se pueden leer los magic bytes, pero si la tabla de
            // particiones dice FAT (p. ej. 0x1C, la EASYROMS oculta de ArkOS)
            // diskutil puede montarla sin privilegios.
            if Self.fatContentTypes.contains(part.content) {
                detection = DetectionResult(filesystem: .fat)
            } else {
                throw error
            }
        }
        if detection.filesystem.isMountableByOmnimount { try requireRoot() }
        let result = try Mounter.mount(partition: part, detection: detection,
                                       mountPoint: point, readOnly: readOnly)
        print("Montado \(result.devicePath) (\(result.filesystem.displayName)) en \(result.mountPoint)")
        print(result.mountPoint) // última línea = punto de montaje, para consumo por la app
    }
}

// MARK: - unmount

struct Unmount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Desmonta limpiamente una partición montada por Omnimount.")

    @Argument(help: "Identificador (disk4s1) o punto de montaje (/Volumes/X).")
    var target: String

    func run() throws {
        let mountPoint: String
        if target.hasPrefix("/") {
            mountPoint = target
        } else {
            let part = try resolvePartition(target)
            guard let current = part.mountPoint ?? Mounter.currentMountPoint(devicePath: part.devicePath) else {
                throw ValidationError("\(part.deviceIdentifier) no está montada.")
            }
            mountPoint = current
        }
        try Mounter.unmount(mountPoint: mountPoint)
        print("Desmontado \(mountPoint)")
    }
}

// MARK: - test

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prueba completa: monta, escribe un fichero, desmonta y verifica con fsck.")

    @Argument(help: "Identificador de la partición, p. ej. disk4s1")
    var partition: String

    func run() throws {
        try requireRoot()
        let part = try resolvePartition(partition)
        let detection = try FilesystemDetector.detect(devicePath: part.devicePath)

        print("1/4 Montando \(part.deviceIdentifier) (\(detection.filesystem.displayName))…")
        let result = try Mounter.mount(partition: part, detection: detection)
        print("    Montado en \(result.mountPoint)")

        print("2/4 Prueba de escritura…")
        let testFile = (result.mountPoint as NSString)
            .appendingPathComponent(".omnimount-test-\(getpid()).txt")
        let payload = "omnimount write test \(Date())"
        do {
            try payload.write(toFile: testFile, atomically: false, encoding: .utf8)
            let readBack = try String(contentsOfFile: testFile, encoding: .utf8)
            guard readBack == payload else {
                throw ValidationError("Lo leído no coincide con lo escrito.")
            }
            try FileManager.default.removeItem(atPath: testFile)
            print("    Escritura y relectura correctas ✓")
        } catch {
            print("    FALLO de escritura: \(error.localizedDescription)")
            try? Mounter.unmount(mountPoint: result.mountPoint)
            throw ExitCode(1)
        }

        print("3/4 Desmontando…")
        try Mounter.unmount(mountPoint: result.mountPoint)
        print("    Desmontado ✓")

        print("4/4 Verificando con fsck…")
        _ = try Mounter.verify(devicePath: part.devicePath, filesystem: detection.filesystem)
        print("    Sistema de ficheros limpio ✓")
    }
}

// MARK: - clone

struct Clone: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clona un disco completo (p. ej. una SD) a un fichero .img con barra de progreso.")

    @Argument(help: "Disco entero, p. ej. disk4")
    var disk: String

    @Argument(help: "Ruta del fichero .img de salida.")
    var image: String

    func run() throws {
        try requireRoot()
        let id = disk.replacingOccurrences(of: "/dev/", with: "")
        print("Clonando \(id) → \(image)")
        try Cloner.clone(wholeDisk: id, to: image, progress: printProgressBar)
        print("\nClonado completado.")
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restaura una imagen .img sobre un disco. DESTRUCTIVO: borra todo el disco destino.")

    @Argument(help: "Ruta del fichero .img de entrada.")
    var image: String

    @Argument(help: "Disco entero de destino, p. ej. disk4")
    var disk: String

    @Flag(name: .long, help: "No pedir confirmación interactiva.")
    var force = false

    func run() throws {
        try requireRoot()
        let id = disk.replacingOccurrences(of: "/dev/", with: "")

        // Solo discos externos: evita apuntar por error al disco del sistema.
        let disks = try DiskLister.externalDisks()
        guard let target = disks.first(where: { $0.deviceIdentifier == id }) else {
            throw ValidationError("\(id) no es un disco externo. Por seguridad solo se restaura sobre discos externos.")
        }

        if !force {
            print("⚠️  Se BORRARÁ TODO el contenido de \(id) (\(target.humanSize), \(target.mediaName ?? "sin nombre")).")
            print("Escribe el identificador del disco (\(id)) para confirmar: ", terminator: "")
            guard readLine() == id else {
                print("Cancelado.")
                throw ExitCode(1)
            }
        }

        print("Restaurando \(image) → \(id)")
        try Cloner.restore(imagePath: image, to: id, progress: printProgressBar)
        print("\nRestauración completada.")
    }
}

// MARK: - format

struct Format: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Formatea una partición. DESTRUCTIVO: borra todo su contenido.",
        discussion: "Formatos: ext2, ext3, ext4, ntfs, fat32, exfat. Ajusta también el tipo MBR si procede.")

    @Argument(help: "Identificador de la partición, p. ej. disk6s3")
    var partition: String

    @Argument(help: "Formato destino: ext2|ext3|ext4|ntfs|fat32|exfat")
    var format: String

    @Option(name: .long, help: "Etiqueta del volumen.")
    var label: String

    @Flag(name: .long, help: "No pedir confirmación interactiva.")
    var force = false

    func run() throws {
        try requireRoot()
        guard let target = TargetFormat(rawValue: format.lowercased()) else {
            throw ValidationError("Formato desconocido: \(format). Usa ext2|ext3|ext4|ntfs|fat32|exfat.")
        }
        let part = try resolvePartition(partition)

        if !force {
            let name = part.volumeName.map { " «\($0)»" } ?? ""
            print("⚠️  Se BORRARÁ TODO el contenido de \(part.deviceIdentifier)\(name) (\(part.humanSize)).")
            print("Escribe el identificador (\(part.deviceIdentifier)) para confirmar: ", terminator: "")
            guard readLine() == part.deviceIdentifier else {
                print("Cancelado.")
                throw ExitCode(1)
            }
        }

        let summary = try Formatter.format(partition: part, as: target, label: label)
        print(summary)
    }
}

// MARK: - unhide

struct Unhide: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Quita la marca 'oculta' de una partición FAT en la tabla MBR.",
        discussion: """
        macOS se niega a montar particiones FAT con tipo MBR oculto (0x1C, 0x16, \
        0x1B, 0x1E), algo habitual en tarjetas de consolas retro: ArkOS marca \
        EASYROMS como 0x1C para que Windows no ofrezca formatearla. Este comando \
        cambia el tipo a su equivalente visible (0x1C → 0x0C…), un único byte que \
        Linux y la consola ignoran. Guarda copia del MBR antes de tocar nada.
        """)

    /// tipo oculto → equivalente visible
    private static let hiddenTypes: [UInt8: UInt8] = [
        0x11: 0x01, 0x14: 0x04, 0x16: 0x06, 0x17: 0x07,
        0x1B: 0x0B, 0x1C: 0x0C, 0x1E: 0x0E,
    ]

    @Argument(help: "Identificador de la partición, p. ej. disk6s3")
    var partition: String

    @Flag(name: .long, help: "No pedir confirmación interactiva.")
    var force = false

    func run() throws {
        try requireRoot()
        let part = try resolvePartition(partition)
        let wholeDisk = part.parentWholeDisk

        let parentInfo = try DiskLister.info(for: wholeDisk)
        guard (parentInfo["Content"] as? String) == "FDisk_partition_scheme" else {
            throw ValidationError("\(wholeDisk) no usa tabla de particiones MBR (FDisk); nada que hacer.")
        }
        guard let sliceStr = part.deviceIdentifier.split(separator: "s").last,
              let slice = Int(sliceStr), (1...4).contains(slice) else {
            throw ValidationError("Solo particiones primarias MBR (s1…s4).")
        }

        let mbrPath = "/dev/r\(wholeDisk)"
        guard let readHandle = FileHandle(forReadingAtPath: mbrPath) else {
            throw ValidationError("No se puede leer \(mbrPath).")
        }
        var mbr = try readHandle.read(upToCount: 512) ?? Data()
        try readHandle.close()
        guard mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw ValidationError("MBR ilegible o sin firma 0x55AA.")
        }

        let typeOffset = 446 + 16 * (slice - 1) + 4
        let currentType = mbr[typeOffset]
        guard let visibleType = Self.hiddenTypes[currentType] else {
            throw ValidationError(String(format: "La partición tiene tipo 0x%02X, que no es un tipo FAT oculto.", currentType))
        }

        let backupPath = "/tmp/omnimount-mbr-\(wholeDisk).bin"
        try mbr.write(to: URL(fileURLWithPath: backupPath))
        print(String(format: "Tipo actual de %@: 0x%02X (oculta) → nuevo tipo: 0x%02X", part.deviceIdentifier, currentType, visibleType))
        print("Copia del MBR guardada en \(backupPath)")

        if !force {
            print("¿Continuar? Se modificará 1 byte de la tabla de particiones de \(wholeDisk). [s/N]: ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "s" || answer == "si" || answer == "sí" else {
                print("Cancelado.")
                throw ExitCode(1)
            }
        }

        // Las escrituras en bruto exigen el disco sin volúmenes montados.
        _ = try ShellRunner.run("/usr/sbin/diskutil", ["unmountDisk", wholeDisk])

        mbr[typeOffset] = visibleType
        guard let writeHandle = FileHandle(forWritingAtPath: mbrPath) else {
            throw ValidationError("No se puede escribir en \(mbrPath).")
        }
        try writeHandle.write(contentsOf: mbr)
        try writeHandle.synchronize()
        try writeHandle.close()
        print("Tabla de particiones actualizada ✓")

        // Reenganchar el disco para que macOS relea la tabla y automonte.
        _ = try ShellRunner.run("/usr/sbin/diskutil", ["mountDisk", wholeDisk])
        print("Listo. Si el volumen no aparece en unos segundos: diskutil mount \(part.deviceIdentifier)")
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Comprueba el estado de las dependencias (macFUSE, fuse2fs, ntfs-3g).")

    func run() throws {
        let d = ToolLocator.diagnose()
        func line(_ name: String, _ status: String?, hint: String) {
            if let status {
                print("✓ \(name): \(status)")
            } else {
                print("✗ \(name): no encontrado — \(hint)")
            }
        }
        if d.fuseT {
            print("✓ Capa FUSE: FUSE-T (sin kext)")
        } else if d.macFUSE {
            print("✓ Capa FUSE: macFUSE (kext)")
        } else {
            print("✗ Capa FUSE: ninguna — recomendado: brew install --cask macos-fuse-t/cask/fuse-t")
        }
        line("fuse2fs (ext2/3/4)", d.fuse2fs, hint: "compílalo con scripts/build-fuse2fs.sh (ver README)")
        line("ntfs-3g (NTFS)", d.ntfs3g, hint: "brew install gromgit/fuse/ntfs-3g-mac")
        line("e2fsck (verificación ext)", d.e2fsck, hint: "brew install e2fsprogs")
        line("ntfsfix (verificación NTFS)", d.ntfsfix, hint: "brew install gromgit/fuse/ntfs-3g-mac")

        print("")
        if d.canMountExt && d.canMountNTFS {
            print("Todo listo: Omnimount puede montar ext2/3/4 y NTFS.")
        } else {
            if !d.canMountExt { print("Aún no se puede montar ext2/3/4.") }
            if !d.canMountNTFS { print("Aún no se puede montar NTFS.") }
        }
    }
}
