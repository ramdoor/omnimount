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

/// Implementación de las operaciones. Corre como root, así que usa
/// OmnimountKit directamente — el mismo código que el CLI bajo sudo. Hay un
/// objeto por conexión: `caller` es el usuario del proceso que se conectó,
/// en cuyo nombre se crean y leen las imágenes.
final class HelperService: NSObject, OmnimountHelperProtocol {
    private let caller: ImageOwner

    init(caller: ImageOwner) {
        self.caller = caller
    }

    func version(reply: @escaping (String) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    private func partition(for deviceIdentifier: String) throws -> DiskPartition {
        let id = deviceIdentifier.replacingOccurrences(of: "/dev/", with: "")
        guard let part = try DiskLister.externalDisks()
            .flatMap(\.partitions)
            .first(where: { $0.deviceIdentifier == id }) else {
            throw MountError.unmountFailed(L10n.t("error.helper.missingPartition", id))
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
            let result = try diskGate.run(on: deviceIdentifier) {
                let part = try partition(for: deviceIdentifier)
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
        do {
            let unmounted: String? = try diskGate.run(on: target) {
                let part = try partition(for: target)
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
                reply(false, L10n.t("error.unmount.notMounted", target))
                return
            }
            reply(true, unmounted)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func clone(deviceIdentifier: String, imagePath: String,
               reply: @escaping (Bool, String) -> Void) {
        do {
            // La imagen se crea en nombre del usuario que lo pide y queda a su nombre.
            try diskGate.run(on: deviceIdentifier) {
                try Cloner.clone(wholeDisk: deviceIdentifier, to: imagePath, owner: caller, progress: { _ in })
            }
            reply(true, imagePath)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func restore(imagePath: String, deviceIdentifier: String,
                 reply: @escaping (Bool, String) -> Void) {
        do {
            // La imagen debe poder leerla el propio usuario que lo pide.
            try diskGate.run(on: deviceIdentifier) {
                try Cloner.restore(imagePath: imagePath, to: deviceIdentifier,
                                   requestedBy: caller, progress: { _ in })
            }
            reply(true, deviceIdentifier)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func makeWritable(deviceIdentifier: String,
                      reply: @escaping (Bool, String) -> Void) {
        do {
            let result = try diskGate.run(on: deviceIdentifier) {
                let part = try partition(for: deviceIdentifier)
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
        do {
            let changed = try diskGate.run(on: deviceIdentifier) { () -> Bool in
                let part = try partition(for: deviceIdentifier)
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
        guard let target = TargetFormat(rawValue: filesystem) else {
            reply(false, L10n.t("error.format.unknown", filesystem))
            return
        }
        do {
            let summary = try diskGate.run(on: deviceIdentifier) {
                let part = try partition(for: deviceIdentifier)
                return try Formatter.format(partition: part, as: target, label: label)
            }
            reply(true, summary)
        } catch {
            reply(false, Self.friendlyMessage(error))
        }
    }

    func checkFullDiskAccess(reply: @escaping (Bool) -> Void) {
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
    static func currentTeamIdentifier() -> String? {
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
        newConnection.exportedObject = HelperService(
            caller: ImageOwner(uid: newConnection.effectiveUserIdentifier,
                               gid: newConnection.effectiveGroupIdentifier))
        newConnection.resume()
        return true
    }
}

// Herramientas: solo las del sistema en /sbin y /usr/sbin y las del bundle
// junto a este ejecutable, firmadas con el mismo Team ID.
if ClientVerifier.currentTeamIdentifier() == nil {
    log.error("This helper has no Team ID (ad-hoc signature): bundled tools are not used.")
}
if let directory = ToolLocator.TrustedToolPolicy.currentExecutableDirectory() {
    ToolLocator.useTrustedLocations(.init(bundledToolDirectory: directory,
                                          teamIdentifier: ClientVerifier.currentTeamIdentifier()))
} else {
    log.error("Cannot determine the helper's executable directory: bundled tools are not used.")
    ToolLocator.useTrustedLocations(.init(bundledToolDirectory: "", teamIdentifier: nil))
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
