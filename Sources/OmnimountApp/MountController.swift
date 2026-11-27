import AppKit
import Foundation
import SwiftUI
import OmnimountKit

/// Ejecuta las operaciones privilegiadas (montar/desmontar) relanzando el CLI
/// `omnimount` con el diálogo de administrador de macOS. La app no lleva
/// lógica de montaje propia: un único código, el del CLI.
@MainActor
final class MountController: ObservableObject {

    /// Operaciones en curso por disco entero: mientras una trabaja sobre un
    /// disco o una de sus particiones, la interfaz desactiva el resto de
    /// acciones de ese disco.
    @Published private(set) var busy = DiskBusyRegistry()
    @Published var lastMessage: String?

    /// true mientras quede alguna operación en curso.
    var hasActiveOperations: Bool { !busy.isEmpty }

    /// Registra una operación sobre `target`. Si su disco ya está ocupado no
    /// la registra, deja el aviso en `lastMessage` y devuelve false.
    private func beginOperation(on target: String, wholeDisk: String) -> Bool {
        guard busy.begin(target: target, wholeDisk: wholeDisk) else {
            lastMessage = L10n.t("app.alert.diskBusy", wholeDisk)
            return false
        }
        return true
    }

    private func endOperation(on target: String) {
        busy.end(target: target)
    }

    /// Comprueba que `expected` sigue apuntando al mismo dispositivo y llama a
    /// `completion` en el hilo principal con el resultado. Sin ID de registro
    /// IOKit hace falta un listado nuevo (diskutil), que se lee fuera del
    /// hilo principal.
    private func verifyIdentity(_ expected: DiskIdentity,
                                completion: @escaping (Bool) -> Void) {
        guard expected.needsFreshListing else {
            completion(expected.matches(in: []))
            return
        }
        Task.detached(priority: .userInitiated) {
            let disks = (try? DiskLister.externalDisks()) ?? []
            await MainActor.run { completion(expected.matches(in: disks)) }
        }
    }
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

