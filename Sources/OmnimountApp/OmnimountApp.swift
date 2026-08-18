import AppKit
import SwiftUI
import Sparkle
import OmnimountKit

/// Actualizador Sparkle compartido (feed en omnimount.es/appcast.xml,
/// configurado vía Info.plist: SUFeedURL + SUPublicEDKey).
enum Updater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}

@main
struct OmnimountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = DiskMonitor()
    @StateObject private var mountController = MountController()

    init() {
        // Si alguien nos invoca como si fuéramos el CLI (p. ej. "Omnimount
        // mount disk4s2"), salir en el acto: quedarse arrancando la interfaz
        // dejaría un proceso colgado esperando eternamente.
        let args = CommandLine.arguments.dropFirst()
        if !args.isEmpty && !args.allSatisfy({ $0.hasPrefix("-") }) {
            FileHandle.standardError.write(Data((L10n.t("Esto es la app de menú Omnimount, no el CLI. Usa el comando omnimount (/usr/local/bin/omnimount).", "This is the Omnimount menu bar app, not the CLI. Use the omnimount command (/usr/local/bin/omnimount).") + "\n").utf8))
            exit(64)
        }
    }

    var body: some Scene {
        MenuBarExtra("Omnimount", systemImage: "externaldrive.badge.plus") {
            MenuContentView()
                .environmentObject(monitor)
                .environmentObject(mountController)
        }
        .menuBarExtraStyle(.window)

        Window("Configuración de Omnimount", id: "setup") {
            SetupView()
                .environmentObject(mountController)
        }
        .windowResizability(.contentSize)
    }
}

/// Sin icono en el Dock: Omnimount vive solo en la barra de menú.
/// (Al empaquetar como .app, LSUIElement en Info.plist hace lo mismo.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Instanciar el updater ya: al ser `static let` (perezoso), si nadie
        // lo toca hasta pulsar "Actualizaciones…" las comprobaciones
        // automáticas de Sparkle no llegan a programarse nunca.
        _ = Updater.controller
    }
}
