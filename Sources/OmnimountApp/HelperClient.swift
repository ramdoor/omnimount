import Foundation
import ServiceManagement
import OmnimountKit

/// Gestiona el registro del daemon privilegiado (SMAppService) y las
/// llamadas XPC hacia él.
@MainActor
final class HelperClient: ObservableObject {

    enum HelperState: Equatable {
        case enabled              // registrado y aprobado: sin contraseñas
        case requiresApproval     // registrado, falta aprobarlo en Ajustes
        case notRegistered        // aún no instalado
        case unavailable(String)  // p. ej. app fuera de /Applications
    }

    @Published var state: HelperState = .notRegistered

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.plistName)
    }

    init() { refreshState() }

    func refreshState() {
        switch service.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered, .notFound: state = .notRegistered
        @unknown default: state = .notRegistered
        }
    }

    /// Registra el daemon. Si macOS exige aprobación, abre el panel de
    /// Elementos de inicio para que el usuario lo active.
    func install() {
        do {
            try service.register()
            refreshState()
            if state == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let ns = error as NSError
            if ns.code == 1 { // kSMErrorAlreadyRegistered
                refreshState()
                return
            }
            state = .unavailable(error.localizedDescription)
        }
    }

    func uninstall() {
        try? service.unregister()
        refreshState()
    }

    // MARK: - XPC

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OmnimountHelperProtocol.self)
        connection.resume()
        return connection
    }

    /// Ejecuta una operación contra el helper con timeout y limpieza de la
    /// conexión. El bloque recibe el proxy y un `finish` que debe llamar.
    private func withHelper(timeout: TimeInterval = 60,
                            _ body: @escaping (OmnimountHelperProtocol,
                                               @escaping (Bool, String) -> Void) -> Void,
                            completion: @escaping (Bool, String) -> Void) {
        let connection = makeConnection()
        var finished = false

        func finish(_ ok: Bool, _ message: String) {
            guard !finished else { return }
            finished = true
            connection.invalidate()
            DispatchQueue.main.async { completion(ok, message) }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(false, L10n.t("El helper no responde: \(error.localizedDescription)", "The helper is not responding: \(error.localizedDescription)"))
        }) as? OmnimountHelperProtocol else {
            finish(false, L10n.t("No se pudo crear el proxy XPC.", "Could not create the XPC proxy."))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(false, L10n.t("El helper no respondió a tiempo.", "The helper did not respond in time."))
        }
        body(proxy) { ok, message in finish(ok, message) }
    }

    func mount(deviceIdentifier: String,
               completion: @escaping (Bool, String) -> Void) {
        withHelper({ proxy, finish in
            proxy.mount(deviceIdentifier: deviceIdentifier, readOnly: false, reply: finish)
        }, completion: completion)
    }

    func unmount(target: String,
                 completion: @escaping (Bool, String) -> Void) {
        withHelper({ proxy, finish in
            proxy.unmount(target: target, reply: finish)
        }, completion: completion)
    }

    func format(deviceIdentifier: String, filesystem: String, label: String,
                completion: @escaping (Bool, String) -> Void) {
        // Formatear puede tardar (mkntfs en particiones grandes): timeout amplio.
        withHelper(timeout: 600, { proxy, finish in
            proxy.format(deviceIdentifier: deviceIdentifier,
                         filesystem: filesystem, label: label, reply: finish)
        }, completion: completion)
    }

    /// Autotest de Acceso total al disco del helper.
    /// completion(alcanzable, tieneFDA)
    func checkFullDiskAccess(completion: @escaping (Bool, Bool) -> Void) {
        withHelper(timeout: 10, { proxy, finish in
            proxy.checkFullDiskAccess { hasAccess in
                finish(true, hasAccess ? "1" : "0")
            }
        }, completion: { reachable, payload in
            completion(reachable, payload == "1")
        })
    }
}
