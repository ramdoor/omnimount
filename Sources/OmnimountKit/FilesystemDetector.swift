import Foundation

/// Sistemas de ficheros que Omnimount sabe identificar leyendo magic bytes.
public enum DetectedFilesystem: String, Sendable {
    case ext2, ext3, ext4
    case ntfs
    case exfat
    case fat
    case btrfs
    case linuxSwap = "linux-swap"
    case unknown

    /// true si Omnimount puede montarlo con un backend FUSE.
    public var isMountableByOmnimount: Bool {
        switch self {
        case .ext2, .ext3, .ext4, .ntfs: return true
        default: return false
        }
    }

    /// true si macOS ya lo monta por sí solo.
    public var isNativelySupported: Bool {
        switch self {
        case .exfat, .fat, .ntfs: return true // NTFS solo lectura en macOS
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .ext2: return "ext2"
        case .ext3: return "ext3"
        case .ext4: return "ext4"
        case .ntfs: return "NTFS"
        case .exfat: return "exFAT"
        case .fat: return "FAT"
        case .btrfs: return "Btrfs"
        case .linuxSwap: return "Linux swap"
        case .unknown: return "desconocido"
        }
    }
}

public struct DetectionResult: Sendable {
    public let filesystem: DetectedFilesystem
    /// Etiqueta de volumen leída del superbloque (solo ext*).
    public let label: String?

    public init(filesystem: DetectedFilesystem, label: String? = nil) {
        self.filesystem = filesystem
        self.label = label
    }
}

public enum DetectionError: Error, LocalizedError {
    case cannotOpenDevice(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenDevice(let path):
            return "No se puede leer \(path). Leer el nodo de dispositivo requiere privilegios: ejecuta con sudo."
        }
    }
}

/// Detecta el sistema de ficheros de una partición leyendo sus magic bytes,
/// sin depender de que macOS lo reconozca.
///
/// Referencias de offsets:
/// - ext2/3/4: superbloque en offset 1024; magic 0xEF53 (LE) en superbloque+56.
///   Las feature flags (+92 compat, +96 incompat, +100 ro_compat) distinguen
///   ext2 (sin journal), ext3 (journal) y ext4 (extents/64bit/etc.).
/// - NTFS: OEM ID "NTFS    " en offset 3 del boot sector.
/// - exFAT: OEM ID "EXFAT   " en offset 3.
/// - FAT12/16/32: cadena "FAT" en offset 54 (FAT12/16) o 82 (FAT32).
/// - Btrfs: magic "_BHRfS_M" en offset 0x10040.
/// - Linux swap: "SWAPSPACE2"/"SWAP-SPACE" al final de la primera página (4 KiB).
public enum FilesystemDetector {

    public static func detect(devicePath: String) throws -> DetectionResult {
        guard let handle = FileHandle(forReadingAtPath: devicePath) else {
            throw DetectionError.cannotOpenDevice(devicePath)
        }
        defer { try? handle.close() }

        func read(offset: UInt64, count: Int) -> Data {
            do {
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: count) ?? Data()
            } catch {
                return Data()
            }
        }

        let bootSector = read(offset: 0, count: 512)
        let superblock = read(offset: 1024, count: 1024)

        if let result = detectExt(superblock: superblock) { return result }

        if bootSector.count >= 11 {
            let oemID = bootSector.subdata(in: 3..<11)
            if oemID == Data("NTFS    ".utf8) {
                return DetectionResult(filesystem: .ntfs, label: nil)
            }
            if oemID == Data("EXFAT   ".utf8) {
                return DetectionResult(filesystem: .exfat, label: nil)
            }
        }
        if bootSector.count >= 90 {
            if bootSector.subdata(in: 82..<87) == Data("FAT32".utf8)
                || bootSector.subdata(in: 54..<57) == Data("FAT".utf8) {
                return DetectionResult(filesystem: .fat, label: nil)
            }
        }

        // Btrfs: bloque de 4 KiB en 0x10000; magic en +0x40.
        let btrfsBlock = read(offset: 0x10000, count: 4096)
        if btrfsBlock.count >= 0x48, btrfsBlock.subdata(in: 0x40..<0x48) == Data("_BHRfS_M".utf8) {
            return DetectionResult(filesystem: .btrfs, label: nil)
        }

        // Linux swap: firma en los últimos 10 bytes de la primera página.
        let firstPage = read(offset: 0, count: 4096)
        if firstPage.count == 4096 {
            let tail = firstPage.subdata(in: 4086..<4096)
            if tail == Data("SWAPSPACE2".utf8) || tail == Data("SWAP-SPACE".utf8) {
                return DetectionResult(filesystem: .linuxSwap, label: nil)
            }
        }

        return DetectionResult(filesystem: .unknown, label: nil)
    }

    private static func detectExt(superblock: Data) -> DetectionResult? {
        guard superblock.count >= 136 else { return nil }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(superblock[superblock.startIndex + offset])
                | (UInt16(superblock[superblock.startIndex + offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for i in (0..<4).reversed() {
                value = (value << 8) | UInt32(superblock[superblock.startIndex + offset + i])
            }
            return value
        }

        guard u16(56) == 0xEF53 else { return nil }

        let compat = u32(92)
        let incompat = u32(96)
        let roCompat = u32(100)

        let hasJournal = compat & 0x0004 != 0
        // extents (0x40), 64bit (0x80), flex_bg (0x200), inline_data, etc.
        let ext4Incompat: UInt32 = 0x0040 | 0x0080 | 0x0200 | 0x1000 | 0x8000
        // huge_file (0x8), gdt_csum (0x10), dir_nlink (0x20), extra_isize (0x40), metadata_csum (0x400)
        let ext4RoCompat: UInt32 = 0x0008 | 0x0010 | 0x0020 | 0x0040 | 0x0400

        let filesystem: DetectedFilesystem
        if incompat & ext4Incompat != 0 || roCompat & ext4RoCompat != 0 {
            filesystem = .ext4
        } else if hasJournal {
            filesystem = .ext3
        } else {
            filesystem = .ext2
        }

        // s_volume_name: 16 bytes en superbloque+120.
        var label: String?
        if superblock.count >= 136 {
            let raw = superblock.subdata(in: 120..<136)
            let trimmed = raw.prefix(while: { $0 != 0 })
            if !trimmed.isEmpty {
                label = String(data: trimmed, encoding: .utf8)
            }
        }

        return DetectionResult(filesystem: filesystem, label: label)
    }
}
