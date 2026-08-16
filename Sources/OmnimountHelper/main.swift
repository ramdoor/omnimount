import Foundation
import OmnimountKit

/// Daemon privilegiado de Omnimount. Lo registra la app con SMAppService
/// (aprobación única en Ajustes → Elementos de inicio) y corre como root,
/// escuchando peticiones XPC de la app para montar/desmontar sin pedir
/// contraseña cada vez.

/// Implementación de las operaciones. Corre como root, así que usa
/// OmnimountKit directamente — el mismo código que el CLI bajo sudo.
final class HelperService: NSObject, OmnimountHelperProtocol {

    func version(reply: @escaping (String) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    private func partition(for deviceIdentifier: String) throws -> DiskPartition {
        let id = deviceIdentifier.replacingOccurrences(of: "/dev/", with: "")
        guard let part = try DiskLister.externalDisks()
            .flatMap(\.partitions)
            .first(where: { $0.deviceIdentifier == id }) else {
            throw MountError.unmountFailed("No existe la partición externa \(id)")
        }
        return part
    }

    func detect(deviceIdentifier: String,
                reply: @escaping (Bool, String, String?) -> Void) {
        do {
            let part = try partition(for: deviceIdentifier)
            let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
            reply(true, detection.filesystem.displayName, detection.label)
        } catch {
            reply(false, Self.friendlyMessage(error), nil)
        }
    }

    func mount(deviceIdentifier: String, readOnly: Bool,
               reply: @escaping (Bool, String) -> Void) {
        do {
            let part = try partition(for: deviceIdentifier)
            let detection = try FilesystemDetector.detect(devicePath: part.devicePath)
            let result = try Mounter.mount(partition: part, detection: detection,
                                           readOnly: readOnly)
            reply(true, result.mountPoint)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func unmount(target: String, reply: @escaping (Bool, String) -> Void) {
        do {
            let mountPoint: String
            if target.hasPrefix("/") {
                mountPoint = target
            } else {
                let part = try partition(for: target)
                // Orden: diskutil → mount(8) → derivado por etiqueta (FUSE-T).
                guard let current = part.mountPoint
                    ?? Mounter.currentMountPoint(devicePath: part.devicePath)
                    ?? Mounter.derivedMountPoint(partition: part) else {
                    reply(false, "\(target) no está montada.")
                    return
                }
                mountPoint = current
            }
            try Mounter.unmount(mountPoint: mountPoint)
            reply(true, mountPoint)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func format(deviceIdentifier: String, filesystem: String, label: String,
                reply: @escaping (Bool, String) -> Void) {
        guard let target = TargetFormat(rawValue: filesystem) else {
            reply(false, "Formato desconocido: \(filesystem)")
            return
        }
        do {
            let part = try partition(for: deviceIdentifier)
            let summary = try Formatter.format(partition: part, as: target, label: label)
            reply(true, summary)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    /// Errores con guía: el caso estrella es el TCC (Acceso total al disco),
    /// que al helper le toca pedir por su cuenta la primera vez.
    private static func friendlyMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if error is DetectionError {
            return message + " Si el helper está activo, concede Acceso total al disco a OmnimountHelper en Ajustes → Privacidad y seguridad."
        }
        return message
    }
}

/// Acepta solo conexiones de procesos firmados con nuestro mismo Team ID.
enum ClientVerifier {
    static func isTrusted(_ connection: NSXPCConnection) -> Bool {
        // Nota: la verificación por PID tiene una ventana de carrera teórica;
        // la alternativa robusta (audit token) es API privada. Suficiente v1:
        // el atacante necesitaría ya ejecución local con nuestro mismo uid.
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        guard let selfTeam = currentTeamIdentifier(), !selfTeam.isEmpty else {
            // Helper sin firma de equipo (build de desarrollo ad-hoc):
            // no se puede anclar la confianza; rechazar por defecto.
            return false
        }
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(selfTeam)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    /// Team ID con el que está firmado este propio helper.
    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard ClientVerifier.isTrusted(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: OmnimountHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
