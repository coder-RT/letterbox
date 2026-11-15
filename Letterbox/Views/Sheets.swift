import LetterboxApplication
import LetterboxDomain
import SwiftUI

struct ChannelsSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var joining: GeohashLevel?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.mesh, subtitle: store.peers.count == 1 ? "1 person in Bluetooth range" : "\(store.peers.count) people in Bluetooth range",
                        icon: "antenna.radiowaves.left.and.right")
                } header: {
                    SectionHeader("Nearby, no internet")
                }

                // Left out of the App Store build (see BuildSettings).
                if store.offersLocationChannels {
                    Section {
                        if let location = store.location {
                            row(.location(geohash: location.geohash),
                                subtitle: "\(location.level.title) · \(store.relays.connected)/\(store.relays.total) relays",
                                icon: "mappin.and.ellipse")
                            Button("Leave location channel", role: .destructive) {
                                Task { await store.leaveLocation() }
                            }
                        }
                        ForEach(GeohashLevel.allCases.reversed(), id: \.self) { level in
                            Button {
                                joining = level
                                Task {
                                    await store.joinLocation(level)
                                    joining = nil
                                    if store.locationError == nil { dismiss() }
                                }
                            } label: {
                                HStack {
                                    RowLabel("Join \(level.title.lowercased()) channel", systemImage: "location")
                                    Spacer()
                                    if joining == level { ProgressView().controlSize(.small) }
                                }
                            }
                            .disabled(joining != nil)
                        }
                        if let error = store.locationError {
                            Text(error).font(.footnote).foregroundStyle(Theme.bad)
                        }
                    } header: {
                        SectionHeader("Location, over the internet")
                    }
                    .disabled(!store.permissions.internet)

                    // An explanation row rather than a footer: footers stop growing at the
                    // largest text sizes, rows don't.
                    Section {
                        RowLabel(store.permissions.internet
                                 ? "Location channels go through public Nostr relays, which can see your IP address. Each area uses a separate identity."
                                 : "The internet is off in HelloLetter. Turn it on in Connections to use location channels.",
                                 systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Color.primary)
                    }
                }

                if !store.directChannels.isEmpty {
                    Section(header: SectionHeader("Private")) {
                        ForEach(store.directChannels, id: \.self) { channel in
                            row(channel, subtitle: "End-to-end encrypted", icon: "lock")
                        }
                    }
                }
            }
            // Keep the first header clear of the bar's scroll-edge fade.
            .contentMargins(.top, 24, for: .scrollContent)
            .navigationTitle("Channels")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ channel: ChannelID, subtitle: String, icon: String) -> some View {
        Button {
            store.selectedChannel = channel
            dismiss()
        } label: {
            HStack {
                Image(systemName: icon).frame(width: 24).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text(store.title(for: channel)).foregroundStyle(Color.primary)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if let unread = store.unread[channel], unread > 0 {
                    Text("\(unread)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                if store.selectedChannel == channel {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct PeopleSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Peer?

    var body: some View {
        NavigationStack {
            List {
                if !store.impostors.isEmpty {
                    Section {
                        ForEach(store.impostors) { peer in
                            Label {
                                Text("Someone nearby is using the name **\(peer.nickname)**, but it isn't the person you verified. It may be a new phone, or someone pretending.")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                            }
                            .font(.callout)
                        }
                    }
                }
                if store.peers.isEmpty {
                    ContentUnavailableView(
                        "No one nearby yet",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("HelloLetter finds phones running HelloLetter within Bluetooth range, and people they can reach.")
                    )
                    // Bluetooth chat needs Letterbox on both phones.
                    ShareLink(item: ShareText.invite(from: store.nickname)) {
                        RowLabel("Invite someone to get HelloLetter", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("people-invite")
                }
                ForEach(store.peers) { peer in
                    HStack(spacing: 12) {
                        Button {
                            store.openDirect(with: peer)
                            dismiss()
                        } label: {
                            PersonRow(peer: peer, isVerified: store.isVerified(peer.fingerprint))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens a private chat")

                        Button { selected = peer } label: {
                            Image(systemName: "info.circle").imageScale(.large)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Details and verify \(peer.nickname)")
                        .accessibilityIdentifier("person-info-\(peer.nickname)")
                    }
                }
            }
            // Keep the first header clear of the bar's scroll-edge fade.
            .contentMargins(.top, 24, for: .scrollContent)
            .navigationTitle("Nearby")
            .inlineTitle()
            .navigationDestination(item: $selected) { peer in PersonView(peer: peer) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// One person: who, how they're reached, and whether you've verified them. Never shows
/// raw codes; those live on the person's Verify screen.
struct PersonRow: View {
    let peer: Peer
    let isVerified: Bool
    /// The avatar grows with the text size, so its initial is never cut off.
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            Text(String(peer.nickname.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: avatarSize, height: avatarSize)
                .background(Theme.color(for: peer.fingerprint.hex), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(peer.nickname).font(.body).foregroundStyle(Color.primary)
                    if isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Theme.good)
                            .accessibilityLabel("Verified")
                    }
                }
                RowLabel(peer.isDirect ? "In direct range" : "Reached through others",
                      systemImage: peer.isDirect ? "dot.radiowaves.left.and.right" : "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var confirmingErase = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: SectionHeader("Nickname")) {
                    TextField("Nickname", text: $nickname)
                        .onSubmit(save)
                        .accessibilityIdentifier("nickname-field")
                    // Only offered when there's a change: a greyed-out button is hard to read
                    // and reads as broken.
                    if !Nickname.sanitize(nickname).isEmpty, Nickname.sanitize(nickname) != store.nickname {
                        Button("Save", action: save)
                    }
                }
                Section {
                    Picker("Theme", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("theme-picker")
                } header: {
                    SectionHeader("Appearance")
                } footer: {
                    SectionFooter("Pager: an LCD screen with a seven-segment clock and dot-matrix headings, like a 90s pager. Messages stay in a clear font.")
                }
                Section {
                    NavigationLink { MyCodeView() } label: {
                        RowLabel("Your safety code", systemImage: "qrcode")
                    }
                    NavigationLink { HelpView() } label: {
                        RowLabel("Help and safety", systemImage: "lifepreserver")
                    }
                    .accessibilityIdentifier("help-and-safety")
                } footer: {
                    SectionFooter("Friends scan this in person to know messages really come from you. Anyone can copy a nickname, but not a code.")
                }
                Section {
                    Toggle(isOn: Binding(get: { store.showsTextInNotifications },
                                         set: { store.setShowsTextInNotifications($0) })) {
                        RowLabel("Show names and text in alerts", systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("notification-text-toggle")
                } header: {
                    SectionHeader("Alerts")
                } footer: {
                    SectionFooter("Off: alerts only say a message arrived, since anyone can read a locked screen. Always hidden with the privacy screen on.")
                }
                Section(header: SectionHeader("How it works")) {
                    RowLabel("Messages hop between phones over Bluetooth. No internet, no accounts.", systemImage: "antenna.radiowaves.left.and.right")
                    RowLabel("Private messages are encrypted; phones passing them on can't read them.", systemImage: "lock")
                    RowLabel("Someone out of reach? Hikers you pass carry your message in a sealed envelope.", systemImage: "envelope")
                    RowLabel("Chats live in memory. Only undelivered messages are saved, encrypted.", systemImage: "memorychip")
                }
                .font(.callout)
                // Destructive and rare: last, where iOS puts it.
                Section {
                    Button(role: .destructive) { confirmingErase = true } label: {
                        RowLabel("Erase everything", systemImage: "trash")
                            .foregroundStyle(Theme.bad) // the system red is just under 4.5:1
                    }
                    .accessibilityIdentifier("erase-everything")
                } footer: {
                    SectionFooter("Deletes everything HelloLetter keeps on this phone, including who you are. Can't be undone.")
                }
            }
            // Keep the first header clear of the bar's scroll-edge fade, and the last
            // footer (under Erase everything) clear of the bottom edge.
            .contentMargins(.top, 24, for: .scrollContent)
            .contentMargins(.bottom, 40, for: .scrollContent)
            .navigationTitle("Settings")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { nickname = store.nickname }
            .confirmationDialog("Erase everything from this device?", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) {
                    Task {
                        await store.eraseEverything()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("confirm-erase")
            } message: {
                Text("HelloLetter stops, and next time it opens you'll be someone new. People you verified will see a new safety number.")
            }
        }
    }

    private func save() {
        Task { await store.setNickname(nickname) }
    }
}
