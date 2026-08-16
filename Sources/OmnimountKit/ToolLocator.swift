import Foundation

/// Herramientas externas que Omnimount envuelve. No se empaquetan:
/// se localizan en las rutas habituales de Homebrew o del script vendor.
public enum ExternalTool: String, CaseIterable, Sendable {
    case fuse2fs
    case ntfs3g = "ntfs-3g"
    case e2fsck
    case ntfsfix
    case omnimountCLI = "omnimount"
    case mkfsExt2 = "mkfs.ext2"
    case mkfsExt3 = "mkfs.ext3"
    case mkfsExt4 = "mkfs.ext4"
    case mkntfs
    case newfsMsdos = "newfs_msdos"
    case newfsExfat = "newfs_exfat"

    var candidateDirectories: [String] {
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/opt/homebrew/opt/e2fsprogs/sbin",
            "/opt/homebrew/opt/e2fsprogs/bin",
            "/opt/homebrew/opt/ntfs-3g-mac/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/sbin",
            "/usr/sbin",
        ]
    }
}

public enum ToolLocator {

    /// Directorio vendor/bin relativo al ejecutable actual (para fuse2fs compilado
    /// con scripts/build-fuse2fs.sh) y al directorio de trabajo.
    private static func vendorDirectories() -> [String] {
        var dirs: [String] = []
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        dirs.append(execDir.appendingPathComponent("vendor/bin").path)
        dirs.append(execDir.path) // el CLI puede vivir junto a la app
        dirs.append(FileManager.default.currentDirectoryPath + "/vendor/bin")
        return dirs
    }

    /// Devuelve la ruta absoluta de la herramienta, o nil si no está instalada.
    /// `OMNIMOUNT_TOOL_DIR` (si está definida) tiene prioridad.
    public static func find(_ tool: ExternalTool) -> String? {
        var directories: [String] = []
        if let override = ProcessInfo.processInfo.environment["OMNIMOUNT_TOOL_DIR"] {
            directories.append(override)
        }
        directories += vendorDirectories()
        directories += tool.candidateDirectories

        let fm = FileManager.default
        // El FS de macOS no distingue mayúsculas: buscando el CLI "omnimount",
        // la app "Omnimount" se encontraría a sí misma y se relanzaría en bucle.
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path.lowercased()
        // El CLI embebido en el bundle se llama "omnimount-cli" porque no puede
        // convivir con el ejecutable "Omnimount" en un FS case-insensitive.
        var names = [tool.rawValue]
        if tool == .omnimountCLI { names.insert("omnimount-cli", at: 0) }

        for dir in directories {
            for name in names {
                let path = (dir as NSString).appendingPathComponent(name)
                guard fm.isExecutableFile(atPath: path) else { continue }
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased()
                if resolved == selfPath { continue }
                return path
            }
        }
        return nil
    }

    /// true si macFUSE está instalado (backend con kext).
    public static var isMacFUSEInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
    }

    /// true si FUSE-T está instalado (backend sin kext).
    public static var isFuseTInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib")
    }

    public struct Diagnosis: Sendable {
        public let macFUSE: Bool
        public let fuseT: Bool
        public let fuse2fs: String?
        public let ntfs3g: String?
        public let e2fsck: String?
        public let ntfsfix: String?

        public var hasFuseLayer: Bool { macFUSE || fuseT }
        public var canMountExt: Bool { hasFuseLayer && fuse2fs != nil }
        public var canMountNTFS: Bool { hasFuseLayer && ntfs3g != nil }
    }

    public static func diagnose() -> Diagnosis {
        Diagnosis(
            macFUSE: isMacFUSEInstalled,
            fuseT: isFuseTInstalled,
            fuse2fs: find(.fuse2fs),
            ntfs3g: find(.ntfs3g),
            e2fsck: find(.e2fsck),
            ntfsfix: find(.ntfsfix)
        )
    }
}
