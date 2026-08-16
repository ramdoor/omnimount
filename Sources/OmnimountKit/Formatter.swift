import Foundation

/// Formatos que Omnimount puede crear.
public enum TargetFormat: String, CaseIterable, Sendable, Identifiable {
    case ext4, ext3, ext2
    case ntfs
    case fat32
    case exfat

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ext4: return "ext4 (Linux/consolas retro)"
        case .ext3: return "ext3"
        case .ext2: return "ext2"
        case .ntfs: return "NTFS (Windows)"
        case .fat32: return "FAT32 (compatible con todo, ficheros <4 GB)"
        case .exfat: return "exFAT (compatible, sin límite de 4 GB)"
        }
    }

    /// Tipo de partición MBR correspondiente.
    var mbrType: UInt8 {
        switch self {
        case .ext4, .ext3, .ext2: return 0x83
        case .ntfs, .exfat: return 0x07
        case .fat32: return 0x0C
        }
    }
}

public enum FormatError: Error, LocalizedError {
    case notRoot
    case toolMissing(String)
    case unmountFailed(String)
    case formatFailed(tool: String, output: String)
    case badLabel(String)

    public var errorDescription: String? {
        switch self {
        case .notRoot:
            return "Formatear requiere privilegios de root."
        case .toolMissing(let tool):
            return "No se encontró \(tool). Revisa `omnimount doctor`."
        case .unmountFailed(let message):
            return "No se pudo desmontar antes de formatear: \(message)"
        case .formatFailed(let tool, let output):
            return "\(tool) falló: \(output)"
        case .badLabel(let reason):
            return "Etiqueta no válida: \(reason)"
        }
    }
}

/// Formatea particiones envolviendo mkfs.ext*/mkntfs/newfs_*.
/// DESTRUCTIVO: el llamante es responsable de confirmar con el usuario.
public enum Formatter {

    /// Valida y normaliza la etiqueta para el formato elegido.
    public static func normalizeLabel(_ label: String, for format: TargetFormat) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FormatError.badLabel("vacía") }
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw FormatError.badLabel("no puede contener '/'")
        }
        switch format {
        case .ext2, .ext3, .ext4:
            guard trimmed.utf8.count <= 16 else { throw FormatError.badLabel("máximo 16 bytes en ext*") }
            return trimmed
        case .ntfs, .exfat:
            return trimmed
        case .fat32:
            // FAT: 11 caracteres, mayúsculas.
            let upper = trimmed.uppercased()
            guard upper.count <= 11 else { throw FormatError.badLabel("máximo 11 caracteres en FAT32") }
            return upper
        }
    }

    /// Formatea la partición. Devuelve un resumen legible.
    public static func format(partition: DiskPartition,
                              as target: TargetFormat,
                              label: String) throws -> String {
        guard getuid() == 0 else { throw FormatError.notRoot }
        let cleanLabel = try normalizeLabel(label, for: target)

        // Desmontar lo que haya (nativo o FUSE).
        if let fuseMount = Mounter.currentMountPoint(devicePath: partition.devicePath) {
            try? Mounter.unmount(mountPoint: fuseMount)
        } else if let derived = Mounter.derivedMountPoint(partition: partition) {
            try? Mounter.unmount(mountPoint: derived)
        }
        _ = try? ShellRunner.run("/usr/sbin/diskutil", ["unmount", partition.deviceIdentifier])
        if let stillMounted = try? DiskLister.info(for: partition.deviceIdentifier),
           stillMounted["MountPoint"] is String {
            throw FormatError.unmountFailed("\(partition.deviceIdentifier) sigue montada")
        }

        let toolName: ExternalTool
        var args: [String]
        switch target {
        case .ext4, .ext3, .ext2:
            toolName = target == .ext4 ? .mkfsExt4 : (target == .ext3 ? .mkfsExt3 : .mkfsExt2)
            args = ["-F", "-L", cleanLabel, partition.devicePath]
        case .ntfs:
            // -f: formato rápido; -F: no exigir block device "estándar".
            toolName = .mkntfs
            args = ["-f", "-F", "-L", cleanLabel, partition.devicePath]
        case .fat32:
            toolName = .newfsMsdos
            args = ["-F", "32", "-v", cleanLabel, partition.rawDevicePath]
        case .exfat:
            toolName = .newfsExfat
            args = ["-v", cleanLabel, partition.rawDevicePath]
        }
        guard let toolPath = ToolLocator.find(toolName) else {
            throw FormatError.toolMissing(toolName.rawValue)
        }

        let result = try ShellRunner.run(toolPath, args)
        guard result.succeeded else {
            throw FormatError.formatFailed(tool: toolName.rawValue,
                                           output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        // Alinear el tipo MBR con el nuevo FS (solo discos FDisk, slices 1-4).
        var mbrNote = ""
        if updateMBRTypeIfPossible(partition: partition, type: target.mbrType) {
            mbrNote = String(format: ", tipo MBR 0x%02X", target.mbrType)
        }

        return "\(partition.deviceIdentifier) formateada como \(target.rawValue) «\(cleanLabel)»\(mbrNote)"
    }

    /// Pone el byte de tipo en la entrada MBR de la partición. Devuelve true
    /// si lo cambió; false si el disco no es MBR o el slice no es primario.
    @discardableResult
    private static func updateMBRTypeIfPossible(partition: DiskPartition, type: UInt8) -> Bool {
        let wholeDisk = partition.parentWholeDisk
        guard let info = try? DiskLister.info(for: wholeDisk),
              (info["Content"] as? String) == "FDisk_partition_scheme",
              let sliceStr = partition.deviceIdentifier.split(separator: "s").last,
              let slice = Int(sliceStr), (1...4).contains(slice) else { return false }

        let mbrPath = "/dev/r\(wholeDisk)"
        guard let readHandle = FileHandle(forReadingAtPath: mbrPath),
              var mbr = try? readHandle.read(upToCount: 512),
              mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA else { return false }
        try? readHandle.close()

        let offset = 446 + 16 * (slice - 1) + 4
        guard mbr[offset] != type else { return true }
        mbr[offset] = type

        guard let writeHandle = FileHandle(forWritingAtPath: mbrPath) else { return false }
        defer { try? writeHandle.close() }
        do {
            try writeHandle.write(contentsOf: mbr)
            try writeHandle.synchronize()
            return true
        } catch {
            return false
        }
    }
}
