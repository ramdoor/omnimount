import Foundation
import os
import Security

/// Herramientas externas que Omnimount envuelve. No se empaquetan:
/// se localizan en las rutas habituales de Homebrew o del script vendor.
public enum ExternalTool: String, CaseIterable, Sendable {
    case fuse2fs
    case ntfs3g = "ntfs-3g"
    case e2fsck
    case tune2fs
    case ntfsfix
    case omnimountCLI = "omnimount"
    case mkfsExt2 = "mkfs.ext2"
    case mkfsExt3 = "mkfs.ext3"
    case mkfsExt4 = "mkfs.ext4"
    case mkntfs
    case newfsMsdos = "newfs_msdos"
    case newfsExfat = "newfs_exfat"

    /// Herramientas de macOS: no van en el bundle y se buscan primero en
    /// los directorios del sistema.
    var isSystemTool: Bool {
        self == .newfsMsdos || self == .newfsExfat
    }

    var candidateDirectories: [String] {
        [
            // Último recurso absoluto: el bundle instalado. Cubre CLIs viejos
            // de `make install` en el PATH, apps trasladadas por Gatekeeper y
            // cualquier proceso cuyo argv[0] no apunte junto a las herramientas
            // embebidas (reporte real de un cliente: "fuse2fs not found" con
            // fuse2fs presente en el bundle).
            "/Applications/Omnimount.app/Contents/MacOS",
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

    /// Directorios de las herramientas del sistema (newfs_msdos, newfs_exfat).
    static let systemToolDirectories = ["/sbin", "/usr/sbin"]

    /// Búsqueda restringida que fija el helper al arrancar. Con ella solo se
    /// usan las herramientas del sistema en /sbin y /usr/sbin y las
    /// herramientas empaquetadas junto al ejecutable del helper, firmadas con
    /// su mismo Team ID. El CLI no la fija y conserva la búsqueda normal.
    public struct TrustedToolPolicy: Sendable, Equatable {
        public let bundledToolDirectory: String
        /// Team ID del helper; sin él no se usa ninguna herramienta empaquetada.
        public let teamIdentifier: String?

        public init(bundledToolDirectory: String, teamIdentifier: String?) {
            self.bundledToolDirectory = bundledToolDirectory
            self.teamIdentifier = teamIdentifier
        }

        /// Directorio del ejecutable de este proceso según el kernel. No
        /// depende de argv[0] ni de Bundle.main (que, dentro de Contents/MacOS,
        /// describe la app contenedora).
        public static func currentExecutableDirectory() -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let path = String(cString: buffer)
            guard path.hasPrefix("/") else { return nil }
            return (path as NSString).deletingLastPathComponent
        }
    }

    private final class PolicyStore: @unchecked Sendable {
        private let lock = NSLock()
        private var policy: TrustedToolPolicy?

        func set(_ value: TrustedToolPolicy) {
            lock.lock()
            defer { lock.unlock() }
            policy = value
        }

        func get() -> TrustedToolPolicy? {
            lock.lock()
            defer { lock.unlock() }
            return policy
        }
    }

    private static let store = PolicyStore()
    private static let log = Logger(subsystem: "org.omnimount.helper", category: "tools")

    /// Activa la búsqueda restringida para todo el proceso. La llama el
    /// helper una vez, antes de aceptar conexiones.
    public static func useTrustedLocations(_ policy: TrustedToolPolicy) {
        store.set(policy)
    }

    /// Directorio vendor/bin relativo al ejecutable actual (para fuse2fs compilado
    /// con scripts/build-fuse2fs.sh) y al directorio de trabajo.
    private static func vendorDirectories(executablePath: String, currentDirectory: String) -> [String] {
        var dirs: [String] = []
        let execDir = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        dirs.append(execDir.appendingPathComponent("vendor/bin").path)
        dirs.append(execDir.path) // el CLI puede vivir junto a la app
        dirs.append(currentDirectory + "/vendor/bin")
        return dirs
    }

    /// Devuelve la ruta absoluta de la herramienta, o nil si no está instalada.
    /// `OMNIMOUNT_TOOL_DIR` (si está definida) tiene prioridad, salvo para las
    /// herramientas del sistema y salvo con la búsqueda restringida del helper.
    public static func find(_ tool: ExternalTool) -> String? {
        if let policy = store.get() {
            return find(tool, trusted: policy, verify: satisfiesTeamRequirement)
        }
        return find(tool,
                    environment: ProcessInfo.processInfo.environment,
                    currentDirectory: FileManager.default.currentDirectoryPath,
                    executablePath: CommandLine.arguments[0])
    }

    /// Búsqueda normal (CLI y app).
    static func find(_ tool: ExternalTool, environment: [String: String],
                     currentDirectory: String, executablePath: String) -> String? {
        var directories: [String] = []
        if tool.isSystemTool { directories += systemToolDirectories }
        if let override = environment["OMNIMOUNT_TOOL_DIR"] {
            directories.append(override)
        }
        directories += vendorDirectories(executablePath: executablePath,
                                         currentDirectory: currentDirectory)
        directories += tool.candidateDirectories

        let fm = FileManager.default
        // El FS de macOS no distingue mayúsculas: buscando el CLI "omnimount",
        // la app "Omnimount" se encontraría a sí misma y se relanzaría en bucle.
        let selfPath = URL(fileURLWithPath: executablePath)
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

    /// Búsqueda restringida del helper. `verify(ruta, teamID)` comprueba la
    /// firma en cada búsqueda; no se guarda ningún resultado.
    ///
    /// La comprobación y la ejecución posterior son pasos distintos sobre una
    /// ruta: esto limita lo que el helper ejecuta a herramientas firmadas por
    /// el equipo en su propio directorio, pero no es atómico.
    static func find(_ tool: ExternalTool, trusted policy: TrustedToolPolicy,
                     verify: (String, String) -> Bool) -> String? {
        if tool.isSystemTool {
            let fm = FileManager.default
            return systemToolDirectories
                .map { ($0 as NSString).appendingPathComponent(tool.rawValue) }
                .first { fm.isExecutableFile(atPath: $0) }
        }
        // El helper nunca necesita el CLI.
        guard tool != .omnimountCLI else { return nil }
        guard let team = policy.teamIdentifier,
              HelperClientRequirement.isValidTeamIdentifier(team) else {
            log.error("\(tool.rawValue, privacy: .public) not used: the helper has no Team ID")
            return nil
        }
        let path = (policy.bundledToolDirectory as NSString).appendingPathComponent(tool.rawValue)
        guard isRegularExecutable(atPath: path) else {
            log.error("\(path, privacy: .public) is not a regular executable file in the helper directory")
            return nil
        }
        guard verify(path, team) else {
            log.error("\(path, privacy: .public) does not satisfy the Team ID requirement \(team, privacy: .public)")
            return nil
        }
        return path
    }

    /// Fichero regular y ejecutable, sin seguir un enlace simbólico final.
    static func isRegularExecutable(atPath path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o111) != 0
    }

    /// Firma válida de Apple cuyo certificado final pertenece a `team`.
    static func satisfiesTeamRequirement(path: String, team: String) -> Bool {
        guard let text = HelperClientRequirement.teamRequirement(teamIdentifier: team) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate),
                                          requirement) == errSecSuccess
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
