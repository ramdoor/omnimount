import AppKit
import Foundation
import SwiftUI
import OmnimountKit

/// Ejecuta las operaciones privilegiadas (montar/desmontar) relanzando el CLI
/// `omnimount` con el diálogo de administrador de macOS. La app no lleva
/// lógica de montaje propia: un único código, el del CLI.
@MainActor
final class MountController: ObservableObject {

    @Published var busyPartitions: Set<String> = []
    @Published var lastMessage: String?
    /// Partición cuyo montaje falló por cuotas ext4 internas: la UI ofrece
    /// desactivarlas con un clic (vía helper).
    @Published var quotaFixTarget: DiskPartition?

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

    /// Operación de clonado/restauración en curso (nil = ninguna).
    @Published var cloneLabel: String?
    /// Progreso 0…1 del clonado (nil con cloneLabel activo = indeterminado).
    @Published var cloneProgress: Double?
    private var cloneTimer: Timer?

    /// Clona un disco o partición a un .img elegido con NSSavePanel.
    func cloneToImage(identifier: String, suggestedName: String, totalBytes: Int64,
                      completion: @escaping () -> Void) {
        guard helper.state == .enabled else {
            lastMessage = L10n.t("Clonar desde la app requiere el helper activo. Alternativa: sudo omnimount clone \(identifier) imagen.img", "Cloning from the app requires the helper. Alternative: sudo omnimount clone \(identifier) image.img")
            completion(); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".img"
        panel.title = L10n.t("Guardar imagen del disco", "Save disk image")
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { completion(); return }

        cloneLabel = L10n.t("Clonando \(identifier) → \(url.lastPathComponent)…", "Cloning \(identifier) → \(url.lastPathComponent)…")
        cloneProgress = 0
        let path = url.path
        cloneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, totalBytes > 0 else { return }
            let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            Task { @MainActor in self.cloneProgress = min(1, Double(written) / Double(totalBytes)) }
        }
        helper.clone(deviceIdentifier: identifier, imagePath: path) { [weak self] ok, message in
            guard let self else { return }
            self.cloneTimer?.invalidate(); self.cloneTimer = nil
            self.cloneLabel = nil; self.cloneProgress = nil
            self.lastFormatSummary = ok ? L10n.t("Imagen guardada en \(message)", "Image saved to \(message)") : nil
            self.lastMessage = ok ? nil : message
            completion()
        }
    }

