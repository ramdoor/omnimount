import SwiftUI
import OmnimountKit

/// Hoja de formateo con avisos: elegir formato y etiqueta, y confirmación
/// en dos pasos (marcar la casilla + botón destructivo).
struct FormatSheet: View {
    let partition: DiskPartition

    @EnvironmentObject private var monitor: DiskMonitor
    @EnvironmentObject private var mountController: MountController
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFormat: TargetFormat = .ext4
    @State private var label: String = ""
    @State private var confirmed = false
    @State private var working = false

    private var partitionDescription: String {
        let name = partition.volumeName.map { " «\($0)»" } ?? ""
        return "\(partition.deviceIdentifier)\(name) · \(partition.humanSize)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("Formatear partición", "Format partition"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(partitionDescription)
                .font(.body.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("⚠️ Esta operación BORRARÁ TODOS LOS DATOS de la partición de forma permanente. No se puede deshacer.", "⚠️ This operation will PERMANENTLY ERASE ALL DATA on the partition. It cannot be undone."))
                Text(L10n.t("Si la tarjeta es de una consola (ArkOS, Batocera…), formatear la partición equivocada puede dejarla sin arrancar. Haz antes una copia con `omnimount clone`.", "If this card belongs to a console (ArkOS, Batocera…), formatting the wrong partition can make it unbootable. Back it up first with `omnimount clone`."))
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Picker(L10n.t("Formato", "Format"), selection: $selectedFormat) {
                ForEach(TargetFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            TextField(L10n.t("Etiqueta del volumen", "Volume label"), text: $label)
                .textFieldStyle(.roundedBorder)

            Toggle(L10n.t("Entiendo que se borrará todo el contenido de \(partition.deviceIdentifier)", "I understand all content of \(partition.deviceIdentifier) will be erased"), isOn: $confirmed)
                .font(.callout)

            HStack {
                Button(L10n.t("Cancelar", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                }
                Button(L10n.t("Formatear (borra todo)", "Format (erases everything)"), role: .destructive) {
                    working = true
                    mountController.format(partition,
                                           as: selectedFormat.rawValue,
                                           label: label.isEmpty ? "OMNIMOUNT" : label) {
                        working = false
                        monitor.refresh()
                        dismiss()
                    }
                }
                .disabled(!confirmed || working)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
