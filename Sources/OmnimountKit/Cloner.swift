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
    /// El usuario que lo pide no puede crear ficheros en esa carpeta.
    case folderAccess(String)
    /// Ya existe un fichero con ese nombre y no es del usuario que lo pide.
    case notYours(String)
    /// Hay un `.partial` que no es un fichero del usuario que lo pide.
    case stalePartial(String)
    /// El usuario que lo pide no puede leer la imagen (o no existe).
    case readAccess(String)
    case notRegularFile(String)
    case badName(String)

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
        case .folderAccess(let path):
            return L10n.t("error.clone.folderAccess", path)
        case .notYours(let path):
            return L10n.t("error.clone.notYours", path)
        case .stalePartial(let path):
            return L10n.t("error.clone.stalePartial", path)
        case .readAccess(let path):
            return L10n.t("error.clone.readAccess", path)
        case .notRegularFile(let path):
            return L10n.t("error.clone.notFile", path)
        case .badName(let path):
            return L10n.t("error.clone.badName", path)
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

        // Todas las comprobaciones del destino, ANTES de desmontar nada.
        let destination = try ImageDestination.open(imagePath, owner: owner,
                                                    access: owner.flatMap(CallerAccess.init(checking:)))
        // Comprobar espacio en destino ANTES de pasar una hora copiando.
        if let free = destination.freeBytes(), free < totalBytes {
            throw CloneError.imageLargerThanTarget(image: totalBytes, target: free)
        }
        try destination.checkExistingImage()
        try unmountTarget(identifier)

        let rawPath = "/dev/r\(identifier)"
        guard let input = FileHandle(forReadingAtPath: rawPath) else {
            throw CloneError.cannotOpen(rawPath)
        }
        defer { try? input.close() }

        try writeImage(from: input, totalBytes: totalBytes, to: destination, progress: progress)
    }

    /// Fichero donde se escribe el clon en curso. La app consulta su tamaño
    /// para mostrar el progreso: el nombre es exactamente `imagePath + ".partial"`.
    public static func partialImagePath(for imagePath: String) -> String {
        imagePath + ".partial"
    }

    /// Escribe la imagen en `<imagePath>.partial` y la renombra a `imagePath`
    /// solo si la copia termina. Si falla, borra el parcial y conserva la
    /// imagen anterior, si existía. Todo es relativo al directorio abierto.
    static func writeImage(from input: FileHandle, totalBytes: Int64, to destination: ImageDestination,
                           progress: (CloneProgress) -> Void) throws {
        let output = try destination.createPartial()
        var finished = false
        defer {
            if !finished {
                try? output.close()
                destination.removePartial()
            }
        }
        try copyStream(from: input, to: output, totalBytes: totalBytes, progress: progress)
        try output.close()
        try destination.commit()
        finished = true
    }

    /// Restaura una imagen .img sobre un disco o partición. DESTRUCTIVO:
    /// sobrescribe el destino. El llamante es responsable de pedir confirmación.
    /// `requestedBy`: usuario en cuyo nombre actúa el helper; la imagen debe
    /// poder leerla él mismo. nil (CLI bajo sudo) = sin comprobaciones extra.
    public static func restore(imagePath: String, to identifier: String,
                               requestedBy caller: ImageOwner? = nil,
                               progress: (CloneProgress) -> Void) throws {
        guard getuid() == 0 else { throw CloneError.notRoot }

        // Un único descriptor para el tamaño y para la lectura.
        let image = try openRestoreImage(imagePath, access: caller.flatMap(CallerAccess.init(checking:)))
        defer { try? image.handle.close() }
        try validateRestore(imageSize: image.size, targetInfo: DiskLister.info(for: identifier),
                            identifier: identifier)

        try unmountTarget(identifier)

        let rawPath = "/dev/r\(identifier)"
        guard let output = FileHandle(forWritingAtPath: rawPath) else {
            throw CloneError.cannotOpen(rawPath)
        }
        defer { try? output.close() }

        try copyStream(from: image.handle, to: output, totalBytes: image.size, progress: progress)
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

    /// Abre la imagen a restaurar. Con `access`, la ruta se resuelve
    /// (realpath) y se recorre desde "/" comprobando que el usuario puede
    /// atravesar cada carpeta y leer el fichero; los enlaces simbólicos se
    /// siguen, pero se comprueba cada componente de la ruta resuelta. Rechaza
    /// lo que no sea un fichero regular y una imagen vacía antes de consultar
    /// o desmontar el destino.
    static func openRestoreImage(_ imagePath: String,
                                 access: CallerAccess?) throws -> (handle: FileHandle, size: Int64) {
        let flags = O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
        let descriptor: Int32
        var ignoresOwnership = false
        if let access {
            guard let canonical = PathWalk.canonicalPath(imagePath),
                  let split = PathWalk.split(canonical),
                  let parent = PathWalk.openDirectory(split.directory, access: access, need: .search) else {
                throw CloneError.readAccess(imagePath)
            }
            defer { close(parent.descriptor) }
            descriptor = openat(parent.descriptor, split.name, flags | O_NOFOLLOW)
            guard descriptor >= 0 else { throw CloneError.readAccess(imagePath) }
            ignoresOwnership = PathWalk.ignoresOwnership(descriptor)
        } else {
            descriptor = open(imagePath, flags)
            guard descriptor >= 0 else { throw CloneError.cannotOpen(imagePath) }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CloneError.cannotOpen(imagePath) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CloneError.notRegularFile(imagePath) }
        if let access, !access.permits(.read, info, ignoresOwnership: ignoresOwnership) {
            throw CloneError.readAccess(imagePath)
        }
        guard info.st_size > 0 else { throw CloneError.ioError(L10n.t("error.clone.empty")) }
        // O_NONBLOCK solo evitaba bloquearse al abrir algo que no fuera un fichero.
        let current = fcntl(descriptor, F_GETFL)
        guard current >= 0, fcntl(descriptor, F_SETFL, current & ~O_NONBLOCK) == 0 else {
            throw CloneError.cannotOpen(imagePath)
        }
        return (handle, Int64(info.st_size))
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

/// Permisos del usuario en cuyo nombre actúa el helper, calculados con los
/// bits de modo (propietario, grupo, otros). Las ACL no se evalúan: un
/// acceso concedido solo por ACL se rechaza.
struct CallerAccess {
    struct Need: OptionSet {
        let rawValue: mode_t
        static let read = Need(rawValue: 4)
        static let write = Need(rawValue: 2)
        static let search = Need(rawValue: 1)
    }

    let uid: uid_t
    let gid: gid_t
    let isMember: (gid_t) -> Bool

    init(uid: uid_t, gid: gid_t, isMember: @escaping (gid_t) -> Bool) {
        self.uid = uid
        self.gid = gid
        self.isMember = isMember
    }

    /// nil para root: actúa como el CLI bajo sudo, sin comprobaciones extra.
    init?(checking owner: ImageOwner) {
        guard owner.uid != 0 else { return nil }
        let groups = Self.groups(of: owner.uid, primary: owner.gid)
        self.init(uid: owner.uid, gid: owner.gid, isMember: { groups.contains($0) })
    }

    /// Regla: root o un volumen con la propiedad ignorada → sí. Propietario
    /// → bits de propietario. Resto → bits de grupo, y además pertenecer al
    /// grupo o que los bits de otros también lo permitan (conservador: un
    /// modo como 0604 no da acceso por una pertenencia no detectada).
    func permits(_ need: Need, mode: mode_t, owner: uid_t, group: gid_t, ignoresOwnership: Bool) -> Bool {
        if uid == 0 || ignoresOwnership { return true }
        let bits = need.rawValue
        if owner == uid { return (mode >> 6) & bits == bits }
        guard (mode >> 3) & bits == bits else { return false }
        return group == gid || isMember(group) || mode & bits == bits
    }

    func permits(_ need: Need, _ info: stat, ignoresOwnership: Bool) -> Bool {
        permits(need, mode: info.st_mode, owner: info.st_uid, group: info.st_gid,
                ignoresOwnership: ignoresOwnership)
    }

    /// Grupos del usuario según el directorio (getgrouplist) más el principal.
    static func groups(of uid: uid_t, primary: gid_t) -> Set<gid_t> {
        var result: Set<gid_t> = [primary]
        var record = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        guard getpwuid_r(uid, &record, &buffer, buffer.count, &found) == 0,
              found != nil, let name = record.pw_name else { return result }
        var count: Int32 = 64
        while count <= 65_536 {
            var list = [Int32](repeating: 0, count: Int(count))
            var size = count
            if getgrouplist(name, Int32(bitPattern: primary), &list, &size) == 0 {
                list.prefix(Int(size)).forEach { result.insert(gid_t(bitPattern: $0)) }
                break
            }
            count *= 4
        }
        return result
    }
}

/// Recorrido de rutas con descriptores, comprobando los permisos del
/// usuario en cada carpeta.
enum PathWalk {
    static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// "/a/b/c" → ("/a/b", "c"). nil si el último componente no es un nombre
    /// de fichero (vacío, "." o "..").
    static func split(_ path: String) -> (directory: String, name: String)? {
        guard let slash = path.lastIndex(of: "/") else {
            return isFileName(path) ? (".", path) : nil
        }
        let name = String(path[path.index(after: slash)...])
        guard isFileName(name) else { return nil }
        let directory = String(path[..<slash])
        return (directory.isEmpty ? "/" : directory, name)
    }

    static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    static func ignoresOwnership(_ descriptor: Int32) -> Bool {
        var info = statfs()
        return fstatfs(descriptor, &info) == 0 && (info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP)) != 0
    }

    private static func permits(_ descriptor: Int32, _ need: CallerAccess.Need, _ access: CallerAccess) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return access.permits(need, info, ignoresOwnership: ignoresOwnership(descriptor))
    }

    /// Abre `path` (absoluto) desde "/", componente a componente sin seguir
    /// enlaces, exigiendo búsqueda en cada carpeta y `need` en la última.
    /// Pensado para rutas ya resueltas con `canonicalPath`.
    static func openDirectory(_ path: String, access: CallerAccess,
                              need: CallerAccess.Need) -> (descriptor: Int32, ignoresOwnership: Bool)? {
        guard path.hasPrefix("/") else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for component in path.split(separator: "/") {
            guard component != ".", component != "..",
                  permits(current, .search, access) else {
                close(current)
                return nil
            }
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { return nil }
            current = next
        }
        guard permits(current, need.union(.search), access) else {
            close(current)
            return nil
        }
        return (current, ignoresOwnership(current))
    }
}

