import LetterboxApplication
import SwiftUI

@main
struct LetterboxApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ChatScreen()
                .environment(container.store)
                .tint(Theme.accent)
                .task { await container.start() }
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 720)
        #endif
    }
}
