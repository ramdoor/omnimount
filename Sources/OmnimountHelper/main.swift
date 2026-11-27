import Foundation
import OmnimountKit
import os
import Security

/// Daemon privilegiado de Omnimount. Lo registra la app con SMAppService
/// (aprobación única en Ajustes → Elementos de inicio) y corre como root,
/// escuchando peticiones XPC de la app para montar/desmontar sin pedir
/// contraseña cada vez.

private let log = Logger(subsystem: "org.omnimount.helper", category: "xpc")

/// Cada conexión XPC tiene su propia cola: las peticiones de conexiones
/// distintas se ejecutan a la vez. Una sola operación por disco entero,
/// compartida por todas las conexiones.
private let diskGate = DiskOperationGate()

/// Cuenta las peticiones atendidas en una conexión (solo para el registro).
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func note() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }
}

/// Implementación de las operaciones. Corre como root, así que usa
/// OmnimountKit directamente — el mismo código que el CLI bajo sudo. Hay un
/// objeto por conexión: `caller` es el usuario del proceso que se conectó,
/// en cuyo nombre se crean y leen las imágenes.
final class HelperService: NSObject, OmnimountHelperProtocol {
    private let caller: ImageOwner
    private let requests: RequestCounter

    init(caller: ImageOwner, requests: RequestCounter) {
        self.caller = caller
        self.requests = requests
    }

    func version(reply: @escaping (String) -> Void) {
        requests.note()
        reply(HelperConstants.protocolVersion)
    }

    /// Identificador recibido del cliente en su forma única (sin "/dev/"
    /// inicial, disk<N>(s<N>)*): el mismo valor va a la reserva del disco y a
    /// la operación.
    private static func normalized(_ identifier: String) throws -> String {
        guard let id = DiskOperationGate.normalizedIdentifier(identifier) else {
            throw DiskOperationError.invalidIdentifier(identifier)
        }
        return id
    }

    /// `id` ya normalizado.
    private func partition(for id: String) throws -> DiskPartition {
        guard let part = try DiskLister.externalDisks()
            .flatMap(\.partitions)
            .first(where: { $0.deviceIdentifier == id }) else {
            throw MountError.unmountFailed(L10n.t("error.helper.missingPartition", id))
        }
        return part
    }

