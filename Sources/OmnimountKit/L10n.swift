import Foundation

/// Localización mínima sin recursos externos: cada cadena visible se declara
/// en español e inglés en el punto de uso. El idioma se decide una vez a
/// partir de las preferencias del usuario (con `OMNIMOUNT_LANG=es|en` como
/// override para pruebas).
public enum L10n {
    public static let isSpanish: Bool = {
        if let forced = ProcessInfo.processInfo.environment["OMNIMOUNT_LANG"] {
            return forced.lowercased().hasPrefix("es")
        }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("es") ?? false
    }()

    /// Devuelve la variante española o inglesa según el idioma del sistema.
    @inlinable
    public static func t(_ es: String, _ en: String) -> String {
        isSpanish ? es : en
    }
}
