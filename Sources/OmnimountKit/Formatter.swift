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
        case .ext4: return L10n.t("disk.fs.ext4")
        case .ext3: return "ext3"
        case .ext2: return "ext2"
        case .ntfs: return "NTFS (Windows)"
        case .fat32: return L10n.t("disk.fs.fat32")
        case .exfat: return L10n.t("disk.fs.exfat")
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
            return L10n.t("error.format.notRoot")
        case .toolMissing(let tool):
            return L10n.t("error.format.toolMissing", tool)
        case .unmountFailed(let message):
            return L10n.t("error.format.unmount", message)
        case .formatFailed(let tool, let output):
            return L10n.t("error.format.failed", tool, output)
        case .badLabel(let reason):
            return L10n.t("error.format.label", reason)
        }
    }
}

/// Formatea particiones envolviendo mkfs.ext*/mkntfs/newfs_*.
/// DESTRUCTIVO: el llamante es responsable de confirmar con el usuario.
public enum Formatter {

    /// Valida y normaliza la etiqueta para el formato elegido.
    public static func normalizeLabel(_ label: String, for format: TargetFormat) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FormatError.badLabel(L10n.t("error.format.empty")) }
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw FormatError.badLabel(L10n.t("error.format.slash"))
        }
        switch format {
        case .ext2, .ext3, .ext4:
            guard trimmed.utf8.count <= 16 else { throw FormatError.badLabel(L10n.t("error.format.extLength")) }
            return trimmed
        case .ntfs, .exfat:
            return trimmed
        case .fat32:
            // FAT: 11 caracteres, mayúsculas.
            let upper = trimmed.uppercased()
            guard upper.count <= 11 else { throw FormatError.badLabel(L10n.t("error.format.fatLength")) }
            return upper
        }
    }

    /// Formatea la partición. Devuelve un resumen legible.
    public static func format(partition: DiskPartition,
                              as target: TargetFormat,
                              label: String) throws -> String {
        guard getuid() == 0 else { throw FormatError.notRoot }
        let cleanLabel = try normalizeLabel(label, for: target)

        try prepareTarget(partition)

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
            mbrNote = L10n.t("error.format.mbrType", String(format: "0x%02X", UInt(target.mbrType)))
        }

        return L10n.t("error.format.summary", partition.deviceIdentifier, target.rawValue, cleanLabel, mbrNote)
    }

    /// Desmonta el destino con las mismas reglas que el clonado: los errores
    /// de desmontaje o de enumeración detienen el formateo, se vuelve a
    /// comprobar el estado tras desmontar y un montaje FUSE-T localizable solo
    /// por etiqueta no se desmonta (el usuario lo expulsa desde la app).
    /// `diskutil info` devuelve MountPoint vacío para un dispositivo
    /// desmontado, así que el estado se toma de `diskutil list` y mount(8).
    static func prepareTarget(_ partition: DiskPartition,
                              operations: Cloner.UnmountOperations = .system) throws {
        do {
            try Cloner.unmountTarget(partition.deviceIdentifier, operations: operations)
        } catch CloneError.unmountFailed(let message) {
            throw FormatError.unmountFailed(message)
        }
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
