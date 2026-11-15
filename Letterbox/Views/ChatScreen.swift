import LetterboxApplication
import LetterboxDomain
import SwiftUI

struct ChatScreen: View {
    @Environment(ChatStore.self) private var store
    @State private var draft = ""
    @State private var sheet: Sheet?
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    enum Sheet: String, Identifiable {
        case channels, people, settings, connections, envelopes, outside
        var id: String { rawValue }
    }

    var body: some View {
        // After "Erase everything" the chat is gone entirely, not just covered.
        if store.isErased {
            ErasedScreen()
        } else {
            chat
        }
    }

    private var chat: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RadioBanner(state: store.radio)
                if store.hidesMessages { PrivacyBanner() }
                MessageList(messages: store.messages(in: store.selectedChannel), hidesText: store.hidesMessages,
                            envelopes: store.envelopes)
                composer
            }
            .inlineTitle()
            .toolbar { toolbar }
            .sheet(item: $sheet) { sheet in
                Group {
                    switch sheet {
                    case .channels: ChannelsSheet()
                    case .people: PeopleSheet()
                    case .settings: SettingsSheet()
                    case .connections: ConnectionsSheet()
                    case .outside: OutsideMessageSheet(draft: draft, nickname: store.nickname)
                    case .envelopes:
                        NavigationStack {
                            EnvelopesView().toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { self.sheet = nil } }
                            }
                        }
                    }
                }
                .environment(store)
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 480)
                #endif
            }
        }
        .overlay { if showsPrivacyCover { PrivacyCover() } }
        // Alerts go to the lock screen only while Letterbox is off screen.
        .onChange(of: scenePhase, initial: true) { _, phase in store.setActive(phase == .active) }
    }

    /// In privacy mode, cover the screen while the app is inactive so the app
    /// switcher snapshot doesn't show the chat. iOS only: on the Mac, "inactive"
    /// just means another window has focus.
    private var showsPrivacyCover: Bool {
        #if os(iOS)
        store.hidesMessages && scenePhase != .active
        #else
        false
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Leading: what's working right now. Tapping opens the Connections panel.
        ToolbarItem(placement: Self.leading) {
            Button { sheet = .connections } label: { ConnectionsChip() }
                .accessibilityIdentifier("connections-button")
                .accessibilityShowsLargeContentViewer()
                .help("What's working: Bluetooth, internet, mobile, satellite and envelopes")
        }
        ToolbarItem(placement: .principal) {
            Button { sheet = .channels } label: {
                HStack(spacing: 4) {
                    Text(store.title(for: store.selectedChannel)).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    if totalUnreadElsewhere > 0 {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Channel \(store.title(for: store.selectedChannel))")
            .accessibilityHint(totalUnreadElsewhere > 0 ? "New messages in other channels. Double-tap to switch." : "Double-tap to switch channel")
            .accessibilityIdentifier("channel-button")
                .accessibilityShowsLargeContentViewer()
        }
        // Trailing: people nearby, with a count you can see at a glance...
        ToolbarItem(placement: Self.trailing) {
            Button { sheet = .people } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                    Text("\(store.peers.count)").monospacedDigit()
                }
            }
            .accessibilityLabel(store.peers.count == 1 ? "1 person nearby" : "\(store.peers.count) people nearby")
            .accessibilityIdentifier("people-button")
                .accessibilityShowsLargeContentViewer()
        }
        // ...and everything else in one menu.
        ToolbarItem(placement: Self.trailing) {
            Menu {
                // A button, not a toggle: on iOS 27 a toggle leaves the menu open on top of
                // everything. The label says what tapping will do.
                Button { store.toggleHidesMessages() } label: {
                    Label(store.hidesMessages ? "Turn off privacy screen" : "Privacy screen",
                          systemImage: store.hidesMessages ? "hand.raised.slash" : "hand.raised")
                }
                .accessibilityIdentifier("menu-privacy")
                Divider()
                // Reaching people without Letterbox (invite, or a one-way AirDrop message).
                // One entry, so the menu stays short enough at the largest text sizes.
                Button { sheet = .outside } label: {
                    Label("Send outside Letterbox…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("menu-outside")
                Divider()
                Button { sheet = .envelopes } label: { Label("Envelopes", systemImage: "envelope") }
                    .accessibilityIdentifier("menu-envelopes")
                Button { sheet = .connections } label: { Label("Connections", systemImage: "antenna.radiowaves.left.and.right") }
                    .accessibilityIdentifier("menu-connections")
                Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("menu-settings")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            // The keyboard sits above app menus; at large text sizes it would hide the last
            // items. Opening the menu puts the keyboard away so every item is reachable.
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .accessibilityIdentifier("more-menu")
                .accessibilityShowsLargeContentViewer()
        }
    }

    private static var leading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private static var trailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    private var totalUnreadElsewhere: Int {
        store.unread.filter { $0.key != store.selectedChannel }.values.reduce(0, +)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                .focused($composerFocused)
                .onSubmit(send)
                .accessibilityIdentifier("composer")
                #if os(iOS)
                .submitLabel(.send)
                #endif
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Theme.accent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("send-button")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var placeholder: String {
        switch store.selectedChannel {
        case .mesh: "Message everyone nearby"
        case .location: "Message this area"
        case .direct: "Private message"
        }
    }

    private func send() {
        let text = draft
        draft = ""
        composerFocused = true
        Task { await store.submit(text) }
    }
}

/// Shown while the privacy screen is on, so it's obvious why messages are blurred
/// and how to undo it.
private struct PrivacyBanner: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        HStack {
            Label("Messages hidden", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
            Spacer()
            Button("Show") { store.setHidesMessages(false) }
                .font(.footnote.weight(.semibold))
                .accessibilityHint("Turns off the privacy screen")
                .accessibilityIdentifier("privacy-show")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy-banner")
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Label("Messages hidden", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// After "Erase everything": nothing is left to show, and nothing runs until reopened.
private struct ErasedScreen: View {
    var body: some View {
        ContentUnavailableView {
            Label("Everything is erased", systemImage: "trash")
        } description: {
            Text("Your identity, messages, envelopes and settings are gone from this device. Close Letterbox. Next time it opens, you'll start as someone new.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("erased-screen")
    }
}

private struct RadioBanner: View {
    let state: RadioState

    var body: some View {
        if let message {
            Label(message, systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.orange.opacity(0.2))
        }
    }

    private var message: String? {
        switch state {
        case .poweredOff: "Bluetooth is off. Turn it on to chat with people nearby."
        case .unauthorized: "Letterbox can't use Bluetooth. Allow it in Settings."
        case .unsupported: "This device doesn't support Bluetooth chat."
        case .unknown, .ready: nil
        }
    }
}
