import Foundation

/// Textos de la app, el helper y el CLI. Cada llamada usa una clave de tres
/// segmentos, en camelCase y empezando en minúscula:
/// `app.<pantalla>.<nombre>`, `cli.<comando>.<nombre>`,
/// `error.<área>.<nombre>`, `disk.<grupo>.<nombre>`, `retro.<firmware>.<nombre>`.
/// Los scripts usan el mismo esquema en `sh.<script>.<nombre>` (`scripts/l10n.sh`).
/// El inglés de `L10nTable` es el respaldo. El idioma sigue el primero de
/// `Locale.preferredLanguages`; `OMNIMOUNT_LANG=es` o `en` lo sustituye
/// (cualquier otro valor fuerza inglés).
public enum L10n {
    public static func t(_ key: String, _ args: String...) -> String {
        let template = template(for: key)
        guard !args.isEmpty else { return template }
        return fill(template, with: args)
    }

    private static func template(for key: String) -> String {
        guard let text = L10nTable.entries[key] else { return key }
        return usesSpanish ? text.es : text.en
    }

    private static var usesSpanish: Bool {
        if let env = getenv("OMNIMOUNT_LANG") {
            let raw = String(cString: env).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !raw.isEmpty {
                return raw == "es" || raw.hasPrefix("es-") || raw.hasPrefix("es_")
            }
        }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("es") ?? false
    }

    /// Sustituye cada `%@` en orden. El texto insertado no se reinterpreta:
    /// un mensaje del sistema que contenga `%` no rompe la frase.
    private static func fill(_ template: String, with args: [String]) -> String {
        var result = ""
        var rest = Substring(template)
        var next = 0
        while let range = rest.range(of: "%@") {
            result.append(contentsOf: rest[..<range.lowerBound])
            if next < args.count {
                result.append(args[next])
                next += 1
            } else {
                result.append("%@")
            }
            rest = rest[range.upperBound...]
        }
        result.append(contentsOf: rest)
        return result
    }
}