    func detect(deviceIdentifier: String,
                reply: @escaping (Bool, String, String?) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(deviceIdentifier)
            let part = try partition(for: id)
            let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
            reply(true, detection.filesystem.displayName, detection.label)
        } catch {
            reply(false, Self.friendlyMessage(error), nil)
        }
    }

    func mount(deviceIdentifier: String, readOnly: Bool,
               reply: @escaping (Bool, String) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(deviceIdentifier)
            let result = try diskGate.run(on: id) {
                let part = try partition(for: id)
                let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
                return try Mounter.mount(partition: part, detection: detection, readOnly: readOnly)
            }
            reply(true, (result.readOnly ? "RO:" : "") + result.mountPoint)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    /// Solo por identificador de una partición externa: el punto de montaje
    /// se obtiene del propio disco.
    func unmount(target: String, reply: @escaping (Bool, String) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(target)
            let unmounted: String? = try diskGate.run(on: id) {
                let part = try partition(for: id)
                // Orden: diskutil → mount(8) → derivado por etiqueta (FUSE-T).
                guard let current = part.mountPoint
                    ?? Mounter.currentMountPoint(devicePath: part.devicePath)
                    ?? Mounter.derivedMountPoint(partition: part) else {
                    return nil
                }
                try Mounter.unmount(mountPoint: current)
                return current
            }
            guard let unmounted else {
                reply(false, L10n.t("error.unmount.notMounted", id))
                return
            }
            reply(true, unmounted)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func clone(deviceIdentifier: String, imagePath: String,
               reply: @escaping (Bool, String) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(deviceIdentifier)
            // La imagen se crea en nombre del usuario que lo pide y queda a su nombre.
            try diskGate.run(on: id) {
                try Cloner.clone(wholeDisk: id, to: imagePath, owner: caller, progress: { _ in })
            }
            reply(true, imagePath)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func restore(imagePath: String, deviceIdentifier: String,
                 reply: @escaping (Bool, String) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(deviceIdentifier)
            // La imagen debe poder leerla el propio usuario que lo pide.
            try diskGate.run(on: id) {
                try Cloner.restore(imagePath: imagePath, to: id,
                                   requestedBy: caller, progress: { _ in })
            }
            reply(true, id)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func makeWritable(deviceIdentifier: String,
                      reply: @escaping (Bool, String) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(deviceIdentifier)
            let result = try diskGate.run(on: id) {
                let part = try partition(for: id)
                let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
                return try Mounter.makeNtfsWritable(partition: part, detection: detection)
            }
            reply(true, (result.readOnly ? "RO:" : "") + result.mountPoint)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func fixQuota(deviceIdentifier: String,
                  reply: @escaping (Bool, String) -> Void) {
        requests.note()
        do {
            let id = try Self.normalized(deviceIdentifier)
            let changed = try diskGate.run(on: id) { () -> Bool in
                let part = try partition(for: id)
                let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
                guard detection.extQuotaEnabled else { return false }
                try Mounter.disableExtQuota(devicePath: part.devicePath)
                return true
            }
            reply(true, changed ? "" : L10n.t("error.helper.noQuota"))
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func format(deviceIdentifier: String, filesystem: String, label: String,
                reply: @escaping (Bool, String) -> Void) {
        requests.note()
        guard let target = TargetFormat(rawValue: filesystem) else {
            reply(false, L10n.t("error.format.unknown", filesystem))
            return
        }
        do {
            let id = try Self.normalized(deviceIdentifier)
            let summary = try diskGate.run(on: id) {
                let part = try partition(for: id)
                return try Formatter.format(partition: part, as: target, label: label)
            }
            reply(true, summary)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func checkFullDiskAccess(reply: @escaping (Bool) -> Void) {
        requests.note()
        // La base de datos TCC del sistema solo es legible con Acceso total
        // al disco: el intento de lectura es el autotest perfecto (incluso
        // siendo root).
        let probe = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        defer { try? probe?.close() }
        reply(probe != nil)
    }

    /// Errores con guía: el caso estrella es el TCC (Acceso total al disco),
    /// que al helper le toca pedir por su cuenta la primera vez.
    private static func friendlyMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if error is DetectionError {
            return message + " " + L10n.t("error.helper.fda")
        }
        return message
    }
}

/// Clientes aceptados: la app y el cliente de pruebas de integración,
/// firmados con el mismo Team ID que este helper (HelperClientRequirement).
/// El sistema aplica el requisito a cada mensaje con el audit token del
/// cliente (setCodeSigningRequirement); la comprobación previa por PID solo
/// sirve para rechazar pronto y registrar el motivo.
enum ClientVerifier {
    /// Team ID con el que está firmado este propio helper.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Texto del requisito y su versión compilada. nil sin Team ID válido:
    /// entonces no se acepta ninguna conexión.
    static let requirement: (text: String, compiled: SecRequirement)? = {
        guard let text = HelperClientRequirement.clientRequirement(teamIdentifier: teamIdentifier) else {
            return nil
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return nil }
        return (text, compiled)
    }()

    /// nil si el proceso con ese PID cumple el requisito; si no, el motivo.
    static func refusalReason(pid: pid_t, requirement: SecRequirement) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard lookup == errSecSuccess, let code else {
            return "cannot read the client's code signature (OSStatus \(lookup))"
        }
        let status = SecCodeCheckValidity(code, [], requirement)
        guard status != errSecSuccess else { return nil }
        return "client \(signingSummary(code)) does not satisfy the requirement (OSStatus \(status))"
    }

    /// "identificador (team)" del cliente, para el registro.
    private static func signingSummary(_ code: SecCode) -> String {
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "with an unreadable signature" }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? "unsigned"
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String ?? "no Team ID"
        return "\(identifier) (\(team))"
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let pid = newConnection.processIdentifier
        let uid = newConnection.effectiveUserIdentifier
        guard let requirement = ClientVerifier.requirement else {
            log.error("Refusing connection from pid \(pid, privacy: .public): this helper has no Team ID (ad-hoc signature), so no client can be verified. Sign the app with a Developer ID or Apple Development identity.")
            return false
        }
        if let reason = ClientVerifier.refusalReason(pid: pid, requirement: requirement.compiled) {
            log.error("Refusing connection from pid \(pid, privacy: .public), uid \(uid, privacy: .public): \(reason, privacy: .public)")
            return false
        }
        // Validado antes con SecRequirementCreateWithString: un requisito mal
        // formado lanzaría una excepción de Objective-C.
        newConnection.setCodeSigningRequirement(requirement.text)

        let requests = RequestCounter()
        newConnection.invalidationHandler = {
            guard requests.isEmpty else { return }
            log.info("Connection from pid \(pid, privacy: .public) closed before any request was handled (this includes clients that do not satisfy the code-signing requirement)")
        }
        newConnection.exportedInterface = NSXPCInterface(with: OmnimountHelperProtocol.self)
        newConnection.exportedObject = HelperService(
            caller: ImageOwner(uid: uid, gid: newConnection.effectiveGroupIdentifier),
            requests: requests)
        newConnection.resume()
        return true
    }
}

// Herramientas: solo las del sistema en /sbin y /usr/sbin y las del bundle
// junto a este ejecutable, firmadas con el mismo Team ID.
if ClientVerifier.teamIdentifier == nil {
    log.error("This helper has no Team ID (ad-hoc signature): connections are refused and bundled tools are not used.")
}
if let directory = ToolLocator.TrustedToolPolicy.currentExecutableDirectory() {
    ToolLocator.useTrustedLocations(.init(bundledToolDirectory: directory,
                                          teamIdentifier: ClientVerifier.teamIdentifier))
} else {
    log.error("Cannot determine the helper's executable directory: bundled tools are not used.")
    ToolLocator.useTrustedLocations(.init(bundledToolDirectory: "", teamIdentifier: nil))
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