    /// Restaura un .img sobre un disco o partición, con confirmación destructiva.
    func restoreImage(identifier: String, displayName: String, completion: @escaping () -> Void) {
        guard helper.state == .enabled else {
            lastMessage = L10n.t("Restaurar desde la app requiere el helper activo. Alternativa: sudo omnimount restore imagen.img \(identifier)", "Restoring from the app requires the helper. Alternative: sudo omnimount restore image.img \(identifier)")
            completion(); return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.t("Elegir imagen a restaurar", "Choose image to restore")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { completion(); return }

        let alert = NSAlert()
        alert.messageText = L10n.t("¿Restaurar sobre \(displayName)?", "Restore over \(displayName)?")
        alert.informativeText = L10n.t("Se sobrescribirá TODO el contenido de \(identifier) con \(url.lastPathComponent). Esta operación no se puede deshacer.", "ALL contents of \(identifier) will be overwritten with \(url.lastPathComponent). This cannot be undone.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.t("Restaurar", "Restore"))
        alert.addButton(withTitle: L10n.t("Cancelar", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { completion(); return }

        cloneLabel = L10n.t("Restaurando \(url.lastPathComponent) → \(identifier)…", "Restoring \(url.lastPathComponent) → \(identifier)…")
        cloneProgress = nil
        helper.restore(imagePath: url.path, deviceIdentifier: identifier) { [weak self] ok, message in
            guard let self else { return }
            self.cloneLabel = nil
            self.lastFormatSummary = ok ? L10n.t("Imagen restaurada en \(message)", "Image restored to \(message)") : nil
            self.lastMessage = ok ? nil : message
            completion()
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
                if verb == "mount" {
                    // El helper antepone "RO:" al punto de montaje si el NTFS
                    // quedó en solo lectura (Windows lo dejó "sucio").
                    let readOnly = message.hasPrefix("RO:")
                    let mp = readOnly ? String(message.dropFirst(3)) : message
                    if mp.hasPrefix("/") {
                        self.monitor?.recordOmnimountMount(
                            deviceIdentifier: partition.deviceIdentifier, mountPoint: mp)
                        if readOnly {
                            self.readOnlyPartitions.insert(partition.deviceIdentifier)
                        } else {
                            self.readOnlyPartitions.remove(partition.deviceIdentifier)
                        }
                        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
                    }
                } else if verb == "unmount" {
                    self.monitor?.forgetOmnimountMount(deviceIdentifier: partition.deviceIdentifier)
                    self.readOnlyPartitions.remove(partition.deviceIdentifier)
                }
            } else {
                self.lastMessage = message
                // El mensaje de MountError.ext4QuotaUnsupported cita tune2fs en
                // ambos idiomas: es el marcador de "arreglable con un clic".
                if verb == "mount", message.contains("tune2fs") {
                    self.quotaFixTarget = partition
                }
            }
            completion()
        }
        if verb == "mount" {
            helper.mount(deviceIdentifier: partition.deviceIdentifier, completion: handle)
        } else {
            helper.unmount(target: partition.deviceIdentifier, completion: handle)
        }
    }

    /// Particiones montadas en solo lectura (NTFS que Windows dejó "sucio").
    @Published var readOnlyPartitions: Set<String> = []

    /// Vuelve escribible un NTFS en solo lectura (helper: ntfsfix + remount con
    /// remove_hiberfile), tras confirmar con el usuario.
    func makeWritable(_ partition: DiskPartition, completion: @escaping () -> Void) {
        guard helper.state == .enabled else {
            lastMessage = L10n.t(
                "Hacerlo escribible requiere el helper activo.",
                "Making it writable requires the helper enabled.")
            completion(); return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t(
            "¿Hacer escribible \(partition.volumeName ?? partition.deviceIdentifier)?",
            "Make \(partition.volumeName ?? partition.deviceIdentifier) writable?")
        alert.informativeText = L10n.t(
            "Windows dejó este disco NTFS en solo lectura (Inicio rápido/hibernación o desconexión sin expulsar). Se limpiará ese estado para poder escribir. Tus ficheros no se tocan; solo se descarta una sesión de Windows en suspensión, si la hubiera.",
            "Windows left this NTFS disk read-only (Fast Startup/hibernation, or unplugged without ejecting). That state will be cleared so you can write. Your files are untouched; only a suspended Windows session, if any, is discarded.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("Hacer escribible", "Make writable"))
        alert.addButton(withTitle: L10n.t("Cancelar", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { completion(); return }

        busyPartitions.insert(partition.deviceIdentifier)
        helper.makeWritable(deviceIdentifier: partition.deviceIdentifier) { [weak self] ok, message in
            guard let self else { return }
            self.busyPartitions.remove(partition.deviceIdentifier)
            if ok {
                self.lastMessage = nil
                self.readOnlyPartitions.remove(partition.deviceIdentifier)
                let stillReadOnly = message.hasPrefix("RO:")
                let mp = stillReadOnly ? String(message.dropFirst(3)) : message
                if mp.hasPrefix("/") {
                    self.monitor?.recordOmnimountMount(
                        deviceIdentifier: partition.deviceIdentifier, mountPoint: mp)
                    if stillReadOnly {
                        // Siguió en solo lectura: el daño necesita chkdsk en Windows.
                        self.readOnlyPartitions.insert(partition.deviceIdentifier)
                        self.lastMessage = L10n.t(
                            "No se pudo hacer escribible; el disco necesita repararse en Windows (chkdsk).",
                            "Could not make it writable; the disk needs repair on Windows (chkdsk).")
                    }
                }
            } else {
                self.lastMessage = message
            }
            completion()
        }
    }

    /// Desactiva las cuotas ext4 de la partición (helper) y reintenta el montaje.
    func fixQuotaAndMount(_ partition: DiskPartition, completion: @escaping () -> Void) {
        quotaFixTarget = nil
        guard helper.state == .enabled else {
            lastMessage = L10n.t(
                "Para el arreglo con un clic activa el helper; o ejecuta: sudo omnimount mount \(partition.deviceIdentifier) --fix-quota",
                "One-click fix needs the helper enabled; or run: sudo omnimount mount \(partition.deviceIdentifier) --fix-quota")
            completion()
            return
        }
        busyPartitions.insert(partition.deviceIdentifier)
        helper.fixQuota(deviceIdentifier: partition.deviceIdentifier) { [weak self] ok, message in
            guard let self else { return }
            self.busyPartitions.remove(partition.deviceIdentifier)
            if ok {
                self.lastMessage = nil
                self.mount(partition, completion: completion)
            } else {
                self.lastMessage = message
                completion()
            }
        }
    }

    private func runPrivileged(partition: DiskPartition, verb: String,
                               completion: @escaping () -> Void) {
        guard let cli = cliPath else {
            lastMessage = L10n.t("No se encontró el CLI `omnimount`. Instálalo con `make install` (ver README).", "The `omnimount` CLI was not found. Install it with `make install` (see README).")
            return
        }
        busyPartitions.insert(partition.deviceIdentifier)
        // Fijar el directorio de herramientas del bundle: aunque `cli` fuera un
        // omnimount ajeno del PATH, encontrará el fuse2fs embebido.
        let toolDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS").path
        let command = "OMNIMOUNT_TOOL_DIR=\(toolDir) \(cli) \(verb) \(partition.deviceIdentifier)"
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
        let newWindow = UserDefaults.standard.bool(forKey: "openInNewFinderWindow")
        if newWindow {
            // Forzar una ventana nueva del Finder (para comparar discos en
            // paralelo). NSWorkspace reutiliza la ventana existente; Finder vía
            // AppleScript sí abre una nueva.
            let script = "tell application \"Finder\"\nmake new Finder window to (POSIX file \"\(mountPoint)\")\nactivate\nend tell"
            DispatchQueue.global().async {
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
        }
    }
}

/// Tamaño del texto del panel del menú, ajustable por el usuario.
enum MenuTextSize: String, CaseIterable, Identifiable {
    case normal, grande, muyGrande
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return L10n.t("Normal", "Normal")
        case .grande: return L10n.t("Grande", "Large")
        case .muyGrande: return L10n.t("Muy grande", "Extra large")
        }
    }
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .normal: return .medium
        case .grande: return .large
        case .muyGrande: return .xxLarge
        }
    }
}
