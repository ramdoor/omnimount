import Foundation

public enum MountError: Error, LocalizedError {
    case notRoot
    case macFUSEMissing
    case toolMissing(ExternalTool)
    case unsupportedFilesystem(DetectedFilesystem)
    case mountFailed(tool: String, stderr: String)
    case unmountFailed(String)
    case fsckFailed(String)
    case ext4QuotaUnsupported(String)
    case ext4NeedsRepair(String, String)

    public var errorDescription: String? {
        switch self {
        case .notRoot:
            return L10n.t("Montar requiere privilegios de root. Ejecuta el comando con sudo.", "Mounting requires root privileges. Run the command with sudo.")
        case .macFUSEMissing:
            return L10n.t("No hay capa FUSE instalada. Recomendado: brew install --cask macos-fuse-t/cask/fuse-t (sin kext). Alternativa: brew install --cask macfuse.", "No FUSE layer installed. Recommended: brew install --cask macos-fuse-t/cask/fuse-t (kext-free). Alternative: brew install --cask macfuse.")
        case .toolMissing(let tool):
            return L10n.t("No se encontró \(tool.rawValue). Consulta el README para instalarlo.", "\(tool.rawValue) not found. See the README to install it.")
        case .unsupportedFilesystem(let fs):
            return L10n.t("Omnimount no puede montar \(fs.displayName).", "Omnimount cannot mount \(fs.displayName).")
        case .mountFailed(let tool, let stderr):
            return L10n.t("\(tool) falló al montar: \(stderr)", "\(tool) failed to mount: \(stderr)")
        case .unmountFailed(let message):
            return L10n.t("No se pudo desmontar: \(message)", "Could not unmount: \(message)")
        case .fsckFailed(let message):
            return L10n.t("La verificación (fsck) encontró problemas: \(message)", "Verification (fsck) found problems: \(message)")
        case .ext4NeedsRepair(let device, let detail):
            return L10n.t(
                "No se puede montar \(device) en escritura: e2fsck no terminó con un resultado seguro. Comprueba el disco desmontado con e2fsck o desde Linux antes de volver a intentarlo. Detalle: \(detail)",
                "Cannot mount \(device) for writing: e2fsck did not finish with a safe result. Check the unmounted disk with e2fsck or from Linux before retrying. Detail: \(detail)")
        case .ext4QuotaUnsupported(let device):
            return L10n.t(
                "Este disco usa cuotas internas de ext4 (habitual en discos de NAS), que fuse2fs no soporta. Desactívalas (no borra datos) con: sudo omnimount mount \(device) --fix-quota — o con tune2fs -O ^quota,^project.",
                "This disk uses ext4 internal quotas (common on NAS disks), which fuse2fs does not support. Disable them (no data loss) with: sudo omnimount mount \(device) --fix-quota — or with tune2fs -O ^quota,^project.")
        }
    }
}

public struct MountResult: Sendable {
    public let devicePath: String
    public let mountPoint: String
    public let filesystem: DetectedFilesystem
    public let backend: String
    /// true si el volumen quedó montado en solo lectura (NTFS "sucio" de
    /// Windows). ntfs-3g cae a solo lectura para proteger los datos.
    public let readOnly: Bool

