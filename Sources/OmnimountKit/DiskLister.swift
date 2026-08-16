import Foundation

/// Una partición (o disco entero) tal y como la describe diskutil.
public struct DiskPartition: Identifiable, Sendable {
    public var id: String { deviceIdentifier }

    public let deviceIdentifier: String   // p. ej. "disk4s1"
    public let parentWholeDisk: String    // p. ej. "disk4"
    public let content: String            // tipo de partición según la GPT/MBR
    public let volumeName: String?        // etiqueta que conoce macOS
    public let size: Int64                // bytes
    public let mountPoint: String?        // nil si no está montada
    public let isWholeDisk: Bool

    public var devicePath: String { "/dev/\(deviceIdentifier)" }
    public var rawDevicePath: String { "/dev/r\(deviceIdentifier)" }
    public var isMounted: Bool { mountPoint != nil }

    /// Heurística sin privilegios basada en el tipo de partición.
    /// La detección definitiva (magic bytes) requiere leer el dispositivo.
    public var contentHint: String {
        switch content {
        case "Linux Filesystem", "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "Linux":
            return L10n.t("Linux (posible ext4)", "Linux (likely ext4)")
        case "Microsoft Basic Data", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Windows_NTFS":
            return "Windows (NTFS/exFAT/FAT)"
        case "0x1C", "0x16", "0x1B", "0x1E", "0x11", "0x14", "0x17":
            return L10n.t("FAT oculta (\(content); móntala tras `omnimount unhide`)", "Hidden FAT (\(content); mount it after `omnimount unhide`)")
        default:
            return content
        }
    }

    public var humanSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public init(deviceIdentifier: String, parentWholeDisk: String, content: String,
                volumeName: String?, size: Int64, mountPoint: String?, isWholeDisk: Bool) {
        self.deviceIdentifier = deviceIdentifier
        self.parentWholeDisk = parentWholeDisk
        self.content = content
        self.volumeName = volumeName
        self.size = size
        self.mountPoint = mountPoint
        self.isWholeDisk = isWholeDisk
    }
}

public struct ExternalDisk: Identifiable, Sendable {
    public var id: String { deviceIdentifier }

    public let deviceIdentifier: String   // "disk4"
    public let size: Int64
    public let mediaName: String?
    public let partitions: [DiskPartition]

    public var humanSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

public enum DiskListerError: Error, LocalizedError {
    case diskutilFailed(String)
    case badPlist

    public var errorDescription: String? {
        switch self {
        case .diskutilFailed(let stderr): return L10n.t("diskutil falló: \(stderr)", "diskutil failed: \(stderr)")
        case .badPlist: return L10n.t("No se pudo interpretar la salida de diskutil.", "Could not parse diskutil output.")
        }
    }
}

/// Enumera discos externos y sus particiones usando `diskutil -plist`.
public enum DiskLister {

    public static func externalDisks() throws -> [ExternalDisk] {
        let result = try ShellRunner.run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard result.succeeded else { throw DiskListerError.diskutilFailed(result.stderr) }
        guard let data = result.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { throw DiskListerError.badPlist }

        return all.compactMap { diskDict -> ExternalDisk? in
            guard let wholeID = diskDict["DeviceIdentifier"] as? String else { return nil }
            let wholeSize = (diskDict["Size"] as? NSNumber)?.int64Value ?? 0

            let partitionDicts = diskDict["Partitions"] as? [[String: Any]] ?? []
            var partitions: [DiskPartition] = partitionDicts.compactMap { part in
                guard let partID = part["DeviceIdentifier"] as? String else { return nil }
                return DiskPartition(
                    deviceIdentifier: partID,
                    parentWholeDisk: wholeID,
                    content: part["Content"] as? String ?? "",
                    volumeName: part["VolumeName"] as? String,
                    size: (part["Size"] as? NSNumber)?.int64Value ?? 0,
                    mountPoint: part["MountPoint"] as? String,
                    isWholeDisk: false
                )
            }

            // Discos sin tabla de particiones (el FS ocupa el disco entero).
            if partitions.isEmpty {
                partitions = [DiskPartition(
                    deviceIdentifier: wholeID,
                    parentWholeDisk: wholeID,
                    content: diskDict["Content"] as? String ?? "",
                    volumeName: diskDict["VolumeName"] as? String,
                    size: wholeSize,
                    mountPoint: diskDict["MountPoint"] as? String,
                    isWholeDisk: true
                )]
            }

            let mediaName = (try? info(for: wholeID))?["MediaName"] as? String
            return ExternalDisk(
                deviceIdentifier: wholeID,
                size: wholeSize,
                mediaName: mediaName,
                partitions: partitions
            )
        }
    }

    /// `diskutil info -plist <id>` como diccionario.
    public static func info(for deviceIdentifier: String) throws -> [String: Any] {
        let result = try ShellRunner.run("/usr/sbin/diskutil", ["info", "-plist", deviceIdentifier])
        guard result.succeeded else { throw DiskListerError.diskutilFailed(result.stderr) }
        guard let data = result.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw DiskListerError.badPlist }
        return plist
    }

    /// Particiones externas que macOS no ha montado (candidatas para Omnimount).
    public static func unmountedExternalPartitions() throws -> [DiskPartition] {
        try externalDisks()
            .flatMap(\.partitions)
            .filter { !$0.isMounted && $0.content != "EFI" && $0.content != "Apple_KernelCoreDump" }
    }
}
