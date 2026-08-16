import AppKit
import ServiceManagement
import SwiftUI
import OmnimountKit

/// Asistente de configuración: chequeo en vivo de dependencias y permisos,
/// con botones de acción para cada paso pendiente.
struct SetupView: View {
    @EnvironmentObject private var mountController: MountController

    @State private var fuseLayer: FuseLayer = .none
    @State private var fuse2fsPath: String?
    @State private var ntfs3gPath: String?
    @State private var e2fsckPath: String?
    @State private var helperReachable = false
    @State private var helperHasFDA = false
    @State private var copiedCommand: String?

    enum FuseLayer { case fuseT, macFUSE, none }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Configuración de Omnimount", "Omnimount Setup"))
                .font(.title2.bold())
                .padding(.bottom, 8)

            Text(L10n.t("Cada fila se comprueba en vivo. Completa las que estén en rojo, en orden.", "Every row is checked live. Complete the red ones, in order."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            stepRow(
                done: fuseLayer != .none,
                title: fuseLayerTitle,
                detail: L10n.t("La capa que permite montar sistemas de ficheros en espacio de usuario. FUSE-T no necesita kext ni reinicios.", "The layer that mounts filesystems in user space. FUSE-T needs no kext and no reboots."),
                actionLabel: L10n.t("Copiar comando de instalación", "Copy install command"),
                action: { copy("brew install --cask macos-fuse-t/cask/fuse-t") }
            )

            stepRow(
                done: fuse2fsPath != nil,
                title: fuse2fsPath.map { "fuse2fs — \($0)" } ?? L10n.t("fuse2fs (montaje ext2/3/4)", "fuse2fs (ext2/3/4 mounting)"),
                detail: L10n.t("Se compila con `make fuse2fs` desde el repositorio (el paquete de Homebrew no lo incluye).", "Built with `make fuse2fs` from the repository (the Homebrew package does not include it)."),
                actionLabel: L10n.t("Copiar comando", "Copy command"),
                action: { copy("make fuse2fs") }
            )

            stepRow(
                done: ntfs3gPath != nil,
                title: ntfs3gPath.map { "ntfs-3g — \($0)" } ?? L10n.t("ntfs-3g (montaje NTFS)", "ntfs-3g (NTFS mounting)"),
                detail: L10n.t("Montaje NTFS en escritura y mkntfs para formatear.", "Read/write NTFS mounting plus mkntfs for formatting."),
                actionLabel: L10n.t("Copiar comando", "Copy command"),
                action: { copy("brew install gromgit/fuse/ntfs-3g-mac") }
            )

            stepRow(
                done: e2fsckPath != nil,
                title: L10n.t("e2fsprogs (verificación y formateo ext4)", "e2fsprogs (ext4 checking and formatting)"),
                detail: L10n.t("e2fsck, mkfs.ext4 y compañía.", "e2fsck, mkfs.ext4 and friends."),
                actionLabel: L10n.t("Copiar comando", "Copy command"),
                action: { copy("brew install e2fsprogs") }
            )

            stepRow(
                done: mountController.helper.state == .enabled,
                title: L10n.t("Helper privilegiado (operaciones sin contraseña)", "Privileged helper (password-free operations)"),
                detail: L10n.t("Daemon aprobado una única vez en Ajustes → Elementos de inicio.", "A daemon you approve once in Settings → Login Items."),
                actionLabel: mountController.helper.state == .requiresApproval ? L10n.t("Abrir Elementos de inicio", "Open Login Items") : L10n.t("Activar helper", "Enable helper"),
                action: {
                    if mountController.helper.state == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    } else {
                        mountController.helper.install()
                    }
                }
            )

            stepRow(
                done: helperReachable && helperHasFDA,
                title: helperFDATitle,
                detail: L10n.t("Añade con + el binario /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper (Cmd+Mayús+G para pegar la ruta).", "Add the binary /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper with + (Cmd+Shift+G to paste the path)."),
                actionLabel: L10n.t("Abrir Acceso total al disco", "Open Full Disk Access"),
                action: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )

            if let copied = copiedCommand {
                Label(L10n.t("Copiado: \(copied) — pégalo en Terminal", "Copied: \(copied) — paste it in Terminal"), systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Spacer()

            HStack {
                if allDone {
                    Label(L10n.t("Todo listo. Omnimount está completamente operativo.", "All set. Omnimount is fully operational."), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(L10n.t("Volver a comprobar", "Check again")) { refresh() }
            }
        }
        .padding(20)
        .frame(width: 560, height: 480, alignment: .topLeading)
        .onAppear { refresh() }
    }

    private var allDone: Bool {
        fuseLayer != .none && fuse2fsPath != nil && ntfs3gPath != nil
            && e2fsckPath != nil && mountController.helper.state == .enabled
            && helperReachable && helperHasFDA
    }

    private var fuseLayerTitle: String {
        switch fuseLayer {
        case .fuseT: return L10n.t("Capa FUSE — FUSE-T (sin kext) ✓", "FUSE layer — FUSE-T (kext-free) ✓")
        case .macFUSE: return L10n.t("Capa FUSE — macFUSE (kext)", "FUSE layer — macFUSE (kext)")
        case .none: return L10n.t("Capa FUSE (FUSE-T recomendado)", "FUSE layer (FUSE-T recommended)")
        }
    }

    private var helperFDATitle: String {
        if !helperReachable { return L10n.t("Acceso total al disco del helper (helper no disponible aún)", "Helper Full Disk Access (helper not available yet)") }
        return helperHasFDA
            ? L10n.t("Acceso total al disco del helper ✓", "Helper Full Disk Access ✓")
            : L10n.t("Acceso total al disco del helper — FALTA", "Helper Full Disk Access — MISSING")
    }

    @ViewBuilder
    private func stepRow(done: Bool, title: String, detail: String,
                         actionLabel: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !done {
                    Button(actionLabel, action: action)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommand = command
    }

    private func refresh() {
        if FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib") {
            fuseLayer = .fuseT
        } else if ToolLocator.isMacFUSEInstalled {
            fuseLayer = .macFUSE
        } else {
            fuseLayer = .none
        }
        fuse2fsPath = ToolLocator.find(.fuse2fs)
        ntfs3gPath = ToolLocator.find(.ntfs3g)
        e2fsckPath = ToolLocator.find(.e2fsck)

        mountController.helper.refreshState()
        if mountController.helper.state == .enabled {
            mountController.helper.checkFullDiskAccess { reachable, hasFDA in
                helperReachable = reachable
                helperHasFDA = hasFDA
            }
        } else {
            helperReachable = false
            helperHasFDA = false
        }
    }
}