/// Destino de un clon: la carpeta se abre una vez y el resto de pasos
/// (comprobar, crear el parcial, borrar, renombrar) son relativos a ella.
/// Con `access` (helper), la carpeta debe permitir escribir al usuario y los
/// ficheros existentes que se sustituyen deben ser suyos.
final class ImageDestination {
    let directory: Int32
    let name: String
    let imagePath: String
    let owner: ImageOwner?
    private let access: CallerAccess?
    private let ignoresOwnership: Bool

    var partialName: String { name + ".partial" }
    var partialPath: String { Cloner.partialImagePath(for: imagePath) }

    private init(directory: Int32, name: String, imagePath: String, owner: ImageOwner?,
                 access: CallerAccess?, ignoresOwnership: Bool) {
        self.directory = directory
        self.name = name
        self.imagePath = imagePath
        self.owner = owner
        self.access = access
        self.ignoresOwnership = ignoresOwnership
    }

    deinit { close(directory) }

    static func open(_ imagePath: String, owner: ImageOwner?, access: CallerAccess?) throws -> ImageDestination {
        guard let split = PathWalk.split(imagePath) else { throw CloneError.badName(imagePath) }
        if let access {
            guard let canonical = PathWalk.canonicalPath(split.directory),
                  let opened = PathWalk.openDirectory(canonical, access: access, need: .write) else {
                throw CloneError.folderAccess(split.directory)
            }
            return ImageDestination(directory: opened.descriptor, name: split.name, imagePath: imagePath,
                                    owner: owner, access: access, ignoresOwnership: opened.ignoresOwnership)
        }
        let descriptor = Darwin.open(split.directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CloneError.cannotOpen(imagePath) }
        return ImageDestination(directory: descriptor, name: split.name, imagePath: imagePath,
                                owner: owner, access: nil, ignoresOwnership: false)
    }

