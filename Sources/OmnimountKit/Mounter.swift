import Foundation

public enum MountError: Error, LocalizedError {
    case notRoot
    case macFUSEMissing
    case toolMissing(ExternalTool)
    case unsupportedFilesystem(DetectedFilesystem)
    case mountFailed(tool: String, stderr: String)
    case unmountFailed(String)
    case fsckFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRoot:
            return "Montar requiere privilegios de root. Ejecuta el comando con sudo."
        case .macFUSEMissing:
            return "macFUSE no está instalado. Instálalo con: brew install --cask macfuse (y aprueba la extensión en Ajustes del Sistema → Privacidad y seguridad)."
        case .toolMissing(let tool):
            return "No se encontró \(tool.rawValue). Consulta el README para instalarlo."
        case .unsupportedFilesystem(let fs):
            return "Omnimount no puede montar \(fs.displayName)."
        case .mountFailed(let tool, let stderr):
            return "\(tool) falló al montar: \(stderr)"
        case .unmountFailed(let message):
            return "No se pudo desmontar: \(message)"
        case .fsckFailed(let message):
            return "La verificación (fsck) encontró problemas: \(message)"
        }
    }
}

public struct MountResult: Sendable {
    public let devicePath: String
    public let mountPoint: String
    public let filesystem: DetectedFilesystem
    public let backend: String
}

/// Monta y desmonta particiones ext2/3/4 y NTFS envolviendo fuse2fs y ntfs-3g.
/// Todas las operaciones asumen que el proceso corre como root (el CLI bajo
/// sudo; la app de menú relanza el CLI con privilegios de administrador).
public enum Mounter {

    public static var isRoot: Bool { getuid() == 0 }

