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
    /// Huella del dispositivo al abrir la hoja; se comprueba antes de borrar.
    @State private var identity: DiskIdentity?

    private var partitionDescription: String {
        let name = partition.volumeName.map { " «\($0)»" } ?? ""
        return "\(partition.deviceIdentifier)\(name) · \(partition.humanSize)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("app.format.title"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(partitionDescription)
                .font(.body.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("app.format.erase"))
                Text(L10n.t("app.format.console"))
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Picker(L10n.t("app.format.picker"), selection: $selectedFormat) {
                ForEach(TargetFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            TextField(L10n.t("app.format.volumeLabel"), text: $label)
                .textFieldStyle(.roundedBorder)

            Toggle(L10n.t("app.format.confirm", partition.deviceIdentifier), isOn: $confirmed)
                .font(.callout)

            HStack {
                Button(L10n.t("app.common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                }
                Button(L10n.t("app.format.eraseButton"), role: .destructive) {
                    guard let identity else { return }
                    working = true
                    mountController.format(partition,
                                           as: selectedFormat.rawValue,
                                           label: label.isEmpty ? "OMNIMOUNT" : label,
                                           expected: identity) {
                        working = false
                        monitor.refresh()
                        dismiss()
                    }
                }
                .disabled(!confirmed || working || identity == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            if identity == nil { identity = DiskIdentity(partition: partition) }
        }
        .onReceive(monitor.$disks) { disks in
            // Si la partición desaparece o el identificador pasa a otro
            // dispositivo, cerrar la hoja. Durante el formateo la partición
            // cambia legítimamente (etiqueta, remontaje): no comprobar.
            guard !working, let identity, !identity.matches(in: disks) else { return }
            mountController.lastMessage = L10n.t("app.alert.diskChanged", partition.deviceIdentifier)
            dismiss()
        }
    }
}
