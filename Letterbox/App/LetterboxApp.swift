import LetterboxApplication
import SwiftUI

@main
struct LetterboxApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ChatScreen()
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 480)
                #endif
                .environment(container.store)
                .tint(Theme.accent)
                .task { await container.start() }
        }
        #if os(macOS)
        // Wide enough for every toolbar control (connections, channel, people, menu);
        // the window title is hidden because the channel name already says where you are.
        .defaultSize(width: 520, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
    }
}
