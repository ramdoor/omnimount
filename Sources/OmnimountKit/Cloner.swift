import Foundation

public struct CloneProgress: Sendable {
    public let bytesCopied: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double

    public var fraction: Double {
        totalBytes > 0 ? Double(bytesCopied) / Double(totalBytes) : 0
    }
}

/// Propietario que recibe la imagen creada por el helper (que corre como
/// root). Se aplica con fchown sobre el descriptor abierto, no sobre la ruta.
public struct ImageOwner: Sendable, Equatable {
    public let uid: uid_t
    public let gid: gid_t

    public init(uid: uid_t, gid: gid_t) {
        self.uid = uid
        self.gid = gid
    }
}

public enum CloneError: Error, LocalizedError {
    case notRoot
    case cannotOpen(String)
    case sizeUnknown(String)
    case imageLargerThanTarget(image: Int64, target: Int64)
    case unmountFailed(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .notRoot:
            return L10n.t("error.clone.notRoot")
        case .cannotOpen(let path):
            return L10n.t("error.clone.open", path)
        case .sizeUnknown(let disk):
            return L10n.t("error.clone.size", disk)
        case .imageLargerThanTarget(let image, let target):
            let f = ByteCountFormatter()
            return L10n.t("error.clone.tooBig", f.string(fromByteCount: image), f.string(fromByteCount: target))
        case .unmountFailed(let message):
            return L10n.t("error.clone.unmount", message)
        case .ioError(let message):
            return L10n.t("error.clone.io", message)
        }
    }
}

/// Clonado de discos o particiones a imagen .img y restauración, estilo dd
/// pero con progreso. Usa el dispositivo en bruto (/dev/rdiskX) por
/// rendimiento; las lecturas/escrituras van en bloques de 4 MiB.
public enum Cloner {

    private static let chunkSize = 4 * 1024 * 1024

    /// true si el identificador es una partición (disk6s2) y no un disco entero.
    private static func isPartition(_ identifier: String) -> Bool {
        identifier.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil
    }

    /// Injectable operations keep raw-device preparation testable without disks.
    struct UnmountOperations {
        var externalDisks: () throws -> [ExternalDisk]
        var currentMountPoint: (String) -> String?
        var possibleFuseMountPoint: (DiskPartition) -> String?
        var unmount: (String) throws -> Void
        var runDiskutil: ([String]) throws -> ShellResult

        static var system: Self {
            Self(externalDisks: DiskLister.externalDisks,
                 currentMountPoint: { Mounter.currentMountPoint(devicePath: $0) },
                 possibleFuseMountPoint: { Mounter.derivedMountPoint(partition: $0) },
                 unmount: { try Mounter.unmount(mountPoint: $0) },
                 runDiskutil: { try ShellRunner.run("/usr/sbin/diskutil", $0) })
        }
    }

    private static func targetPartitions(_ identifier: String,
                                         in disks: [ExternalDisk]) throws -> [DiskPartition] {
        let partitions = isPartition(identifier)
            ? disks.flatMap(\.partitions).filter { $0.deviceIdentifier == identifier }
            : disks.first { $0.deviceIdentifier == identifier }?.partitions ?? []
        guard !partitions.isEmpty else {
            throw CloneError.unmountFailed(L10n.t("error.clone.missing", identifier))
        }
        return partitions
    }

