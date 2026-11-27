import Foundation

/// Requisitos de firma (lenguaje de requisitos de codesign) que usa el helper.
public enum HelperClientRequirement {

    /// Identificadores de firma de los clientes que pueden conectarse al
    /// helper: la app y el cliente de pruebas de Tests/HelperIntegration
    /// (firmado con `--identifier org.omnimount.helper-integration`).
    public static let allowedIdentifiers = ["org.omnimount.app", "org.omnimount.helper-integration"]

    /// Un Team ID de Apple: diez caracteres en mayúsculas o dígitos. Se
    /// valida antes de interpolarlo en un requisito.
    public static func isValidTeamIdentifier(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        }
    }

    /// Código firmado por Apple para el equipo `teamIdentifier`.
    public static func teamRequirement(teamIdentifier: String?) -> String? {
        guard let team = teamIdentifier, isValidTeamIdentifier(team) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Requisito para los clientes XPC: mismo equipo que el helper y uno de
    /// los identificadores permitidos. nil si el helper no tiene Team ID.
    public static func clientRequirement(teamIdentifier: String?) -> String? {
        guard let base = teamRequirement(teamIdentifier: teamIdentifier) else { return nil }
        let identifiers = allowedIdentifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "\(base) and (\(identifiers))"
    }
}
