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
         L10n.t("Tarjeta de ArkOS. La partición EASYROMS contiene tus roms; la partición del sistema es ext4 y no debe modificarse a mano. Haz una copia con `omnimount clone` antes de tocar nada.", "ArkOS card. The EASYROMS partition holds your roms; the system partition is ext4 and should not be edited by hand. Back it up with `omnimount clone` before touching anything.")),
        ("ARKOS", "ArkOS",
         L10n.t("Tarjeta de ArkOS. La partición EASYROMS contiene tus roms; la partición del sistema es ext4 y no debe modificarse a mano. Haz una copia con `omnimount clone` antes de tocar nada.", "ArkOS card. The EASYROMS partition holds your roms; the system partition is ext4 and should not be edited by hand. Back it up with `omnimount clone` before touching anything.")),
        ("BATOCERA", "Batocera",
         L10n.t("Tarjeta de Batocera. La partición de usuario (SHARE) es ext4; móntala con Omnimount para gestionar roms y saves.", "Batocera card. The user partition (SHARE) is ext4; mount it with Omnimount to manage roms and saves.")),
        ("SHARE", "Batocera",
         L10n.t("Posible partición de datos de Batocera (roms/saves en ext4).", "Likely a Batocera data partition (roms/saves on ext4).")),
        ("ROCKNIX", "ROCKNIX/JELOS",
         L10n.t("Tarjeta de ROCKNIX (antes JELOS). La partición de juegos suele ser ext4.", "ROCKNIX card (formerly JELOS). The games partition is usually ext4.")),
        ("GAMES", "ROCKNIX/JELOS",
         L10n.t("Posible partición de juegos de ROCKNIX/JELOS (ext4).", "Likely a ROCKNIX/JELOS games partition (ext4).")),
        ("ROMS", "muOS / Knulli",
         L10n.t("Partición de roms típica de muOS o Knulli.", "Typical muOS or Knulli roms partition.")),
        ("RETROPIE", "RetroPie",
         L10n.t("Tarjeta de RetroPie. El sistema es ext4; los roms viven en /home/pi/RetroPie/roms dentro de la partición del sistema.", "RetroPie card. The system is ext4; roms live at /home/pi/RetroPie/roms inside the system partition.")),
        ("RECALBOX", "Recalbox",
         L10n.t("Tarjeta de Recalbox. La partición de datos es ext4.", "Recalbox card. The data partition is ext4.")),
        ("BOOT", "Raspberry Pi (genérico)",
         L10n.t("Partición de arranque de una imagen tipo Raspberry Pi; la partición del sistema acompañante suele ser ext4.", "Boot partition of a Raspberry Pi-style image; the companion system partition is usually ext4.")),
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
