import Foundation

/// Firmware de consola retro reconocido a partir de las etiquetas de partición.
public struct RetroCardMatch: Sendable {
    public let firmware: String
    public let advice: String
}

/// Detección de tarjetas SD de consolas retro (Anbernic, Powkiddy, etc.)
/// por las etiquetas de partición características de cada firmware.
public enum RetroCards {

    private static let knownLabels: [(label: String, firmware: String, advice: String)] = [
        ("EASYROMS", "ArkOS",
         "Tarjeta de ArkOS. La partición EASYROMS contiene tus roms; la partición del sistema es ext4 y no debe modificarse a mano. Haz una copia con `omnimount clone` antes de tocar nada."),
        ("ARKOS", "ArkOS",
         "Tarjeta de ArkOS. La partición EASYROMS contiene tus roms; la partición del sistema es ext4 y no debe modificarse a mano. Haz una copia con `omnimount clone` antes de tocar nada."),
        ("BATOCERA", "Batocera",
         "Tarjeta de Batocera. La partición de usuario (SHARE) es ext4; móntala con Omnimount para gestionar roms y saves."),
        ("SHARE", "Batocera",
         "Posible partición de datos de Batocera (roms/saves en ext4)."),
        ("ROCKNIX", "ROCKNIX/JELOS",
         "Tarjeta de ROCKNIX (antes JELOS). La partición de juegos suele ser ext4."),
        ("GAMES", "ROCKNIX/JELOS",
         "Posible partición de juegos de ROCKNIX/JELOS (ext4)."),
        ("ROMS", "muOS / Knulli",
         "Partición de roms típica de muOS o Knulli."),
        ("RETROPIE", "RetroPie",
         "Tarjeta de RetroPie. El sistema es ext4; los roms viven en /home/pi/RetroPie/roms dentro de la partición del sistema."),
        ("RECALBOX", "Recalbox",
         "Tarjeta de Recalbox. La partición de datos es ext4."),
        ("BOOT", "Raspberry Pi (genérico)",
         "Partición de arranque de una imagen tipo Raspberry Pi; la partición del sistema acompañante suele ser ext4."),
    ]

    /// Comprueba las particiones de un disco contra las etiquetas conocidas.
    public static func identify(partitions: [DiskPartition],
                                extLabels: [String: String] = [:]) -> RetroCardMatch? {
        // extLabels: etiquetas leídas del superbloque ext (id de partición → etiqueta),
        // porque macOS no siempre conoce el nombre de un volumen ext4.
        var labels: [String] = []
        for partition in partitions {
            if let name = partition.volumeName { labels.append(name) }
            if let extLabel = extLabels[partition.deviceIdentifier] { labels.append(extLabel) }
        }

        let normalized = labels.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }
        // Coincidencia exacta primero; después por prefijo ("ARKOS-128G" → ARKOS).
        for label in normalized {
            if let match = knownLabels.first(where: { $0.label == label }) {
                return RetroCardMatch(firmware: match.firmware, advice: match.advice)
            }
        }
        for label in normalized {
            if let match = knownLabels.first(where: { label.hasPrefix($0.label + "-") || label.hasPrefix($0.label + " ") }) {
                return RetroCardMatch(firmware: match.firmware, advice: match.advice)
            }
        }
        return nil
    }
}
