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

    /// El helper sin contraseña usa SMAppService, que es de macOS 13+. En
    /// macOS 12 no está disponible: la app recurre al montaje con diálogo de
    /// administrador (MountController.runPrivileged) y el CLI para el resto.
    @available(macOS 13.0, *)
    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.plistName)
    }

    /// Resultado de comprobar la firma de la app frente a la del helper.
    let trust: HelperTrust = SigningCheck.helperTrust()

    /// true si el helper va a rechazar esta app por su firma (build sin Team
    /// ID, p. ej. ad-hoc). Registrar o reparar el helper no lo resuelve.
    var isRejectedBySigning: Bool { trust.rejectsThisApp }

    init() { refreshState() }

    func refreshState() {
        guard #available(macOS 13.0, *) else {
            state = .unavailable(L10n.t("error.helper.needsMacOS13"))
            return
        }
        // El helper rechazaría todas las conexiones: tratarlo como no
        // disponible para que montar/expulsar usen el diálogo de administrador.
        if isRejectedBySigning {
            state = .unavailable(L10n.t("error.helper.signingRejected"))
            return
        }
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
        guard #available(macOS 13.0, *), !isRejectedBySigning else { refreshState(); return }
        do {
            try service.register()
            refreshState()
            if state == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            // register() también falla cuando el servicio ya estaba
            // registrado (kSMErrorAlreadyRegistered) o cuando falta la
            // aprobación del usuario (kSMErrorLaunchDeniedByUser). Decidir por
            // el estado real del servicio, no por el código: si espera
            // aprobación, abrir Elementos de inicio como en el caso de éxito;
            // si ya está activo, no hay nada que hacer.
            refreshState()
            switch state {
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .enabled:
                return
            default:
                state = .unavailable(error.localizedDescription)
            }
        }
    }

    func uninstall() {
        guard #available(macOS 13.0, *) else { return }
        try? service.unregister()
        refreshState()
    }

    /// Repara un helper que launchd rechaza arrancar (EX_CONFIG por "LWCR"):
    /// al actualizar la app, la huella de firma que guardó el registro deja de
    /// coincidir con el binario nuevo. Des-registrar y volver a registrar la
    /// refresca.
    func repair() {
        guard #available(macOS 13.0, *), !isRejectedBySigning else { return }
        try? service.unregister()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.install()
        }
    }

    // MARK: - XPC

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OmnimountHelperProtocol.self)
        connection.resume()
        return connection
    }

    /// Ejecuta una operación contra el helper y cierra la conexión al acabar.
    /// El bloque recibe el proxy y un `finish` que debe llamar. `completion`
    /// se ejecuta una sola vez, en el hilo principal.
    ///
    /// `timeout` nil = sin límite en el cliente: solo para las operaciones
    /// que modifican un disco, y siempre a través de `withReachableHelper`.
    /// El helper no cancela una operación cuando el cliente se va, así que
    /// dar por fallida una operación que sigue en curso liberaría el disco en
    /// la interfaz mientras el helper aún lo usa. Esas operaciones terminan
    /// con la respuesta del helper o con el manejador de error de la conexión
    /// (helper que se cae durante la operación).
    private func withHelper(timeout: TimeInterval?,
                            _ body: @escaping (OmnimountHelperProtocol,
                                               @escaping (Bool, String) -> Void) -> Void,
                            completion: @escaping (Bool, String) -> Void) {
        let connection = makeConnection()
        let once = OneShot<(Bool, String)> { result in
            connection.invalidate()
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
        let finish: (Bool, String) -> Void = { ok, message in once.fire((ok, message)) }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(false, L10n.t("error.helper.notResponding", error.localizedDescription))
        }) as? OmnimountHelperProtocol else {
            finish(false, L10n.t("error.helper.noProxy"))
            return
        }

        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(false, L10n.t("error.helper.timeout"))
            }
        }
        body(proxy, finish)
    }

    /// Para las operaciones que modifican un disco: antes de enviarlas,
    /// comprueba en una conexión aparte que el helper responde (`version()`,
    /// límite de 10 s). Si launchd no consigue arrancar el helper (p. ej.
    /// registro obsoleto tras actualizar la app), el mensaje queda en cola
    /// sin que llegue ningún error a la conexión; como en ese caso no se ha
    /// enviado nada, se informa del fallo y el disco queda libre. Si
    /// responde, la operación se envía sin límite de tiempo en el cliente.
    /// Una versión de protocolo distinta no impide la operación (la informa
    /// la comprobación de Configuración).
    private func withReachableHelper(_ body: @escaping (OmnimountHelperProtocol,
                                                        @escaping (Bool, String) -> Void) -> Void,
                                     completion: @escaping (Bool, String) -> Void) {
        withHelper(timeout: 10, { proxy, finish in
            proxy.version { version in finish(true, version) }
        }, completion: { ok, message in
            guard ok else { completion(false, message); return }
            self.withHelper(timeout: nil, body, completion: completion)
        })
    }

    func mount(deviceIdentifier: String,
               completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.mount(deviceIdentifier: deviceIdentifier, readOnly: false, reply: finish)
        }, completion: completion)
    }

    func unmount(target: String,
                 completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.unmount(target: target, reply: finish)
        }, completion: completion)
    }

    func format(deviceIdentifier: String, filesystem: String, label: String,
                completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.format(deviceIdentifier: deviceIdentifier,
                         filesystem: filesystem, label: label, reply: finish)
        }, completion: completion)
    }

    /// Clona disco/partición a imagen.
    func clone(deviceIdentifier: String, imagePath: String,
               completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.clone(deviceIdentifier: deviceIdentifier, imagePath: imagePath, reply: finish)
        }, completion: completion)
    }

    /// Restaura una imagen sobre disco/partición. El llamante confirma antes.
    func restore(imagePath: String, deviceIdentifier: String,
                 completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.restore(imagePath: imagePath, deviceIdentifier: deviceIdentifier, reply: finish)
        }, completion: completion)
    }

    /// Vuelve escribible un NTFS que Windows dejó en solo lectura.
    func makeWritable(deviceIdentifier: String, completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.makeWritable(deviceIdentifier: deviceIdentifier, reply: finish)
        }, completion: completion)
    }

    /// Desactiva las cuotas ext4 internas de una partición (tune2fs + e2fsck).
    func fixQuota(deviceIdentifier: String, completion: @escaping (Bool, String) -> Void) {
        withReachableHelper({ proxy, finish in
            proxy.fixQuota(deviceIdentifier: deviceIdentifier, reply: finish)
        }, completion: completion)
    }

    enum Probe: Equatable {
        /// Responde con la versión de protocolo esperada.
        case ok(hasFullDiskAccess: Bool)
        /// Responde, pero con otra versión de protocolo (sigue en marcha un
        /// helper antiguo).
        case outdated(helperVersion: String)
        /// No responde; lleva el texto del error.
        case unreachable(String)
    }

    /// Comprueba que el helper responde (`version()`, el saludo previsto en
    /// el protocolo) y, si es así, su Acceso total al disco.
    func probe(completion: @escaping (Probe) -> Void) {
        withHelper(timeout: 10, { proxy, finish in
            proxy.version { version in finish(true, version) }
        }, completion: { [weak self] ok, payload in
            guard let self else { return }
            guard ok else { completion(.unreachable(payload)); return }
            guard payload == HelperConstants.protocolVersion else {
                completion(.outdated(helperVersion: payload)); return
            }
            self.withHelper(timeout: 10, { proxy, finish in
                proxy.checkFullDiskAccess { hasAccess in
                    finish(true, hasAccess ? "1" : "0")
                }
            }, completion: { ok, payload in
                completion(ok ? .ok(hasFullDiskAccess: payload == "1") : .unreachable(payload))
            })
        })
    }
}
