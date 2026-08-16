import DiskArbitration
import Foundation
import OmnimountKit

/// Observa la inserción/extracción de discos con DiskArbitration y mantiene
/// la lista de particiones externas que macOS no ha montado.
@MainActor
final class DiskMonitor: ObservableObject {

    @Published var disks: [ExternalDisk] = []
    @Published var mountedByOmnimount: [String: String] = [:] // deviceIdentifier → mountPoint
    @Published var retroMatch: RetroCardMatch?
    @Published var lastError: String?

    private var session: DASession?
    private var refreshWorkItem: DispatchWorkItem?

    init() {
        startMonitoring()
        refresh()
    }

    private func startMonitoring() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let appeared: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            let monitor = Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.scheduleRefresh()
        }
        let disappeared: DADiskDisappearedCallback = { _, context in
            guard let context else { return }
            let monitor = Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.scheduleRefresh()
        }
        let changed: DADiskDescriptionChangedCallback = { _, _, context in
            guard let context else { return }
            let monitor = Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.scheduleRefresh()
        }

        DARegisterDiskAppearedCallback(session, nil, appeared, context)
        DARegisterDiskDisappearedCallback(session, nil, disappeared, context)
        // Solo cambios de punto de montaje, para no refrescar por ruido.
        let watchedKeys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watchedKeys, changed, context)
    }

    /// DiskArbitration dispara ráfagas de eventos al insertar un disco;
    /// se agrupan en un único refresco.
    nonisolated private func scheduleRefresh() {
        Task { @MainActor in
            self.refreshWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.refresh() }
            self.refreshWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    func refresh() {
        let session = sessionMounts
        Task.detached(priority: .userInitiated) {
            do {
                let disks = try DiskLister.externalDisks()
                let mounted = Self.omnimountMounts(disks: disks, session: session)
                let retro = RetroCards.identify(partitions: disks.flatMap(\.partitions))
                await MainActor.run {
                    self.disks = disks
                    self.mountedByOmnimount = mounted
                    self.retroMatch = retro
                    self.lastError = nil
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    /// Registro de montajes hechos por Omnimount en esta sesión de la app.
    /// Con FUSE-T, mount(8) no permite mapear dispositivo → punto de montaje
    /// (aparecen como "fuse-t:/<volname>"), así que la app apunta los suyos
    /// y los valida con stat en cada refresco.
    private var sessionMounts: [String: String] = [:]

    func recordOmnimountMount(deviceIdentifier: String, mountPoint: String) {
        sessionMounts[deviceIdentifier] = mountPoint
        mountedByOmnimount[deviceIdentifier] = mountPoint
    }

    func forgetOmnimountMount(deviceIdentifier: String) {
        sessionMounts.removeValue(forKey: deviceIdentifier)
        mountedByOmnimount.removeValue(forKey: deviceIdentifier)
    }

    /// Puntos de montaje FUSE activos: mount(8) para macFUSE, más el registro
    /// de sesión (validado) para FUSE-T.
    nonisolated private static func omnimountMounts(disks: [ExternalDisk],
                                                   session: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for partition in disks.flatMap(\.partitions) {
            if let point = Mounter.currentMountPoint(devicePath: partition.devicePath) {
                result[partition.deviceIdentifier] = point
            }
        }
        for (device, point) in session where result[device] == nil {
            if Mounter.isMountPoint(point) {
                result[device] = point
            }
        }
        return result
    }
}