    public init(devicePath: String, mountPoint: String,
                filesystem: DetectedFilesystem, backend: String,
                readOnly: Bool = false) {
        self.devicePath = devicePath
        self.mountPoint = mountPoint
        self.filesystem = filesystem
        self.backend = backend
        self.readOnly = readOnly
    }
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
                             readOnly: Bool = false,
                             forceWritable: Bool = false) throws -> MountResult {
        // FAT/exFAT no necesitan FUSE: macOS los monta, aunque no automonte
        // particiones con tipo "oculto" (p. ej. 0x1C, la EASYROMS de ArkOS).
        if detection.filesystem == .fat || detection.filesystem == .exfat {
            return try mountNatively(partition: partition, detection: detection, readOnly: readOnly)
        }

        guard isRoot else { throw MountError.notRoot }
        guard ToolLocator.isFuseTInstalled || ToolLocator.isMacFUSEInstalled else {
            throw MountError.macFUSEMissing
        }

        // fuse2fs rechaza superbloques con cuotas internas ("quotas not
        // supported"); detectarlo aquí da un error accionable en vez del críptico.
        if detection.filesystem != .ntfs, detection.extQuotaEnabled {
            throw MountError.ext4QuotaUnsupported(partition.deviceIdentifier)
        }

        let tool: ExternalTool
        switch detection.filesystem {
        case .ext2, .ext3, .ext4: tool = .fuse2fs
        case .ntfs: tool = .ntfs3g
        default: throw MountError.unsupportedFilesystem(detection.filesystem)
        }
        guard let toolPath = ToolLocator.find(tool) else { throw MountError.toolMissing(tool) }

        // fuse2fs 1.47.3 puede recuperar el journal al abrir ext3/4, pero no
        // usa el journal para proteger las escrituras posteriores. Conservamos
        // e2fsck -p como comprobación previa y reparación automática segura:
        // si requiere intervención (incluido reinicio), no se monta en escritura.
        // Se omite en solo lectura para no modificar el sistema de ficheros.
        if tool == .fuse2fs {
            try preflightExtMount(devicePath: partition.devicePath,
                                  deviceIdentifier: partition.deviceIdentifier,
                                  readOnly: readOnly)
        }

        let mountPoint = explicitMountPoint ?? defaultMountPoint(partition: partition, detection: detection)
        let createdMountPoint = try prepareMountPoint(mountPoint)
        var mounted = false
        defer {
            if !mounted { cleanupMountPoint(mountPoint, createdByUs: createdMountPoint) }
        }

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
            // remove_hiberfile: monta en escritura un NTFS que Windows dejó
            // hibernado (Inicio rápido), descartando la sesión suspendida.
            if forceWritable { options.append("remove_hiberfile") }
        default:
            options = []
        }
        if readOnly { options.append("ro") }

        let args = [partition.devicePath, mountPoint, "-o", options.joined(separator: ",")]
        let result = try ShellRunner.run(toolPath, args)
        guard result.succeeded else {
            throw MountError.mountFailed(tool: tool.rawValue, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        // El daemon FUSE puede devolver 0 y aun así no montar (p. ej. si el
        // kext de macFUSE está bloqueado pendiente de aprobación). Confirmar
        // que el montaje existe de verdad antes de cantar victoria.
        for _ in 0..<10 {
            if currentMountPoint(devicePath: partition.devicePath) != nil
                || isMountPoint(mountPoint) {
                mounted = true
                break
            }
            usleep(300_000)
        }
        guard mounted else {
            throw MountError.mountFailed(
                tool: tool.rawValue,
                stderr: L10n.t("\(tool.rawValue) terminó sin error pero el volumen no aparece montado. Causa habitual: la capa FUSE no está operativa (kext bloqueado o instalación incompleta). Salida: \(result.stdout) \(result.stderr)", "\(tool.rawValue) exited cleanly but the volume is not mounted. Usual cause: the FUSE layer is not operational (blocked kext or incomplete install). Output: \(result.stdout) \(result.stderr)"))
        }

        return MountResult(
            devicePath: partition.devicePath,
            mountPoint: mountPoint,
            filesystem: detection.filesystem,
            backend: toolPath,
            readOnly: isMountReadOnly(mountPoint)
        )
    }

    /// e2fsck usa una máscara de condiciones: solo 0 (limpio) y 1 (corregido)
    /// permiten continuar. 2/3 requieren reiniciar; una señal nunca es éxito.
    static func preflightExtMount(devicePath: String, deviceIdentifier: String, readOnly: Bool,
                                  findTool: (ExternalTool) -> String? = ToolLocator.find,
                                  run: (String, [String]) throws -> ShellResult = ShellRunner.run) throws {
        guard !readOnly else { return }
        guard let e2fsck = findTool(.e2fsck) else { throw MountError.toolMissing(.e2fsck) }
        let check = try run(e2fsck, ["-p", devicePath])
        guard !check.terminatedBySignal, check.exitCode == 0 || check.exitCode == 1 else {
            let status = check.terminatedBySignal ? "signal \(check.exitCode)" : "exit \(check.exitCode)"
            let output = (check.stdout + " " + check.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.ext4NeedsRepair(deviceIdentifier, "e2fsck: \(status). \(output)")
        }
    }

    /// mkdir permite distinguir atómicamente un directorio creado por esta
    /// operación de otro que ya existía, incluso si aparece durante la llamada.
    static func prepareMountPoint(_ path: String) throws -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if mkdir(path, 0o755) == 0 { return true }
        let errorCode = errno
        var info = stat()
        if errorCode == EEXIST, stat(path, &info) == 0,
           (info.st_mode & S_IFMT) == S_IFDIR { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode),
                      userInfo: [NSFilePathErrorKey: path])
    }

    /// rmdir nunca recorre contenido. Si el montaje apareció tarde o alguien
    /// escribió en el directorio, el kernel rechaza la limpieza sin borrar datos.
    static func cleanupMountPoint(_ path: String, createdByUs: Bool) {
        if createdByUs { _ = rmdir(path) }
    }

    /// true si el volumen montado en `mountPoint` es de solo lectura según el
    /// flag MNT_RDONLY (statfs). Fiable para los montajes NATIVOS de macOS
    /// (p. ej. el NTFS de solo lectura que macOS monta por su cuenta — es lo
    /// que Disk Utility muestra como "Writable: No"). NO fiable para los
    /// montajes propios sobre FUSE-T (se expone por NFS): para esos, usar
    /// isMountReadOnly (prueba de escritura) desde root.
    public static func isMountReadOnlyByFlags(_ mountPoint: String) -> Bool {
        var st = statfs()
        guard statfs(mountPoint, &st) == 0 else { return false }
        return (Int32(st.f_flags) & MNT_RDONLY) != 0
    }

    /// true si el volumen montado en `mountPoint` es de solo lectura. Usa una
    /// prueba de escritura real (crear y borrar un fichero oculto) en vez de
    /// statfs: en FUSE-T el volumen se expone por NFS y el flag de solo lectura
    /// de ntfs-3g NO se refleja en MNT_RDONLY. Debe ejecutarse como root (el
    /// helper/CLI). Un fallo también puede indicar permisos o un error de E/S;
    /// se trata conservadoramente como no escribible.
    public static func isMountReadOnly(_ mountPoint: String) -> Bool {
        // mkstemp crea un nombre único con O_EXCL y modo 0600: nunca trunca un
        // fichero del usuario ni sigue un enlace simbólico que ya existiera.
        var template = Array(((mountPoint as NSString)
            .appendingPathComponent(".omnimount-writetest-XXXXXX")).utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return true }
        _ = unlink(template)
        _ = close(descriptor)
        return false
    }

    /// Vuelve escribible un NTFS que Windows dejó en solo lectura (hibernación
    /// / Inicio rápido / desconexión sin expulsar): desmonta, limpia la marca
    /// "dirty" con ntfsfix y remonta con remove_hiberfile. ntfsfix puede reparar
    /// metadatos; remove_hiberfile descarta la sesión de Windows en hibernación.
    public static func makeNtfsWritable(partition: DiskPartition,
                                        detection: DetectionResult) throws -> MountResult {
        guard isRoot else { throw MountError.notRoot }
        guard detection.filesystem == .ntfs else {
            throw MountError.unsupportedFilesystem(detection.filesystem)
        }
        // ntfsfix exige el dispositivo desmontado. Cubre tanto el montaje de
        // macOS (partition.mountPoint / diskutil) como uno propio de FUSE-T.
        let mountPoint = partition.mountPoint.flatMap { isMountPoint($0) ? $0 : nil }
            ?? currentMountPoint(devicePath: partition.devicePath)
            ?? derivedMountPoint(partition: partition)
        try prepareNtfsForWriting(devicePath: partition.devicePath, mountPoint: mountPoint)
        return try mount(partition: partition, detection: detection, forceWritable: true)
    }

    static func prepareNtfsForWriting(devicePath: String, mountPoint: String?,
                                      findTool: (ExternalTool) -> String? = ToolLocator.find,
                                      unmount: (String) throws -> Void = Mounter.unmount,
                                      isMounted: (String) -> Bool = Mounter.isMountPoint,
                                      run: (String, [String]) throws -> ShellResult = ShellRunner.run) throws {
        guard let ntfsfix = findTool(.ntfsfix) else { throw MountError.toolMissing(.ntfsfix) }
        if let mountPoint, isMounted(mountPoint) {
            try unmount(mountPoint)
            guard !isMounted(mountPoint) else {
                throw MountError.unmountFailed(L10n.t(
                    "El volumen sigue montado en \(mountPoint).", "The volume is still mounted at \(mountPoint)."))
            }
        }
        // -d limpia la marca "dirty" solo si ntfsfix puede reparar el volumen.
        let result = try run(ntfsfix, ["-d", devicePath])
        guard result.succeeded || ntfsfixOnlyReportsHibernation(result) else {
            let status = result.terminatedBySignal ? "signal \(result.exitCode)" : "exit \(result.exitCode)"
            throw MountError.fsckFailed("ntfsfix: \(status). \(result.stdout) \(result.stderr)")
        }
    }

    /// El ntfsfix empaquetado (sin NLS) también sale con 1 cuando su única
    /// objeción es hibernación. En esa ruta ya aprobada por el usuario, ntfs-3g
    /// debe poder llegar a remove_hiberfile. No ignoramos otros diagnósticos.
    private static func ntfsfixOnlyReportsHibernation(_ result: ShellResult) -> Bool {
        guard !result.terminatedBySignal, result.exitCode == 1 else { return false }
        let output = result.stdout.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let errors = result.stderr.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let mftOK = "Processing of $MFT and $MFTMirr completed successfully."
        let hibernated = "Windows is hibernated, refused to mount."
        let remountDenied = "Remount failed: Operation not permitted"
        let expectedOutput: Set<String> = [
            "Mounting volume... FAILED", "Attempting to correct errors...",
            "Processing $MFT and $MFTMirr...", "Reading $MFT... OK",
            "Reading $MFTMirr... OK", "Comparing $MFTMirr to $MFT... OK", mftOK,
            "Setting required flags on partition... OK",
            "Going to empty the journal ($LogFile)... OK",
        ]
        return output.contains(mftOK) && output.allSatisfy(expectedOutput.contains)
            && errors.contains(hibernated) && errors.contains(remountDenied)
            && errors.allSatisfy { $0 == hibernated || $0 == remountDenied }
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
            _ = rmdir(mountPoint)
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

    /// Desactiva las cuotas internas del superbloque ext* (tune2fs) y pasa
    /// e2fsck. No borra datos; un NAS que las usara tendrá que recalcularlas.
    public static func disableExtQuota(devicePath: String) throws {
        guard isRoot else { throw MountError.notRoot }
        try repairExtQuota(devicePath: devicePath)
    }

    static func repairExtQuota(devicePath: String,
                               findTool: (ExternalTool) -> String? = ToolLocator.find,
                               run: (String, [String]) throws -> ShellResult = ShellRunner.run) throws {
        guard let tune2fs = findTool(.tune2fs) else {
            throw MountError.toolMissing(.tune2fs)
        }
        // Las dos herramientas son necesarias ANTES de modificar el superbloque.
        guard let e2fsck = findTool(.e2fsck) else { throw MountError.toolMissing(.e2fsck) }
        let result = try run(tune2fs, ["-O", "^quota,^project", devicePath])
        guard result.succeeded else {
            throw MountError.mountFailed(tool: "tune2fs", stderr: result.stderr)
        }
        // -f fuerza la pasada completa; -y acepta las reparaciones que deja
        // la retirada de los inodos de cuota. Solo salidas normales 0/1 son OK.
        let check = try run(e2fsck, ["-fy", devicePath])
        guard !check.terminatedBySignal, check.exitCode == 0 || check.exitCode == 1 else {
            let status = check.terminatedBySignal ? "signal \(check.exitCode)" : "exit \(check.exitCode)"
            throw MountError.fsckFailed("e2fsck: \(status). \(check.stdout) \(check.stderr)")
        }
    }
}
