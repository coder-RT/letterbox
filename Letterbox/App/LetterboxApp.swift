import LetterboxApplication
import SwiftUI

@main
struct LetterboxApp: App {
    private let container: AppContainer

    init() {
        let container = AppContainer()
        self.container = container
        // Start here, not from a view: when iOS relaunches Letterbox in the background for a
        // Bluetooth event (state restoration), no window is created, but the mesh must run.
        Task { await container.start() }
    }

    var body: some Scene {
        WindowGroup {
            ChatScreen()
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 480)
                #endif
                .environment(container.store)
                .tint(Theme.accent)
        }
        #if os(macOS)
        // Wide enough for every toolbar control (connections, channel, people, menu);
        // the window title is hidden because the channel name already says where you are.
        .defaultSize(width: 520, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
    }
}
