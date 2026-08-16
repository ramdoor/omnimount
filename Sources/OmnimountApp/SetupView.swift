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
            Text("Configuración de Omnimount")
                .font(.title2.bold())
                .padding(.bottom, 8)

            Text("Cada fila se comprueba en vivo. Completa las que estén en rojo, en orden.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            stepRow(
                done: fuseLayer != .none,
                title: fuseLayerTitle,
                detail: "La capa que permite montar sistemas de ficheros en espacio de usuario. FUSE-T no necesita kext ni reinicios.",
                actionLabel: "Copiar comando de instalación",
                action: { copy("brew install --cask macos-fuse-t/cask/fuse-t") }
            )

            stepRow(
                done: fuse2fsPath != nil,
                title: fuse2fsPath.map { "fuse2fs — \($0)" } ?? "fuse2fs (montaje ext2/3/4)",
                detail: "Se compila con `make fuse2fs` desde el repositorio (el paquete de Homebrew no lo incluye).",
                actionLabel: "Copiar comando",
                action: { copy("make fuse2fs") }
            )

            stepRow(
                done: ntfs3gPath != nil,
                title: ntfs3gPath.map { "ntfs-3g — \($0)" } ?? "ntfs-3g (montaje NTFS)",
                detail: "Montaje NTFS en escritura y mkntfs para formatear.",
                actionLabel: "Copiar comando",
                action: { copy("brew install gromgit/fuse/ntfs-3g-mac") }
            )

            stepRow(
                done: e2fsckPath != nil,
                title: "e2fsprogs (verificación y formateo ext4)",
                detail: "e2fsck, mkfs.ext4 y compañía.",
                actionLabel: "Copiar comando",
                action: { copy("brew install e2fsprogs") }
            )

            stepRow(
                done: mountController.helper.state == .enabled,
                title: "Helper privilegiado (operaciones sin contraseña)",
                detail: "Daemon aprobado una única vez en Ajustes → Elementos de inicio.",
                actionLabel: mountController.helper.state == .requiresApproval ? "Abrir Elementos de inicio" : "Activar helper",
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
                detail: "Añade con + el binario /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper (Cmd+Mayús+G para pegar la ruta).",
                actionLabel: "Abrir Acceso total al disco",
                action: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )

            if let copied = copiedCommand {
                Label("Copiado: \(copied) — pégalo en Terminal", systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Spacer()

            HStack {
                if allDone {
                    Label("Todo listo. Omnimount está completamente operativo.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Volver a comprobar") { refresh() }
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
        case .fuseT: return "Capa FUSE — FUSE-T (sin kext) ✓"
        case .macFUSE: return "Capa FUSE — macFUSE (kext)"
        case .none: return "Capa FUSE (FUSE-T recomendado)"
        }
    }

    private var helperFDATitle: String {
        if !helperReachable { return "Acceso total al disco del helper (helper no disponible aún)" }
        return helperHasFDA
            ? "Acceso total al disco del helper ✓"
            : "Acceso total al disco del helper — FALTA"
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
