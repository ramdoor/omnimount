import Foundation

public struct CloneProgress: Sendable {
    public let bytesCopied: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double

    public var fraction: Double {
        totalBytes > 0 ? Double(bytesCopied) / Double(totalBytes) : 0
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
            return L10n.t("Clonar/restaurar accede al dispositivo en bruto: ejecuta con sudo.", "Cloning/restoring accesses the raw device: run with sudo.")
        case .cannotOpen(let path):
            return L10n.t("No se pudo abrir \(path).", "Could not open \(path).")
        case .sizeUnknown(let disk):
            return L10n.t("No se pudo determinar el tamaño de \(disk).", "Could not determine the size of \(disk).")
        case .imageLargerThanTarget(let image, let target):
            let f = ByteCountFormatter()
            return L10n.t("La imagen (\(f.string(fromByteCount: image))) no cabe en el destino (\(f.string(fromByteCount: target))).", "The image (\(f.string(fromByteCount: image))) does not fit in the target (\(f.string(fromByteCount: target))).")
        case .unmountFailed(let message):
            return L10n.t("No se pudo desmontar el disco antes de la operación: \(message)", "Could not unmount the disk before the operation: \(message)")
        case .ioError(let message):
            return L10n.t("Error de E/S: \(message)", "I/O error: \(message)")
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

    /// Desmonta el objetivo (partición o disco entero) antes del acceso en bruto.
    /// Los montajes FUSE de Omnimount no aparecen en DiskArbitration, así que
    /// `diskutil unmountDisk` no los toca: hay que localizarlos por mount(8)
    /// y desmontarlos uno a uno antes.
    private static func unmountTarget(_ identifier: String) throws {
        if isPartition(identifier) {
            if let fuseMount = Mounter.currentMountPoint(devicePath: "/dev/\(identifier)") {
                try Mounter.unmount(mountPoint: fuseMount)
            }
            // Puede no estar montada; diskutil devuelve error inofensivo en ese caso.
            _ = try? ShellRunner.run("/usr/sbin/diskutil", ["unmount", identifier])
            return
        }
        if let disk = try? DiskLister.externalDisks().first(where: { $0.deviceIdentifier == identifier }) {
            for partition in disk.partitions {
                if let fuseMount = Mounter.currentMountPoint(devicePath: partition.devicePath) {
                    try Mounter.unmount(mountPoint: fuseMount)
                }
            }
        }
        let result = try ShellRunner.run("/usr/sbin/diskutil", ["unmountDisk", identifier])
        guard result.succeeded else {
            throw CloneError.unmountFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private static func diskSize(_ identifier: String) throws -> Int64 {
        let info = try DiskLister.info(for: identifier)
        guard let size = (info["TotalSize"] as? NSNumber)?.int64Value ?? (info["Size"] as? NSNumber)?.int64Value,
              size > 0 else {
            throw CloneError.sizeUnknown(identifier)
        }
        return size
    }

    /// Clona un disco entero ("disk4") o una partición ("disk4s2") a un .img.
    public static func clone(wholeDisk identifier: String, to imagePath: String,
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

        try unmountTarget(identifier)

        let rawPath = "/dev/r\(identifier)"
        guard let input = FileHandle(forReadingAtPath: rawPath) else {
            throw CloneError.cannotOpen(rawPath)
        }
        defer { try? input.close() }

        FileManager.default.createFile(atPath: imagePath, contents: nil)
        guard let output = FileHandle(forWritingAtPath: imagePath) else {
            throw CloneError.cannotOpen(imagePath)
        }
        defer { try? output.close() }

        try copyStream(from: input, to: output, totalBytes: totalBytes, progress: progress)
    }

    /// Restaura una imagen .img sobre un disco o partición. DESTRUCTIVO:
    /// sobrescribe el destino. El llamante es responsable de pedir confirmación.
    public static func restore(imagePath: String, to identifier: String,
                               progress: (CloneProgress) -> Void) throws {
        guard getuid() == 0 else { throw CloneError.notRoot }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath),
              let imageSize = (attrs[.size] as? NSNumber)?.int64Value else {
            throw CloneError.cannotOpen(imagePath)
        }
        let targetSize = try diskSize(identifier)
        guard imageSize <= targetSize else {
            throw CloneError.imageLargerThanTarget(image: imageSize, target: targetSize)
        }

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

    private static func copyStream(from input: FileHandle, to output: FileHandle,
                                   totalBytes: Int64, progress: (CloneProgress) -> Void) throws {
        var copied: Int64 = 0
        let start = Date()
        var lastReport = Date.distantPast

        while true {
            let chunk: Data
            do {
                chunk = try input.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw CloneError.ioError("lectura en offset \(copied): \(error.localizedDescription)")
            }
            if chunk.isEmpty { break }

            do {
                try output.write(contentsOf: chunk)
            } catch {
                throw CloneError.ioError("escritura en offset \(copied): \(error.localizedDescription)")
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

        try output.synchronize()
        let elapsed = Date().timeIntervalSince(start)
        progress(CloneProgress(
            bytesCopied: copied,
            totalBytes: totalBytes,
            bytesPerSecond: elapsed > 0 ? Double(copied) / elapsed : 0
        ))
    }
}