    /// Punto de montaje por defecto: /Volumes/<etiqueta o identificador>.
    public static func defaultMountPoint(partition: DiskPartition, detection: DetectionResult) -> String {
        var name = detection.label ?? partition.volumeName ?? partition.deviceIdentifier
        name = name.replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = partition.deviceIdentifier }
        return "/Volumes/\(name)"
    }

    public static func mount(partition: DiskPartition,
                             detection: DetectionResult,
                             mountPoint explicitMountPoint: String? = nil,
                             readOnly: Bool = false) throws -> MountResult {
        // FAT/exFAT no necesitan FUSE: macOS los monta, aunque no automonte
        // particiones con tipo "oculto" (p. ej. 0x1C, la EASYROMS de ArkOS).
        if detection.filesystem == .fat || detection.filesystem == .exfat {
            return try mountNatively(partition: partition, detection: detection, readOnly: readOnly)
        }

        guard isRoot else { throw MountError.notRoot }
        guard ToolLocator.isMacFUSEInstalled else { throw MountError.macFUSEMissing }

        let tool: ExternalTool
        switch detection.filesystem {
        case .ext2, .ext3, .ext4: tool = .fuse2fs
        case .ntfs: tool = .ntfs3g
        default: throw MountError.unsupportedFilesystem(detection.filesystem)
        }
        guard let toolPath = ToolLocator.find(tool) else { throw MountError.toolMissing(tool) }

        let mountPoint = explicitMountPoint ?? defaultMountPoint(partition: partition, detection: detection)
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        let volname = (mountPoint as NSString).lastPathComponent
        var options: [String]
        switch tool {
        case .fuse2fs:
            // local: Finder trata el volumen como disco local.
            // allow_other: visible para el usuario aunque monte root.
            options = ["local", "allow_other", "volname=\(volname)"]
        case .ntfs3g:
            // windows_names: evita crear nombres inválidos para Windows.
            // big_writes mejora el rendimiento de escritura.
            options = ["local", "allow_other", "volname=\(volname)", "windows_names", "big_writes"]
        default:
            options = []
        }
        if readOnly { options.append("ro") }

        let args = [partition.devicePath, mountPoint, "-o", options.joined(separator: ",")]
        let result = try ShellRunner.run(toolPath, args)
        guard result.succeeded else {
            try? FileManager.default.removeItem(atPath: mountPoint)
            throw MountError.mountFailed(tool: tool.rawValue, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        // El daemon FUSE puede devolver 0 y aun así no montar (p. ej. si el
        // kext de macFUSE está bloqueado pendiente de aprobación). Confirmar
        // que el montaje existe de verdad antes de cantar victoria.
        var mounted = false
        for _ in 0..<10 {
            if currentMountPoint(devicePath: partition.devicePath) != nil
                || isMountPoint(mountPoint) {
                mounted = true
                break
            }
            usleep(300_000)
        }
        guard mounted else {
            try? FileManager.default.removeItem(atPath: mountPoint)
            throw MountError.mountFailed(
                tool: tool.rawValue,
                stderr: "\(tool.rawValue) terminó sin error pero el volumen no aparece montado. "
                    + "Causa habitual: la extensión de kernel de macFUSE está bloqueada — "
                    + "apruébala en Ajustes del Sistema → Privacidad y seguridad y reinicia. "
                    + "Salida: \(result.stdout) \(result.stderr)")
        }

        return MountResult(
            devicePath: partition.devicePath,
            mountPoint: mountPoint,
            filesystem: detection.filesystem,
            backend: toolPath
        )
    }

    /// Monta vía diskutil los FS que macOS ya entiende (FAT/exFAT) pero que no
    /// automonta por tener tipo de partición oculto.
    private static func mountNatively(partition: DiskPartition,
                                      detection: DetectionResult,
                                      readOnly: Bool) throws -> MountResult {
        var args = ["mount"]
        if readOnly { args += ["readOnly"] }
        args.append(partition.deviceIdentifier)
        let result = try ShellRunner.run("/usr/sbin/diskutil", args)
        guard result.succeeded else {
            throw MountError.mountFailed(tool: "diskutil",
                                         stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let info = (try? DiskLister.info(for: partition.deviceIdentifier)) ?? [:]
        let mountPoint = info["MountPoint"] as? String ?? "/Volumes"
        return MountResult(
            devicePath: partition.devicePath,
            mountPoint: mountPoint,
            filesystem: detection.filesystem,
            backend: "/usr/sbin/diskutil"
        )
    }

    /// Desmontaje limpio: primero diskutil (avisa a diskarbitrationd), después
    /// umount como plan B. Elimina el directorio de /Volumes si queda vacío.
    public static func unmount(mountPoint: String) throws {
        var lastError = ""
        let diskutil = try ShellRunner.run("/usr/sbin/diskutil", ["unmount", mountPoint])
        if !diskutil.succeeded {
            lastError = diskutil.stderr.isEmpty ? diskutil.stdout : diskutil.stderr
            let umount = try ShellRunner.run("/sbin/umount", [mountPoint])
            if !umount.succeeded {
                throw MountError.unmountFailed(umount.stderr.isEmpty ? lastError : umount.stderr)
            }
        }
        // Limpieza del punto de montaje (solo si está vacío).
        if mountPoint.hasPrefix("/Volumes/") {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(atPath: mountPoint)
            }
        }
    }

    /// true si la ruta es un punto de montaje real (device distinto al del padre).
    public static func isMountPoint(_ path: String) -> Bool {
        var st = stat(), parentSt = stat()
        guard stat(path, &st) == 0,
              stat((path as NSString).deletingLastPathComponent, &parentSt) == 0 else {
            return false
        }
        return st.st_dev != parentSt.st_dev
    }

    /// Deriva el punto de montaje esperado de una partición re-detectando su
    /// etiqueta y comprueba que está montado de verdad. Necesario con FUSE-T,
    /// cuyos montajes aparecen como "fuse-t:/<volname>" en mount(8), sin
    /// rastro del /dev/diskXsY. Requiere poder leer el dispositivo (root+TCC).
    public static func derivedMountPoint(partition: DiskPartition) -> String? {
        guard let detection = try? FilesystemDetector.detect(devicePath: partition.devicePath) else {
            return nil
        }
        let candidate = defaultMountPoint(partition: partition, detection: detection)
        return isMountPoint(candidate) ? candidate : nil
    }

    /// Busca el punto de montaje actual de un dispositivo consultando mount(8).
    public static func currentMountPoint(devicePath: String) -> String? {
        guard let result = try? ShellRunner.run("/sbin/mount", []) else { return nil }
        for line in result.stdout.split(separator: "\n") {
            // Formato: "/dev/disk4s1 on /Volumes/X (fuse, ...)"
            let parts = line.components(separatedBy: " on ")
            guard parts.count == 2, parts[0] == devicePath else { continue }
            if let range = parts[1].range(of: " (", options: .backwards) {
                return String(parts[1][..<range.lowerBound])
            }
        }
        return nil
    }

    /// Verificación de integridad tras desmontar (fsck en modo solo-comprobación).
    public static func verify(devicePath: String, filesystem: DetectedFilesystem) throws -> String {
        switch filesystem {
        case .ext2, .ext3, .ext4:
            guard let e2fsck = ToolLocator.find(.e2fsck) else { throw MountError.toolMissing(.e2fsck) }
            // -f fuerza la comprobación, -n solo lectura (no repara).
            let result = try ShellRunner.run(e2fsck, ["-f", "-n", devicePath])
            // e2fsck: 0 = limpio, 4+ = errores sin corregir.
            guard result.exitCode == 0 else {
                throw MountError.fsckFailed(result.stdout + result.stderr)
            }
            return result.stdout
        case .ntfs:
            guard let ntfsfix = ToolLocator.find(.ntfsfix) else { throw MountError.toolMissing(.ntfsfix) }
            // -n: dry run, solo diagnóstico.
            let result = try ShellRunner.run(ntfsfix, ["-n", devicePath])
            guard result.succeeded else {
                throw MountError.fsckFailed(result.stdout + result.stderr)
            }
            return result.stdout
        default:
            throw MountError.unsupportedFilesystem(filesystem)
        }
    }
}
