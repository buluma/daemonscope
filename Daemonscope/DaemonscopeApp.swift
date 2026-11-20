import AppKit
import SwiftUI

@main
struct DaemonscopeApp: App {
    static let mainWindowID = "main"

    @State private var store = InventoryStore()
    @State private var launchServices = LaunchServicesStore()

    var body: some Scene {
        // LSUIElement apps are never active on their own, so the menu bar extra is the app's only
        // always-present surface. It also keeps the process alive after the main window closes.
        MenuBarExtra("Daemonscope", systemImage: "gearshape.2") {
            MenuBarView(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Daemonscope", id: Self.mainWindowID) {
            MainWindowView(store: store, launchServices: launchServices)
        }
        // Without this the window would open at launch, which a menu-bar-only app shouldn't do.
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Opens the main window and brings it forward. An LSUIElement app isn't activated by opening a
/// window, so without the explicit activation the window lands behind whatever app is frontmost.
@MainActor
func showMainWindow(_ openWindow: OpenWindowAction) {
    openWindow(id: DaemonscopeApp.mainWindowID)
    NSApp.activate()
}
