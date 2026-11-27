import Foundation

/// Entrecomillado para construir órdenes de shell y literales AppleScript a
/// partir de valores arbitrarios (rutas, etiquetas de volumen…).
public enum ScriptQuoting {
    /// Devuelve `value` como una sola palabra de shell POSIX: entre comillas
    /// simples, con cada `'` interna escrita como `'\''`. Dentro de comillas
    /// simples el shell no interpreta ningún otro carácter.
    public static func posixShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Une ejecutable y argumentos en una orden de shell, entrecomillando
    /// cada pieza. `environment` se antepone como asignaciones `NOMBRE=valor`
    /// (los nombres deben ser identificadores de shell válidos).
    public static func shellCommand(_ executable: String, _ arguments: [String],
                                    environment: [(String, String)] = []) -> String {
        let assignments = environment.map { "\($0.0)=\(posixShellQuote($0.1))" }
        let words = ([executable] + arguments).map(posixShellQuote)
        return (assignments + words).joined(separator: " ")
    }

    /// Devuelve `value` como literal de cadena AppleScript, comillas
    /// incluidas: escapa `\` y `"`, los únicos caracteres especiales dentro
    /// de una cadena AppleScript.
    public static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
