import ArgumentParser
import Foundation
import OmnimountKit

@main
struct Omnimount: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omnimount",
        abstract: L10n.t("cli.root.abstract"),
        version: "0.4.9",
        subcommands: [
            List.self, Detect.self, Mount.self, Unmount.self,
            Test.self, Clone.self, Restore.self, Doctor.self,
            Unhide.self, Format.self,
        ],
        defaultSubcommand: List.self
    )
}

// MARK: - Utilidades compartidas

/// Fallo en tiempo de ejecución (no de argumentos): ArgumentParser imprime
/// solo "Error: <mensaje>" y sale con código 1. `ValidationError` queda para
/// argumentos inválidos, que además muestran el uso y salen con 64.
struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func resolvePartition(_ identifier: String) throws -> DiskPartition {
    let id = identifier.replacingOccurrences(of: "/dev/", with: "")
    let disks = try DiskLister.externalDisks()
    guard let partition = disks.flatMap(\.partitions).first(where: { $0.deviceIdentifier == id }) else {
        throw CLIError(L10n.t("cli.common.partitionMissing", id))
    }
    return partition
}

func requireRoot() throws {
    guard Mounter.isRoot else {
        throw CLIError(L10n.t("cli.common.needsRoot"))
    }
}

/// Acepta sí en español e inglés: el aviso muestra [s/N] o [y/N] según el idioma.
func isAffirmative(_ line: String?) -> Bool {
    switch line?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "y", "yes", "s", "si", "sí":
        return true
    default:
        return false
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
        abstract: L10n.t("cli.list.abstract"))

    func run() throws {
        let disks = try DiskLister.externalDisks()
        if disks.isEmpty {
            print(L10n.t("disk.list.empty"))
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
                    fsColumn = L10n.t("cli.list.sudo", partition.contentHint)
                }
                let state = partition.mountPoint.map { L10n.t("cli.list.mounted", $0) } ?? L10n.t("cli.list.unmounted")
                let label = labelColumn.isEmpty ? "" : " «\(labelColumn)»"
                print("  \(partition.deviceIdentifier)  \(partition.humanSize)  \(fsColumn)\(label)  \(state)")
            }

            if let match = RetroCards.identify(partitions: disk.partitions, extLabels: extLabels) {
                print("  🎮 \(L10n.t("cli.list.card", match.firmware, match.advice))")
            }
        }
    }
}

// MARK: - detect

struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.detect.abstract"))

    @Argument(help: ArgumentHelp(L10n.t("cli.common.partition")))
    var partition: String

    @Flag(name: .long, help: ArgumentHelp(L10n.t("cli.detect.verbose")))
    var verbose = false

    func run() throws {
        let part = try resolvePartition(partition)
        let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
        print("\(part.deviceIdentifier): \(detection.filesystem.displayName)")
        if let label = detection.label { print(L10n.t("cli.detect.label", label)) }
        if verbose { try dumpBootSector(devicePath: part.devicePath) }
        if detection.filesystem.isMountableByOmnimount {
            print(L10n.t("cli.detect.mountable"))
        } else if detection.filesystem.isNativelySupported {
            print(L10n.t("cli.detect.native"))
        } else {
            print(L10n.t("cli.detect.unsupported"))
        }
    }

    /// Vuelca los campos BPB del boot sector (FAT/exFAT/NTFS) para diagnóstico.
    private func dumpBootSector(devicePath: String) throws {
        guard let handle = FileHandle(forReadingAtPath: devicePath) else {
            throw CLIError(L10n.t("cli.detect.permissions", devicePath))
        }
        defer { try? handle.close() }
        let bs = try handle.read(upToCount: 512) ?? Data()
        guard bs.count >= 512 else {
            throw CLIError(L10n.t("cli.detect.shortSector", String(bs.count)))
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
        let signature = (u8(510) == 0x55 && u8(511) == 0xAA) ? L10n.t("cli.detect.yes") : L10n.t("cli.detect.corrupt")
        print("\(L10n.t("cli.detect.signature")) \(signature)")
    }
}

// MARK: - mount