    func freeBytes() -> Int64? {
        var info = statfs()
        guard fstatfs(directory, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Con `access`, un fichero existente solo se sustituye si es del usuario
    /// (salvo en volúmenes con la propiedad ignorada).
    private func belongsToCaller(_ info: stat) -> Bool {
        guard let access else { return true }
        return ignoresOwnership || info.st_uid == access.uid
    }

    /// El destino debe no existir o ser un fichero regular (se sustituye al
    /// terminar). Enlaces simbólicos, directorios y otros tipos se rechazan
    /// sin modificarlos.
    func checkExistingImage() throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw CloneError.notRegularFile(imagePath) }
            guard belongsToCaller(info) else { throw CloneError.notYours(imagePath) }
        } else if errno != ENOENT {
            throw access == nil ? CloneError.cannotOpen(imagePath) : CloneError.folderAccess(imagePath)
        }
    }

    /// Crea el parcial con O_CREAT|O_EXCL|O_NOFOLLOW. Un parcial previo solo
    /// se borra si es un fichero regular (del usuario, con `access`).
    func createPartial() throws -> FileHandle {
        var info = stat()
        if fstatat(directory, partialName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, belongsToCaller(info) else {
                throw CloneError.stalePartial(partialPath)
            }
            guard unlinkat(directory, partialName, 0) == 0 || errno == ENOENT else {
                throw CloneError.stalePartial(partialPath)
            }
        }
        let descriptor = openat(directory, partialName,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw CloneError.stalePartial(partialPath) }
            throw access == nil ? CloneError.cannotOpen(partialPath)
                : CloneError.folderAccess((imagePath as NSString).deletingLastPathComponent)
        }
        // Modo independiente de la umask del proceso; el propietario se aplica
        // sobre el descriptor (un fallo no es fatal).
        _ = fchmod(descriptor, 0o644)
        if let owner { _ = fchown(descriptor, owner.uid, owner.gid) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func removePartial() {
        _ = unlinkat(directory, partialName, 0)
    }

    /// Sustituye el destino por el parcial, tras volver a comprobarlo.
    func commit() throws {
        try checkExistingImage()
        guard renameat(directory, partialName, directory, name) == 0 else {
            throw CloneError.ioError("rename \(partialPath): \(String(cString: strerror(errno)))")
        }
    }
}
