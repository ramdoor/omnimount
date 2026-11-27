import DiskArbitration
import Foundation
import IOKit
import OmnimountKit

/// Huella del disco o partición que el usuario eligió para una operación
/// destructiva (formatear, restaurar). El helper solo recibe el identificador
/// BSD, que macOS puede reasignar a otro disco si se extrae uno y se conecta
/// otro mientras el diálogo está abierto; esta huella permite comprobar,
/// justo antes de enviar la orden, que el identificador sigue apuntando al
/// mismo dispositivo.
///
/// La comprobación principal es el ID de registro de IOKit del objeto
/// IOMedia: un disco extraído y vuelto a conectar (o sustituido) obtiene un
/// objeto nuevo con otro ID. Si al elegir no se pudo obtener ese ID, se
/// recurre a comparar tamaño y nombre con el listado actual.
struct DiskIdentity {
    let deviceIdentifier: String
    let isWholeDisk: Bool
    let size: Int64
    let name: String?
    /// ID de registro IOKit al elegir (nil si no se pudo obtener).
    let registryEntryID: UInt64?

    init(partition: DiskPartition) {
        deviceIdentifier = partition.deviceIdentifier
        isWholeDisk = false
        size = partition.size
        name = partition.volumeName
        registryEntryID = Self.registryEntryID(for: partition.deviceIdentifier)
    }

    init(disk: ExternalDisk) {
        deviceIdentifier = disk.deviceIdentifier
        isWholeDisk = true
        size = disk.size
        name = disk.mediaName
        registryEntryID = Self.registryEntryID(for: disk.deviceIdentifier)
    }

    /// ID de registro IOKit del IOMedia que hoy corresponde a `bsdName`.
    static func registryEntryID(for bsdName: String) -> UInt64? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            return nil
        }
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &entryID) == KERN_SUCCESS else { return nil }
        return entryID
    }

    /// Compara con el estado actual. `listed` es el dispositivo con el mismo
    /// identificador en un listado reciente (nil si ya no aparece).
    /// - Con ID de registro al elegir: debe existir ahora y ser el mismo.
    /// - Sin él: debe seguir listado con el mismo tamaño y nombre.
    func matches(listedSize: Int64?, listedName: String?) -> Bool {
        if let registryEntryID {
            return Self.registryEntryID(for: deviceIdentifier) == registryEntryID
        }
        guard let listedSize else { return false }
        return listedSize == size && listedName == name
    }

    /// Busca este dispositivo en `disks` y aplica `matches`.
    func matches(in disks: [ExternalDisk]) -> Bool {
        if isWholeDisk {
            let disk = disks.first { $0.deviceIdentifier == deviceIdentifier }
            return matches(listedSize: disk?.size, listedName: disk?.mediaName)
        }
        let partition = disks.flatMap(\.partitions)
            .first { $0.deviceIdentifier == deviceIdentifier }
        return matches(listedSize: partition?.size, listedName: partition?.volumeName)
    }

    /// true si la comprobación necesita un listado reciente de discos.
    var needsFreshListing: Bool { registryEntryID == nil }
}
