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
    @State private var setupNotice: String?
    @AppStorage("menuTextSize") private var menuTextSize = MenuTextSize.normal.rawValue
    @AppStorage("openInNewFinderWindow") private var openInNewFinderWindow = false

    enum FuseLayer { case fuseT, macFUSE, none }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("app.setup.title"))
                .font(.title2.bold())
                .padding(.bottom, 8)

            Text(L10n.t("app.setup.intro"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            stepRow(
                done: fuseLayer != .none,
                title: fuseLayerTitle,
                detail: L10n.t("app.setup.fuseDetail"),
                actionLabel: installingFuseT
                    ? L10n.t("app.setup.installing")
                    : L10n.t("app.setup.installFuse"),
                action: { installFuseT() }
            )

            stepRow(
                done: fuse2fsPath != nil,
                title: fuse2fsPath.map { "fuse2fs — \($0)" } ?? L10n.t("app.setup.fuse2fsTitle"),
                detail: L10n.t("app.setup.bundled"),
                actionLabel: L10n.t("app.setup.copyCommand"),
                action: { copy("make fuse2fs") }
            )

            stepRow(
                done: ntfs3gPath != nil,
                title: ntfs3gPath.map { "ntfs-3g — \($0)" } ?? L10n.t("app.setup.ntfsTitle"),
                detail: L10n.t("app.setup.ntfsDetail"),
                actionLabel: L10n.t("app.setup.copyCommand"),
                action: { copy("make ntfs3g") }
            )

            stepRow(
                done: e2fsckPath != nil,
                title: L10n.t("app.setup.e2fsTitle"),
                detail: L10n.t("app.setup.e2fsDetail"),
                actionLabel: L10n.t("app.setup.copyCommand"),
                action: { copy("make fuse2fs") }
            )

            if #available(macOS 13.0, *) {
                stepRow(
                    done: mountController.helper.state == .enabled,
                    title: L10n.t("app.setup.helperTitle"),
                    detail: L10n.t("app.setup.helperDetail"),
                    actionLabel: mountController.helper.state == .requiresApproval ? L10n.t("app.setup.openLoginItems") : L10n.t("app.common.enableHelper"),
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
                        ? L10n.t("app.setup.helperStuck")
                        : L10n.t("app.setup.fdaHint"),
                    actionLabel: helperNotResponding
                        ? L10n.t("app.setup.repairHelper")
                        : L10n.t("app.setup.openFda"),
                    action: {
                        if helperNotResponding {
                            // Des-registrar mata el daemon: no hacerlo con
                            // operaciones en curso.
                            guard !mountController.hasActiveOperations else {
                                setupNotice = L10n.t("app.alert.repairBusy")
                                return
                            }
                            setupNotice = nil
                            mountController.helper.repair()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { refresh() }
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            } else {
                // macOS 12: el helper sin contraseña (SMAppService) no existe.
                // No es un paso pendiente; se informa de que se pedirá la
                // contraseña de administrador al montar.
                infoRow(
                    title: L10n.t("app.setup.adminTitle"),
                    detail: L10n.t("app.setup.adminDetail"))
            }

            if let notice = setupNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }

            if let copied = copiedCommand {
                Label(L10n.t("app.setup.copied", copied), systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Divider().padding(.vertical, 4)

            Text(L10n.t("app.setup.preferences"))
                .font(.headline)
            HStack {
                Text(L10n.t("app.setup.textSize"))
                Spacer()
                Picker("", selection: $menuTextSize) {
                    ForEach(MenuTextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle(L10n.t("app.setup.newWindow"),
                   isOn: $openInNewFinderWindow)

            Spacer()

            HStack {
                if allDone {
                    Label(L10n.t("app.setup.ready"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(L10n.t("app.setup.checkAgain")) { refresh() }
            }
        }
        .padding(20)
        .frame(width: 560, height: 600, alignment: .topLeading)
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
        case .fuseT: return L10n.t("app.setup.fuseT")
        case .macFUSE: return L10n.t("app.setup.macFuse")
        case .none: return L10n.t("app.setup.fuseNeeded")
        }
    }

    private var helperFDATitle: String {
        if !helperReachable { return L10n.t("app.setup.fdaWaiting") }
        return helperHasFDA
            ? L10n.t("app.setup.fdaOk")
            : L10n.t("app.setup.fdaMissing")
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

    /// Fila informativa (ni pendiente ni completada): un punto neutro y texto,
    /// sin botón de acción. Para pasos que no aplican en esta versión de macOS.
    private func infoRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
