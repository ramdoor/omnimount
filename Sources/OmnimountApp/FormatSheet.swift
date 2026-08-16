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
            Label("Formatear partición", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(partitionDescription)
                .font(.body.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("⚠️ Esta operación BORRARÁ TODOS LOS DATOS de la partición de forma permanente. No se puede deshacer.")
                Text("Si la tarjeta es de una consola (ArkOS, Batocera…), formatear la partición equivocada puede dejarla sin arrancar. Haz antes una copia con `omnimount clone`.")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Picker("Formato", selection: $selectedFormat) {
                ForEach(TargetFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            TextField("Etiqueta del volumen", text: $label)
                .textFieldStyle(.roundedBorder)

            Toggle("Entiendo que se borrará todo el contenido de \(partition.deviceIdentifier)", isOn: $confirmed)
                .font(.callout)

            HStack {
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                }
                Button("Formatear (borra todo)", role: .destructive) {
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