struct Mount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.mount.abstract"))

    @Argument(help: ArgumentHelp(L10n.t("cli.common.partition")))
    var partition: String

    @Option(name: .long, help: ArgumentHelp(L10n.t("cli.mount.point")))
    var point: String?

    @Flag(name: [.customLong("read-only"), .customShort("r")], help: ArgumentHelp(L10n.t("cli.mount.readOnly")))
    var readOnly = false

    @Flag(name: .customLong("fix-quota"),
          help: ArgumentHelp(L10n.t("cli.mount.fixQuota")))
    var fixQuota = false

    @Flag(name: .customLong("make-writable"),
          help: ArgumentHelp(L10n.t("cli.mount.makeWritable")))
    var makeWritable = false

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
        var detection2 = detection
        if fixQuota, detection.extQuotaEnabled {
            print(L10n.t("cli.mount.disabling", part.devicePath))
            try Mounter.disableExtQuota(devicePath: part.devicePath)
            detection2 = try FilesystemDetector.detect(devicePath: part.devicePath)
        }
        let result: MountResult
        if makeWritable {
            result = try Mounter.makeNtfsWritable(partition: part, detection: detection2)
        } else {
            result = try Mounter.mount(partition: part, detection: detection2,
                                       mountPoint: point, readOnly: readOnly)
        }
        print(L10n.t("cli.mount.mounted", result.devicePath, result.filesystem.displayName, result.mountPoint))
        if result.readOnly {
            print(L10n.t("cli.mount.readOnlyWarning"))
        }
        print(result.mountPoint) // última línea = punto de montaje, para consumo por la app
    }
}

// MARK: - unmount

struct Unmount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.unmount.abstract"))

    @Argument(help: ArgumentHelp(L10n.t("cli.unmount.target")))
    var target: String

    func run() throws {
        let mountPoint: String
        if target.hasPrefix("/") {
            mountPoint = target
        } else {
            let part = try resolvePartition(target)
            // Triple fallback: diskutil → tabla de montajes → derivado por
            // etiqueta (los montajes FUSE-T aparecen como "fuse-t:/X", no
            // como /dev/diskN, y los dos primeros no los ven).
            guard let current = part.mountPoint
                ?? Mounter.currentMountPoint(devicePath: part.devicePath)
                ?? Mounter.derivedMountPoint(partition: part) else {
                throw CLIError(L10n.t("error.unmount.notMounted", part.deviceIdentifier))
            }
            mountPoint = current
        }
        try Mounter.unmount(mountPoint: mountPoint)
        print(L10n.t("cli.unmount.done", mountPoint))
    }
}

// MARK: - test

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.test.abstract"))

    @Argument(help: ArgumentHelp(L10n.t("cli.common.partition")))
    var partition: String

    func run() throws {
        try requireRoot()
        let part = try resolvePartition(partition)
        let detection = try FilesystemDetector.detect(devicePath: part.devicePath)

        print(L10n.t("cli.test.stepMount", part.deviceIdentifier, detection.filesystem.displayName))
        let result = try Mounter.mount(partition: part, detection: detection)
        print("    \(L10n.t("cli.test.mounted", result.mountPoint))")

        print(L10n.t("cli.test.stepWrite"))
        let testFile = (result.mountPoint as NSString)
            .appendingPathComponent(".omnimount-test-\(getpid()).txt")
        let payload = "omnimount write test \(Date())"
        do {
            try payload.write(toFile: testFile, atomically: false, encoding: .utf8)
            let readBack = try String(contentsOfFile: testFile, encoding: .utf8)
            guard readBack == payload else {
                throw CLIError(L10n.t("cli.test.mismatch"))
            }
            try FileManager.default.removeItem(atPath: testFile)
            print("    \(L10n.t("cli.test.ok"))")
        } catch {
            print("    \(L10n.t("cli.test.failed", error.localizedDescription))")
            try? Mounter.unmount(mountPoint: result.mountPoint)
            throw ExitCode(1)
        }

        print(L10n.t("cli.test.stepUnmount"))
        try Mounter.unmount(mountPoint: result.mountPoint)
        print("    \(L10n.t("cli.test.unmounted"))")

        print(L10n.t("cli.test.stepVerify"))
        _ = try Mounter.verify(devicePath: part.devicePath, filesystem: detection.filesystem)
        print("    \(L10n.t("cli.test.clean"))")
    }
}

