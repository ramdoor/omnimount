import Foundation
import Security

/// ¿Aceptará el helper las conexiones de esta app?
///
/// Entre otros requisitos, el helper exige que el cliente esté firmado con
/// su mismo Team ID, y si él mismo no tiene Team ID (build firmada ad-hoc)
/// rechaza a todos. Cuando rechaza, la app solo ve una conexión invalidada,
/// igual que con un helper que no arranca. Esta comprobación local cubre
/// únicamente la parte del Team ID, para explicar ese caso en vez de
/// ofrecer reparaciones que no lo resuelven.
///
/// Solo se informa de un rechazo cuando la firma se ha podido leer y la
/// causa es inequívoca; cualquier otro error o situación indeterminada da
/// `.unknown`, que no cambia el comportamiento de la app.
enum HelperTrust: Equatable {
    case trusted
    /// El helper está firmado sin Team ID (p. ej. ad-hoc): rechaza a todos.
    case helperHasNoTeamID
    /// La app no satisface el requisito de Team ID del helper.
    case clientRejected(team: String)
    case unknown

    var rejectsThisApp: Bool {
        switch self {
        case .helperHasNoTeamID, .clientRejected: return true
        case .trusted, .unknown: return false
        }
    }
}

enum SigningCheck {
    static func helperTrust(bundle: Bundle = .main) -> HelperTrust {
        let helperURL = bundle.bundleURL.appendingPathComponent("Contents/MacOS/OmnimountHelper")
        // Fuera de un .app (p. ej. `swift run`) no hay helper que comprobar.
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return .unknown }

        var helperCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helperURL as CFURL, [], &helperCode) == errSecSuccess,
              let helperCode else { return .unknown }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(helperCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any],
              // Sin identificador el binario no está firmado o la lectura no
              // es fiable: no concluir nada.
              dict[kSecCodeInfoIdentifier as String] != nil else { return .unknown }

        guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return .helperHasNoTeamID
        }

        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return .unknown }
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let requirement else { return .unknown }
        switch SecCodeCheckValidity(selfCode, [], requirement) {
        case errSecSuccess:
            return .trusted
        case errSecCSReqFailed:
            // Firma válida pero de otro equipo (o sin certificado de Apple).
            return .clientRejected(team: team)
        default:
            return .unknown
        }
    }
}
