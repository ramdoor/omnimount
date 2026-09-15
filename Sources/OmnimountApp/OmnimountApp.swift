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

/// Instancias compartidas del monitor de discos y el controlador de montaje.
/// Un singleton (en vez de @StateObject) para que también las alcance el
/// AppDelegate, que en macOS 12 construye la interfaz a mano (NSStatusItem).
@MainActor
final class AppServices {
    static let shared = AppServices()
    let monitor = DiskMonitor()
    let mountController = MountController()
    private init() {}
}

extension Notification.Name {
    /// La vista del menú pide abrir la ventana de Configuración.
    static let omnimountOpenSetup = Notification.Name("omnimount.openSetup")
}

@main
struct OmnimountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

    // La barra de menú la gestiona el AppDelegate con NSStatusItem (funciona
    // en macOS 12 y 13+ por igual; MenuBarExtra es solo de 13+). Una escena
    // Settings vacía cumple el requisito de tener al menos una y no muestra
    // ventana al arrancar.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Sin icono en el Dock: Omnimount vive solo en la barra de menú.
/// (Al empaquetar como .app, LSUIElement en Info.plist hace lo mismo.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Instanciar el updater ya: al ser `static let` (perezoso), si nadie
        // lo toca hasta pulsar "Actualizaciones…" las comprobaciones
        // automáticas de Sparkle no llegan a programarse nunca.
        _ = Updater.controller

        // La ventana de Configuración se abre igual en todas las versiones:
        // un NSWindow que hospeda SetupView (evita depender de openWindow /
        // la escena Window, que son de macOS 13+).
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSetup),
            name: .omnimountOpenSetup, object: nil)

        installStatusItem()
    }

    // MARK: - Barra de menú (NSStatusItem + popover, todas las versiones)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive.badge.plus",
                                     accessibilityDescription: "Omnimount")
        item.button?.action = #selector(togglePopover)
        item.button?.target = self

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 340, height: 480)
        pop.contentViewController = NSHostingController(rootView:
            MenuContentView()
                .environmentObject(AppServices.shared.monitor)
                .environmentObject(AppServices.shared.mountController)
                .frame(width: 340)
        )
        statusItem = item
        popover = pop
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Ventana de Configuración (todas las versiones)

    @objc private func openSetup() {
        if setupWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = L10n.t("Configuración de Omnimount", "Omnimount Setup")
            win.contentViewController = NSHostingController(rootView:
                SetupView().environmentObject(AppServices.shared.mountController))
            win.isReleasedWhenClosed = false
            win.center()
            setupWindow = win
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