// MARK: - clone

struct Clone: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.clone.abstract"))

    @Argument(help: ArgumentHelp(L10n.t("cli.clone.disk")))
    var disk: String

    @Argument(help: ArgumentHelp(L10n.t("cli.clone.output")))
    var image: String

    func run() throws {
        try requireRoot()
        let id = disk.replacingOccurrences(of: "/dev/", with: "")
        print(L10n.t("cli.clone.progress", id, image))
        try Cloner.clone(wholeDisk: id, to: image, progress: printProgressBar)
        print("\n" + L10n.t("cli.clone.done"))
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.restore.abstract"))

    @Argument(help: ArgumentHelp(L10n.t("cli.restore.input")))
    var image: String

    @Argument(help: ArgumentHelp(L10n.t("cli.restore.disk")))
    var disk: String

    @Flag(name: .long, help: ArgumentHelp(L10n.t("cli.common.force")))
    var force = false

    func run() throws {
        try requireRoot()
        let id = disk.replacingOccurrences(of: "/dev/", with: "")

        // Solo discos externos: evita apuntar por error al disco del sistema.
        let disks = try DiskLister.externalDisks()
        guard let target = disks.first(where: { $0.deviceIdentifier == id }) else {
            throw ValidationError(L10n.t("cli.restore.notExternal", id))
        }

        if !force {
            print(L10n.t("cli.restore.warning", id, target.humanSize, target.mediaName ?? L10n.t("cli.common.unnamed")))
            print(L10n.t("cli.restore.confirm", id), terminator: "")
            guard readLine() == id else {
                print(L10n.t("cli.common.cancelled"))
                throw ExitCode(1)
            }
        }

        print(L10n.t("cli.restore.progress", image, id))
        try Cloner.restore(imagePath: image, to: id, progress: printProgressBar)
        print("\n" + L10n.t("cli.restore.done"))
    }
}

// MARK: - format

