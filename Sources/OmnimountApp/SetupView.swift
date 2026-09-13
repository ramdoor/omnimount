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
                actionLabel: installingFuseT
                    ? L10n.t("Instalando…", "Installing…")
                    : L10n.t("Instalar FUSE-T", "Install FUSE-T"),
                action: { installFuseT() }
            )

            stepRow(
                done: fuse2fsPath != nil,
                title: fuse2fsPath.map { "fuse2fs — \($0)" } ?? L10n.t("fuse2fs (montaje ext2/3/4)", "fuse2fs (ext2/3/4 mounting)"),
                detail: L10n.t("Incluido dentro de la app.", "Bundled inside the app."),
                actionLabel: L10n.t("Copiar comando", "Copy command"),
                action: { copy("make fuse2fs") }
            )

            stepRow(
                done: ntfs3gPath != nil,
                title: ntfs3gPath.map { "ntfs-3g — \($0)" } ?? L10n.t("ntfs-3g (montaje NTFS)", "ntfs-3g (NTFS mounting)"),
                detail: L10n.t("Incluido dentro de la app, compilado contra FUSE-T (sin macFUSE).", "Bundled inside the app, built against FUSE-T (no macFUSE needed)."),
                actionLabel: L10n.t("Copiar comando", "Copy command"),
                action: { copy("make ntfs3g") }
            )

            stepRow(
                done: e2fsckPath != nil,
                title: L10n.t("e2fsprogs (verificación y formateo ext4)", "e2fsprogs (ext4 checking and formatting)"),
                detail: L10n.t("e2fsck, mkfs.ext4 y compañía — incluidos dentro de la app.", "e2fsck, mkfs.ext4 and friends — bundled inside the app."),
                actionLabel: L10n.t("Copiar comando", "Copy command"),
                action: { copy("make fuse2fs") }
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
                detail: helperNotResponding
                    ? L10n.t("El helper está registrado pero no arranca (suele pasar tras actualizar la app). \"Reparar helper\" lo re-registra; después vuelve a comprobar.", "The helper is registered but won't start (usually after updating the app). \"Repair helper\" re-registers it; then check again.")
                    : L10n.t("Añade con + el binario /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper (Cmd+Mayús+G para pegar la ruta).", "Add the binary /Applications/Omnimount.app/Contents/MacOS/OmnimountHelper with + (Cmd+Shift+G to paste the path)."),
                actionLabel: helperNotResponding
                    ? L10n.t("Reparar helper", "Repair helper")
                    : L10n.t("Abrir Acceso total al disco", "Open Full Disk Access"),
                action: {
                    if helperNotResponding {
                        mountController.helper.repair()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { refresh() }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
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

    /// Registrado como activo pero sin responder al XPC: candidato a reparación.
    private var helperNotResponding: Bool {
        mountController.helper.state == .enabled && !helperReachable
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

    @State private var installingFuseT = false

    /// Descarga el pkg oficial de FUSE-T y lo instala con diálogo de admin.
    private func installFuseT() {
        guard !installingFuseT else { return }
        installingFuseT = true
        // Resolver la última release en GitHub; si la API falla, caer a una
        // versión conocida y, en último término, abrir la página de releases.
        let fallback = URL(string: "https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.7/fuse-t-macos-installer-1.2.7.pkg")!
        let api = URL(string: "https://api.github.com/repos/macos-fuse-t/fuse-t/releases/latest")!
        let resolve: (@escaping (URL) -> Void) -> Void = { done in
            URLSession.shared.dataTask(with: api) { data, _, _ in
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let assets = json["assets"] as? [[String: Any]],
                   let pkg = assets.compactMap({ $0["browser_download_url"] as? String })
                       .first(where: { $0.hasSuffix(".pkg") }),
                   let url = URL(string: pkg) {
                    done(url)
                } else {
                    done(fallback)
                }
            }.resume()
        }
        resolve { url in
        URLSession.shared.downloadTask(with: url) { temp, _, error in
            guard let temp, error == nil else {
                DispatchQueue.main.async {
                    installingFuseT = false
                    NSWorkspace.shared.open(URL(string: "https://github.com/macos-fuse-t/fuse-t/releases/latest")!)
                }
                return
            }
            let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("fuse-t-installer.pkg")
            try? FileManager.default.removeItem(at: pkg)
            try? FileManager.default.moveItem(at: temp, to: pkg)
            let script = "do shell script \"installer -pkg '\(pkg.path)' -target /\" with administrator privileges"
            DispatchQueue.global().async {
                let apple = NSAppleScript(source: script)
                var errInfo: NSDictionary?
                apple?.executeAndReturnError(&errInfo)
                DispatchQueue.main.async {
                    installingFuseT = false
                    refresh()
                }
            }
        }.resume()
        }
    }

    private func refresh() {
        if ToolLocator.isFuseTInstalled {
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
