import AppKit
import SwiftUI

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
            FileHandle.standardError.write(Data("Esto es la app de menú Omnimount, no el CLI. Usa /opt/homebrew/bin/omnimount.\n".utf8))
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
    }
}

/// Sin icono en el Dock: Omnimount vive solo en la barra de menú.
/// (Al empaquetar como .app, LSUIElement en Info.plist hace lo mismo.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