struct Format: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.format.abstract"),
        discussion: L10n.t("cli.format.discussion"))

    @Argument(help: ArgumentHelp(L10n.t("cli.common.partition")))
    var partition: String

    @Argument(help: ArgumentHelp(L10n.t("cli.format.target")))
    var format: String

    @Option(name: .long, help: ArgumentHelp(L10n.t("cli.format.label")))
    var label: String

    @Flag(name: .long, help: ArgumentHelp(L10n.t("cli.common.force")))
    var force = false

    func run() throws {
        try requireRoot()
        guard let target = TargetFormat(rawValue: format.lowercased()) else {
            throw ValidationError(L10n.t("cli.format.unknown", format))
        }
        let part = try resolvePartition(partition)

        if !force {
            let name = part.volumeName.map { " «\($0)»" } ?? ""
            print(L10n.t("cli.format.warning", part.deviceIdentifier, name, part.humanSize))
            print(L10n.t("cli.format.confirm", part.deviceIdentifier), terminator: "")
            guard readLine() == part.deviceIdentifier else {
                print(L10n.t("cli.common.cancelled"))
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
        abstract: L10n.t("cli.unhide.abstract"),
        discussion: L10n.t("cli.unhide.discussion"))

    /// tipo oculto → equivalente visible
    private static let hiddenTypes: [UInt8: UInt8] = [
        0x11: 0x01, 0x14: 0x04, 0x16: 0x06, 0x17: 0x07,
        0x1B: 0x0B, 0x1C: 0x0C, 0x1E: 0x0E,
    ]

    @Argument(help: ArgumentHelp(L10n.t("cli.common.partition")))
    var partition: String

    @Flag(name: .long, help: ArgumentHelp(L10n.t("cli.common.force")))
    var force = false

    func run() throws {
        try requireRoot()
        let part = try resolvePartition(partition)
        let wholeDisk = part.parentWholeDisk

        let parentInfo = try DiskLister.info(for: wholeDisk)
        guard (parentInfo["Content"] as? String) == "FDisk_partition_scheme" else {
            throw ValidationError(L10n.t("cli.unhide.notMbr", wholeDisk))
        }
        guard let sliceStr = part.deviceIdentifier.split(separator: "s").last,
              let slice = Int(sliceStr), (1...4).contains(slice) else {
            throw ValidationError(L10n.t("cli.unhide.primaryOnly"))
        }

        let mbrPath = "/dev/r\(wholeDisk)"
        guard let readHandle = FileHandle(forReadingAtPath: mbrPath) else {
            throw CLIError(L10n.t("cli.unhide.read", mbrPath))
        }
        var mbr = try readHandle.read(upToCount: 512) ?? Data()
        try readHandle.close()
        guard mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw CLIError(L10n.t("cli.unhide.badMbr"))
        }

        let typeOffset = 446 + 16 * (slice - 1) + 4
        let currentType = mbr[typeOffset]
        guard let visibleType = Self.hiddenTypes[currentType] else {
            throw ValidationError(L10n.t("cli.unhide.badType", String(format: "0x%02X", UInt(currentType))))
        }

        let backupPath = "/tmp/omnimount-mbr-\(wholeDisk).bin"
        try mbr.write(to: URL(fileURLWithPath: backupPath))
        print(L10n.t(
            "cli.unhide.changing",
            part.deviceIdentifier,
            String(format: "0x%02X", UInt(currentType)),
            String(format: "0x%02X", UInt(visibleType))))
        print(L10n.t("cli.unhide.backup", backupPath))

        if !force {
            print(L10n.t("cli.unhide.confirm", wholeDisk), terminator: "")
            guard isAffirmative(readLine()) else {
                print(L10n.t("cli.common.cancelled"))
                throw ExitCode(1)
            }
        }

        // Las escrituras en bruto exigen el disco sin volúmenes montados.
        _ = try ShellRunner.run("/usr/sbin/diskutil", ["unmountDisk", wholeDisk])

        mbr[typeOffset] = visibleType
        guard let writeHandle = FileHandle(forWritingAtPath: mbrPath) else {
            throw CLIError(L10n.t("cli.unhide.write", mbrPath))
        }
        try writeHandle.write(contentsOf: mbr)
        try writeHandle.synchronize()
        try writeHandle.close()
        print(L10n.t("cli.unhide.updated"))

        // Reenganchar el disco para que macOS relea la tabla y automonte.
        _ = try ShellRunner.run("/usr/sbin/diskutil", ["mountDisk", wholeDisk])
        print(L10n.t("cli.unhide.done", part.deviceIdentifier))
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L10n.t("cli.doctor.abstract"))

    func run() throws {
        let d = ToolLocator.diagnose()
        func line(_ name: String, _ status: String?, hint: String) {
            if let status {
                print("✓ \(name): \(status)")
            } else {
                print("✗ \(name): \(L10n.t("cli.doctor.missing", hint))")
            }
        }
        if d.fuseT {
            print(L10n.t("cli.doctor.fuseT"))
        } else if d.macFUSE {
            print(L10n.t("cli.doctor.macFuse"))
        } else {
            print(L10n.t("cli.doctor.noFuse"))
        }
        line("fuse2fs (ext2/3/4)", d.fuse2fs, hint: L10n.t("cli.doctor.fuse2fsHint"))
        line("ntfs-3g (NTFS)", d.ntfs3g, hint: L10n.t("cli.doctor.ntfs3gHint"))
        line(L10n.t("cli.doctor.e2fsck"), d.e2fsck, hint: L10n.t("cli.doctor.e2fsckHint"))
        line(L10n.t("cli.doctor.ntfsfix"), d.ntfsfix, hint: L10n.t("cli.doctor.ntfs3gHint"))

        print("")
        if d.canMountExt && d.canMountNTFS {
            print(L10n.t("cli.doctor.ready"))
        } else {
            if !d.canMountExt { print(L10n.t("cli.doctor.noExt")) }
            if !d.canMountNTFS { print(L10n.t("cli.doctor.noNtfs")) }
        }
    }
}
