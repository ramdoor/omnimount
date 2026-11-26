import Foundation

/// Firmware de consola retro reconocido a partir de las etiquetas de partición.
public struct RetroCardMatch: Sendable {
    public let firmware: String
    public let advice: String
}

/// Detección de tarjetas SD de consolas retro (Anbernic, Powkiddy, etc.)
/// por las etiquetas de partición características de cada firmware.
public enum RetroCards {

    /// Se resuelve en cada consulta para seguir el idioma del proceso, no el
    /// que hubiera al cargar el tipo.
    private static func knownCards() -> [(label: String, firmware: String, advice: String)] {
        [
            ("EASYROMS", "ArkOS",
             L10n.t("retro.arkos.advice")),
            ("ARKOS", "ArkOS",
             L10n.t("retro.arkos.advice")),
            ("BATOCERA", "Batocera",
             L10n.t("retro.batocera.advice")),
            ("SHARE", "Batocera",
             L10n.t("retro.batocera.share")),
            ("ROCKNIX", "ROCKNIX/JELOS",
             L10n.t("retro.rocknix.advice")),
            ("GAMES", "ROCKNIX/JELOS",
             L10n.t("retro.rocknix.games")),
            ("ROMS", "muOS / Knulli",
             L10n.t("retro.muos.advice")),
            ("RETROPIE", "RetroPie",
             L10n.t("retro.retropie.advice")),
            ("RECALBOX", "Recalbox",
             L10n.t("retro.recalbox.advice")),
            ("BOOT", L10n.t("retro.pi.name"),
             L10n.t("retro.pi.advice")),
        ]
    }

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
        let knownLabels = knownCards()
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
