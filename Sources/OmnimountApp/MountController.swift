import AppKit
import Foundation
import OmnimountKit

/// Ejecuta las operaciones privilegiadas (montar/desmontar) relanzando el CLI
/// `omnimount` con el diálogo de administrador de macOS. La app no lleva
/// lógica de montaje propia: un único código, el del CLI.
@MainActor
final class MountController: ObservableObject {

    @Published var busyPartitions: Set<String> = []
    @Published var lastMessage: String?

    /// Helper privilegiado (SMAppService): si está activo, monta sin pedir
    /// contraseña. Si no, se recurre a osascript como plan B.
    let helper = HelperClient()

    /// Monitor al que notificar los montajes propios (lo inyecta la vista).
    weak var monitor: DiskMonitor?

    init() {
        // Tras una actualización de la app, la huella de firma registrada del
        // helper (LWCR) queda obsoleta y launchd se niega a arrancarlo.
        // Detectar el cambio de versión y re-registrarlo automáticamente.
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let previous = UserDefaults.standard.string(forKey: "lastRunVersion")
        // previous == nil también cuenta como cambio: quien actualiza desde
        // versiones sin esta clave (≤0.1.3) es justo quien necesita el repair.
        // La clave se persiste tras reparar, no antes: si la app muere en la
        // ventana de 2 s, el próximo arranque lo reintenta.
        if previous != current, helper.state == .enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.helper.repair()
                UserDefaults.standard.set(current, forKey: "lastRunVersion")
            }
        } else {
            UserDefaults.standard.set(current, forKey: "lastRunVersion")
        }
    }

    private let prompt = "Omnimount necesita permisos de administrador para acceder al disco."

    private var cliPath: String? { ToolLocator.find(.omnimountCLI) }

    var isCLIInstalled: Bool { cliPath != nil }

    func mount(_ partition: DiskPartition, completion: @escaping () -> Void) {
        if helper.state == .enabled {
            runViaHelper(partition: partition, verb: "mount", completion: completion)
        } else {
            runPrivileged(partition: partition, verb: "mount", completion: completion)
        }
    }

    func unmount(_ partition: DiskPartition, completion: @escaping () -> Void) {
        if helper.state == .enabled {
            runViaHelper(partition: partition, verb: "unmount", completion: completion)
        } else {
            runPrivileged(partition: partition, verb: "unmount", completion: completion)
        }
    }

    /// Partición para la que la interfaz está mostrando el diálogo de formateo.
    @Published var formatTarget: DiskPartition?
    @Published var lastFormatSummary: String?

    /// Formatea vía helper. La vista DEBE haber confirmado antes con el usuario.
    func format(_ partition: DiskPartition, as filesystem: String, label: String,
                completion: @escaping () -> Void) {
        guard helper.state == .enabled else {
            lastMessage = L10n.t("Formatear desde la app requiere el helper activo. Alternativa: sudo omnimount format.", "Formatting from the app requires the helper. Alternative: sudo omnimount format.")
            completion()
            return
        }
        busyPartitions.insert(partition.deviceIdentifier)
        helper.format(deviceIdentifier: partition.deviceIdentifier,
                      filesystem: filesystem, label: label) { [weak self] ok, message in
            guard let self else { return }
            self.busyPartitions.remove(partition.deviceIdentifier)
            if ok {
                self.lastMessage = nil
                self.lastFormatSummary = message
                self.monitor?.forgetOmnimountMount(deviceIdentifier: partition.deviceIdentifier)
            } else {
                self.lastMessage = message
            }
            completion()
        }
    }

    private func runViaHelper(partition: DiskPartition, verb: String,
                              completion: @escaping () -> Void) {
        busyPartitions.insert(partition.deviceIdentifier)
        let handle: (Bool, String) -> Void = { [weak self] ok, message in
            guard let self else { return }
            self.busyPartitions.remove(partition.deviceIdentifier)
            if ok {
                self.lastMessage = nil
                if verb == "mount", message.hasPrefix("/") {
                    self.monitor?.recordOmnimountMount(
                        deviceIdentifier: partition.deviceIdentifier, mountPoint: message)
                    NSWorkspace.shared.open(URL(fileURLWithPath: message))
                } else if verb == "unmount" {
                    self.monitor?.forgetOmnimountMount(deviceIdentifier: partition.deviceIdentifier)
                }
            } else {
                self.lastMessage = message
            }
            completion()
        }
        if verb == "mount" {
            helper.mount(deviceIdentifier: partition.deviceIdentifier, completion: handle)
        } else {
            helper.unmount(target: partition.deviceIdentifier, completion: handle)
        }
    }

    private func runPrivileged(partition: DiskPartition, verb: String,
                               completion: @escaping () -> Void) {
        guard let cli = cliPath else {
            lastMessage = L10n.t("No se encontró el CLI `omnimount`. Instálalo con `make install` (ver README).", "The `omnimount` CLI was not found. Install it with `make install` (see README).")
            return
        }
        busyPartitions.insert(partition.deviceIdentifier)
        let command = "\(cli) \(verb) \(partition.deviceIdentifier)"
        let prompt = self.prompt

        Task.detached {
            let result: Result<ShellResult, Error> = Result {
                try ShellRunner.runPrivileged(command, prompt: prompt)
            }
            await MainActor.run {
                self.busyPartitions.remove(partition.deviceIdentifier)
                switch result {
                case .success(let shell) where shell.succeeded:
                    self.lastMessage = nil
                    if verb == "mount",
                       let mountPoint = shell.stdout
                           .split(separator: "\n").last.map(String.init),
                       mountPoint.hasPrefix("/") {
                        self.monitor?.recordOmnimountMount(
                            deviceIdentifier: partition.deviceIdentifier, mountPoint: mountPoint)
                        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
                    } else if verb == "unmount" {
                        self.monitor?.forgetOmnimountMount(deviceIdentifier: partition.deviceIdentifier)
                    }
                case .success(let shell):
                    // osascript devuelve -128 si el usuario cancela el diálogo.
                    if shell.stderr.contains("-128") {
                        self.lastMessage = nil
                    } else {
                        self.lastMessage = shell.stderr.isEmpty ? shell.stdout : shell.stderr
                    }
                case .failure(let error):
                    self.lastMessage = error.localizedDescription
                }
                completion()
            }
        }
    }

    func revealInFinder(_ mountPoint: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }
}
