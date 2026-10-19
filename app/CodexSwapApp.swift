import SwiftUI

@main
@MainActor
struct CodexSwapApp: App {
    @StateObject private var store = SwapStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
                .preferredColorScheme(store.appearance.colorScheme)
        } label: {
            Group {
                if store.showMenuBarTPS {
                    Image(nsImage: MenuBarMetrics.image(speed: store.menuBarText, quota: store.menuBarQuota.text))
                        .renderingMode(.template)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                }
            }
            .accessibilityLabel(store.showMenuBarTPS ? store.menuBarHelp : "Codex Pilot")
            .help(store.showMenuBarTPS ? store.menuBarHelp : "Codex Pilot")
        }
        .menuBarExtraStyle(.window)
    }
}
