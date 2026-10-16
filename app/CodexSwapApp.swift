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
                    Text(store.menuBarText).monospacedDigit()
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                }
            }
            .accessibilityLabel("Codex Pilot")
        }
        .menuBarExtraStyle(.window)
    }
}