    /// Confirma el desmontaje antes del acceso en bruto. FUSE-T pierde la
    /// asociación con /dev/disk…: una ruta derivada solo por etiqueta puede
    /// corresponder a otro disco. En ese caso no desmontamos un volumen ajeno;
    /// el usuario debe expulsarlo desde la app, que conserva su registro.
    static func unmountTarget(_ identifier: String,
                              operations: UnmountOperations = .system) throws {
        let partitions = try targetPartitions(identifier, in: operations.externalDisks())
        var knownMounts: Set<String> = []
        for partition in partitions {
            if let point = operations.currentMountPoint(partition.devicePath) ?? partition.mountPoint {
                knownMounts.insert(point)
            } else if let possible = operations.possibleFuseMountPoint(partition) {
                throw CloneError.unmountFailed(L10n.t("error.clone.ambiguous", possible))
            }
        }
        for point in knownMounts.sorted() {
            try operations.unmount(point)
        }
        let command = isPartition(identifier) ? "unmount" : "unmountDisk"
        let result = try operations.runDiskutil([command, identifier])
        // diskutil returns 1 when a partition is already unmounted, including
        // immediately after we unmounted its known mount point above. Accept
        // only that exact diagnostic, then still verify the fresh mount state.
        let alreadyUnmounted = isPartition(identifier)
            && !result.terminatedBySignal && result.exitCode == 1
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                == "\(identifier) was already unmounted"
        guard result.succeeded || alreadyUnmounted else {
            throw CloneError.unmountFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        // No ignorar errores ni asumir que exit 0 prueba que FUSE-T se desmontó.
        let refreshed = try targetPartitions(identifier, in: operations.externalDisks())
        for partition in refreshed {
            if let point = partition.mountPoint
                ?? operations.currentMountPoint(partition.devicePath)
                ?? operations.possibleFuseMountPoint(partition) {
                throw CloneError.unmountFailed(L10n.t("error.clone.stillMounted", identifier, point))
            }
        }
    }

    private static func diskSize(_ identifier: String) throws -> Int64 {
        try deviceSize(from: DiskLister.info(for: identifier), identifier: identifier)
    }

    static func deviceSize(from info: [String: Any], identifier: String) throws -> Int64 {
        // TotalSize may describe the mounted filesystem, which can be smaller
        // than its partition. Raw copies must include the entire device slice.
        guard let size = (info["IOKitSize"] as? NSNumber)?.int64Value
                ?? (info["Size"] as? NSNumber)?.int64Value
                ?? (info["TotalSize"] as? NSNumber)?.int64Value,
              size > 0 else {
            throw CloneError.sizeUnknown(identifier)
        }
        return size
    }

    /// Clona un disco entero ("disk4") o una partición ("disk4s2") a un .img.
    public static func clone(wholeDisk identifier: String, to imagePath: String,
                             owner: ImageOwner? = nil,
                             progress: (CloneProgress) -> Void) throws {
        guard getuid() == 0 else { throw CloneError.notRoot }
        let totalBytes = try diskSize(identifier)

        // Comprobar espacio en destino ANTES de pasar una hora copiando.
        let destDir = (imagePath as NSString).deletingLastPathComponent
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: destDir.isEmpty ? "." : destDir),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
           free < totalBytes {
            throw CloneError.imageLargerThanTarget(image: totalBytes, target: free)
        }

        try checkImageDestination(imagePath)
        try unmountTarget(identifier)

        let rawPath = "/dev/r\(identifier)"
        guard let input = FileHandle(forReadingAtPath: rawPath) else {
            throw CloneError.cannotOpen(rawPath)
        }
        defer { try? input.close() }

        try writeImage(from: input, totalBytes: totalBytes, to: imagePath,
                       owner: owner, progress: progress)
    }

    /// Fichero donde se escribe el clon en curso. La app consulta su tamaño
    /// para mostrar el progreso: el nombre es exactamente `imagePath + ".partial"`.
    public static func partialImagePath(for imagePath: String) -> String {
        imagePath + ".partial"
    }