    private var prompt: String {
        L10n.t("app.alert.adminPrompt")
    }

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
    /// Solo hay un clonado/restauración a la vez (un único indicador de progreso).
    func cloneToImage(identifier: String, wholeDisk: String, suggestedName: String,
                      totalBytes: Int64, completion: @escaping () -> Void) {
        guard helper.state == .enabled else {
            lastMessage = L10n.t("app.alert.cloneNeedsHelper", identifier)
            completion(); return
        }
        guard cloneLabel == nil, !busy.isDiskBusy(wholeDisk) else {
            lastMessage = L10n.t("app.alert.diskBusy", wholeDisk)
            completion(); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".img"
        panel.title = L10n.t("app.alert.saveImage")
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { completion(); return }
        // El panel es modal: comprobar de nuevo antes de empezar.
        guard cloneLabel == nil, beginOperation(on: identifier, wholeDisk: wholeDisk) else {
            completion(); return
        }

        cloneLabel = L10n.t("app.alert.cloning", identifier, url.lastPathComponent)
        cloneProgress = 0
        let path = url.path
        // El clonado puede escribir primero en "<imagen>.partial" y renombrar
        // al terminar: sondear ese fichero y, si no existe, la ruta final.
        let partialPath = path + ".partial"
        cloneTimer?.invalidate()
        cloneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, totalBytes > 0 else { return }
            let size: (String) -> Int64? = {
                (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int64
            }
            let written = size(partialPath) ?? size(path) ?? 0
            Task { @MainActor in self.cloneProgress = min(1, Double(written) / Double(totalBytes)) }
        }
        helper.clone(deviceIdentifier: identifier, imagePath: path) { [weak self] ok, message in
            guard let self else { return }
            self.endOperation(on: identifier)
            self.cloneTimer?.invalidate(); self.cloneTimer = nil
            self.cloneLabel = nil; self.cloneProgress = nil
            self.lastFormatSummary = ok ? L10n.t("app.alert.imageSaved", message) : nil
            self.lastMessage = ok ? nil : message
            completion()
        }
    }

    /// Restaura un .img sobre un disco o partición, con confirmación destructiva.
    func restoreImage(disk: ExternalDisk, completion: @escaping () -> Void) {
        let identifier = disk.deviceIdentifier
        let displayName = disk.mediaName ?? disk.deviceIdentifier
        // Huella del disco elegido, antes de los diálogos modales.
        let expected = DiskIdentity(disk: disk)
        guard helper.state == .enabled else {
            lastMessage = L10n.t("app.alert.restoreNeedsHelper", identifier)
            completion(); return
        }
        guard cloneLabel == nil, !busy.isDiskBusy(identifier) else {
            lastMessage = L10n.t("app.alert.diskBusy", identifier)
            completion(); return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.t("app.alert.chooseImage")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { completion(); return }

        let alert = NSAlert()
        alert.messageText = L10n.t("app.alert.restoreTitle", displayName)
        alert.informativeText = L10n.t("app.alert.restoreBody", identifier, url.lastPathComponent)
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.t("app.common.restore"))
        alert.addButton(withTitle: L10n.t("app.common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { completion(); return }
        // Panel y alerta son modales: comprobar de nuevo antes de empezar.
        guard cloneLabel == nil, beginOperation(on: identifier, wholeDisk: identifier) else {
            completion(); return
        }
        cloneLabel = L10n.t("app.alert.restoring", url.lastPathComponent, identifier)
        cloneProgress = nil

        verifyIdentity(expected) { [weak self] stillSame in
            guard let self else { return }
            guard stillSame else {
                self.endOperation(on: identifier)
                self.cloneLabel = nil
                self.lastMessage = L10n.t("app.alert.diskChanged", identifier)
                completion()
                return
            }
            self.helper.restore(imagePath: url.path, deviceIdentifier: identifier) { [weak self] ok, message in
                guard let self else { return }
                self.endOperation(on: identifier)
                self.cloneLabel = nil
                self.lastFormatSummary = ok ? L10n.t("app.alert.imageRestored", message) : nil
                self.lastMessage = ok ? nil : message
                completion()
            }
        }
    }

    /// Partición para la que la interfaz está mostrando el diálogo de formateo.
    @Published var formatTarget: DiskPartition?
    @Published var lastFormatSummary: String?

    /// Formatea vía helper. La vista DEBE haber confirmado antes con el usuario.
    /// `expected` es la huella tomada al abrir el diálogo: si el identificador
    /// ya apunta a otro dispositivo, no se formatea.
    func format(_ partition: DiskPartition, as filesystem: String, label: String,
                expected: DiskIdentity, completion: @escaping () -> Void) {
        guard helper.state == .enabled else {
            lastMessage = L10n.t("app.alert.formatNeedsHelper")
            completion()
            return
        }
        let id = partition.deviceIdentifier
        guard beginOperation(on: id, wholeDisk: partition.parentWholeDisk) else {
            completion(); return
        }
        // Único punto de salida: libera el disco y llama a completion una vez.
        var finished = false
        let finish: (_ error: String?, _ summary: String?) -> Void = { [weak self] error, summary in
            guard !finished else { return }
            finished = true
            self?.endOperation(on: id)
            self?.lastMessage = error
            if let summary { self?.lastFormatSummary = summary }
            completion()
        }
        let sendFormat = { [weak self] in
            guard let self else { return }
            self.helper.format(deviceIdentifier: id, filesystem: filesystem,
                               label: label) { [weak self] ok, message in
                if ok { self?.monitor?.forgetOmnimountMount(deviceIdentifier: id) }
                finish(ok ? nil : message, ok ? message : nil)
            }
        }
        verifyIdentity(expected) { [weak self] stillSame in
            guard let self else { return }
            guard stillSame else {
                finish(L10n.t("app.alert.diskChanged", id), nil)
                return
            }
            // Una partición montada (por Omnimount o por macOS) se expulsa
            // antes, por la misma vía que el botón Expulsar: el formateo no
            // desmonta por su cuenta un montaje FUSE-T que solo se localiza
            // por la etiqueta. Si la expulsión falla, no se formatea.
            guard self.currentMountPoint(of: id) != nil else {
                sendFormat()
                return
            }
            self.helper.unmount(target: id) { [weak self] ok, message in
                guard ok else {
                    finish(L10n.t("app.alert.formatEjectFailed", id, message), nil)
                    return
                }
                self?.monitor?.forgetOmnimountMount(deviceIdentifier: id)
                self?.readOnlyPartitions.remove(id)
                sendFormat()
            }
        }
    }

    /// Punto de montaje actual de la partición según el monitor: el
    /// registrado como montaje de Omnimount o, si no, el que informa macOS.
    private func currentMountPoint(of identifier: String) -> String? {
        if let point = monitor?.mountedByOmnimount[identifier] { return point }
        return monitor?.disks.flatMap(\.partitions)
            .first { $0.deviceIdentifier == identifier }?.mountPoint
    }

    private func runViaHelper(partition: DiskPartition, verb: String,
                              completion: @escaping () -> Void) {
        guard beginOperation(on: partition.deviceIdentifier, wholeDisk: partition.parentWholeDisk) else {
            completion(); return
        }
        let handle: (Bool, String) -> Void = { [weak self] ok, message in
            guard let self else { return }
            self.endOperation(on: partition.deviceIdentifier)
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
            lastMessage = L10n.t("app.alert.writableNeedsHelper")
            completion(); return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("app.alert.writableTitle", partition.volumeName ?? partition.deviceIdentifier)
        alert.informativeText = L10n.t("app.alert.writableBody")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("app.common.makeWritable"))
        alert.addButton(withTitle: L10n.t("app.common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { completion(); return }

        guard beginOperation(on: partition.deviceIdentifier, wholeDisk: partition.parentWholeDisk) else {
            completion(); return
        }
        helper.makeWritable(deviceIdentifier: partition.deviceIdentifier) { [weak self] ok, message in
            guard let self else { return }
            self.endOperation(on: partition.deviceIdentifier)
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
                        self.lastMessage = L10n.t("app.alert.writableFailed")
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
            lastMessage = L10n.t("app.alert.quotaNeedsHelper", partition.deviceIdentifier)
            completion()
            return
        }
        guard beginOperation(on: partition.deviceIdentifier, wholeDisk: partition.parentWholeDisk) else {
            completion(); return
        }
        helper.fixQuota(deviceIdentifier: partition.deviceIdentifier) { [weak self] ok, message in
            guard let self else { return }
            self.endOperation(on: partition.deviceIdentifier)
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
            lastMessage = L10n.t("app.alert.cliMissing")
            completion()
            return
        }
        guard beginOperation(on: partition.deviceIdentifier, wholeDisk: partition.parentWholeDisk) else {
            completion(); return
        }
        // Fijar el directorio de herramientas del bundle: aunque `cli` fuera un
        // omnimount ajeno del PATH, encontrará el fuse2fs embebido.
        // Cada pieza va entrecomillada para el shell (la ruta de la app puede
        // contener espacios u otros caracteres); ShellRunner.runPrivileged se
        // encarga del escapado de la cadena AppleScript.
        let toolDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS").path
        let command = ScriptQuoting.shellCommand(
            cli, [verb, partition.deviceIdentifier],
            environment: [("OMNIMOUNT_TOOL_DIR", toolDir)])
        let prompt = self.prompt

        Task.detached {
            let result: Result<ShellResult, Error> = Result {
                try ShellRunner.runPrivileged(command, prompt: prompt)
            }
            await MainActor.run {
                self.endOperation(on: partition.deviceIdentifier)
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
            // El punto de montaje deriva de la etiqueta del volumen: se pasa
            // como literal AppleScript escapado.
            let path = ScriptQuoting.appleScriptStringLiteral(mountPoint)
            let script = "tell application \"Finder\"\nmake new Finder window to (POSIX file \(path))\nactivate\nend tell"
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
        case .normal: return L10n.t("app.textSize.normal")
        case .grande: return L10n.t("app.textSize.large")
        case .muyGrande: return L10n.t("app.textSize.extraLarge")
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