    /// Antes de desmontar nada: el destino debe no existir o ser un fichero
    /// regular (se sustituye al terminar). Enlaces simbólicos, directorios y
    /// otros tipos se rechazan sin modificarlos.
    static func checkImageDestination(_ imagePath: String) throws {
        var info = stat()
        if lstat(imagePath, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw CloneError.cannotOpen(imagePath) }
        } else if errno != ENOENT {
            throw CloneError.cannotOpen(imagePath)
        }
    }

    /// Escribe la imagen en `<imagePath>.partial` y la renombra a `imagePath`
    /// solo si la copia termina. Si falla, borra el parcial y conserva la
    /// imagen anterior, si existía. El parcial se crea con
    /// O_CREAT|O_EXCL|O_NOFOLLOW; el propietario se aplica con fchown sobre el
    /// descriptor (un fallo no es fatal, como el chown que hacía el helper).
    static func writeImage(from input: FileHandle, totalBytes: Int64, to imagePath: String,
                           owner: ImageOwner?, progress: (CloneProgress) -> Void) throws {
        let partialPath = partialImagePath(for: imagePath)
        // Un parcial de un clon interrumpido: unlink elimina la entrada (si es
        // un enlace, no su destino). Si reaparece algo, O_EXCL falla.
        var info = stat()
        if lstat(partialPath, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR {
            _ = unlink(partialPath)
        }
        let descriptor = open(partialPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw CloneError.cannotOpen(partialPath) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var finished = false
        defer {
            if !finished {
                try? output.close()
                _ = unlink(partialPath)
            }
        }
        // Modo independiente de la umask del proceso.
        _ = fchmod(descriptor, 0o644)
        if let owner { _ = fchown(descriptor, owner.uid, owner.gid) }

        try copyStream(from: input, to: output, totalBytes: totalBytes, progress: progress)
        try output.close()
        guard rename(partialPath, imagePath) == 0 else {
            throw CloneError.ioError("rename \(partialPath): \(String(cString: strerror(errno)))")
        }
        finished = true
    }

    /// Restaura una imagen .img sobre un disco o partición. DESTRUCTIVO:
    /// sobrescribe el destino. El llamante es responsable de pedir confirmación.
    public static func restore(imagePath: String, to identifier: String,
                               progress: (CloneProgress) -> Void) throws {
        guard getuid() == 0 else { throw CloneError.notRoot }

        let imageSize = try restoreImageSize(at: imagePath)
        try validateRestore(imageSize: imageSize, targetInfo: DiskLister.info(for: identifier),
                            identifier: identifier)

        try unmountTarget(identifier)

        guard let input = FileHandle(forReadingAtPath: imagePath) else {
            throw CloneError.cannotOpen(imagePath)
        }
        defer { try? input.close() }

        let rawPath = "/dev/r\(identifier)"
        guard let output = FileHandle(forWritingAtPath: rawPath) else {
            throw CloneError.cannotOpen(rawPath)
        }
        defer { try? output.close() }

        try copyStream(from: input, to: output, totalBytes: imageSize, progress: progress)
    }

    /// Comprobaciones previas al desmontaje. Las escrituras en /dev/rdiskN
    /// deben ser múltiplos del tamaño de bloque del dispositivo: una imagen
    /// que no lo es fallaría en el último bloque, con el resto del destino ya
    /// sobrescrito. Sin DeviceBlockSize se usa 512, el sector mínimo.
    static func validateRestore(imageSize: Int64, targetInfo: [String: Any], identifier: String) throws {
        let targetSize = try deviceSize(from: targetInfo, identifier: identifier)
        guard imageSize <= targetSize else {
            throw CloneError.imageLargerThanTarget(image: imageSize, target: targetSize)
        }
        let reported = (targetInfo["DeviceBlockSize"] as? NSNumber)?.int64Value ?? 0
        let blockSize = reported > 0 ? reported : 512
        guard imageSize % blockSize == 0 else {
            throw CloneError.ioError(L10n.t("error.clone.misaligned", String(imageSize), String(blockSize)))
        }
    }

    /// Rechaza una imagen vacía antes de consultar o desmontar el destino.
    static func restoreImageSize(at imagePath: String) throws -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath),
              let imageSize = (attrs[.size] as? NSNumber)?.int64Value else {
            throw CloneError.cannotOpen(imagePath)
        }
        guard imageSize > 0 else {
            throw CloneError.ioError(L10n.t("error.clone.empty"))
        }
        return imageSize
    }

    static func copyStream(from input: FileHandle, to output: FileHandle,
                           totalBytes: Int64, progress: (CloneProgress) -> Void) throws {
        var copied: Int64 = 0
        let start = Date()
        var lastReport = Date.distantPast

        while copied < totalBytes {
            // autoreleasepool por iteración: sin él, los objetos Data/NSData
            // temporales del read/write se acumulan durante todo el copiado
            // (decenas de miles de iteraciones en un disco grande) y disparan
            // la presión de memoria de macOS ("Forzar salida de aplicaciones"),
            // que aborta el clon. Drenarlos cada vuelta mantiene la memoria plana.
            try autoreleasepool {
                let chunk: Data
                do {
                    let count = Int(min(Int64(chunkSize), totalBytes - copied))
                    chunk = try input.read(upToCount: count) ?? Data()
                } catch {
                    throw CloneError.ioError(L10n.t("error.clone.read", String(copied), error.localizedDescription))
                }
                guard !chunk.isEmpty else {
                    throw CloneError.ioError(L10n.t("error.clone.shortRead", String(copied), String(totalBytes)))
                }

                do {
                    try output.write(contentsOf: chunk)
                } catch {
                    throw CloneError.ioError(L10n.t("error.clone.write", String(copied), error.localizedDescription))
                }

                copied += Int64(chunk.count)
                let now = Date()
                if now.timeIntervalSince(lastReport) >= 0.5 || copied == totalBytes {
                    let elapsed = now.timeIntervalSince(start)
                    progress(CloneProgress(
                        bytesCopied: copied,
                        totalBytes: totalBytes,
                        bytesPerSecond: elapsed > 0 ? Double(copied) / elapsed : 0
                    ))
                    lastReport = now
                }
            }
        }

        try output.synchronize()
        let elapsed = Date().timeIntervalSince(start)
        progress(CloneProgress(
            bytesCopied: copied,
            totalBytes: totalBytes,
            bytesPerSecond: elapsed > 0 ? Double(copied) / elapsed : 0
        ))
    }
}
