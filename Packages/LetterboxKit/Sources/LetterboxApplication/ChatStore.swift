import Foundation
import LetterboxDomain
import Observation

/// The app's state and use cases, observed by SwiftUI.
///
/// Depends only on domain ports, so it works the same with the real Bluetooth and
/// Nostr adapters or with fakes in tests. Messages live in memory only.
@MainActor
@Observable
public final class ChatStore {
    public private(set) var nickname: String
    public private(set) var peers: [Peer] = []
    public private(set) var radio: RadioState = .unknown
    public private(set) var relays: (connected: Int, total: Int) = (0, 0)
    public private(set) var location: (geohash: String, level: GeohashLevel)?
    public private(set) var locationError: String?
    public var selectedChannel: ChannelID = .mesh {
        didSet { channelOpened(selectedChannel) }
    }

    /// Privacy mode: the UI blurs message text so people nearby can't read over your shoulder.
    public private(set) var hidesMessages: Bool
    /// Our envelopes on their way, and how many we carry for others.
    public private(set) var envelopes = EnvelopeSummary.empty
    /// What the device reports about its network, mobile radio and location permission.
    public private(set) var connectivity = SystemConnectivity.unknown
    /// Which ways of communicating the user lets Letterbox use.
    public private(set) var permissions: TransportPermissions
    /// People whose safety number you've compared in person, with their name at the time.
    public private(set) var verified: [Fingerprint: String] = [:]
    /// People whose messages you don't want to see, with their name at the time.
    public private(set) var blocked: [Fingerprint: String] = [:]
    /// Lock-screen alerts show who wrote and what. Off by default: anyone can read a
    /// locked phone's screen.
    public private(set) var showsTextInNotifications: Bool
    /// Everything was erased; the app does nothing more until it's reopened.
    public private(set) var isErased = false
    /// Offensive words in other people's messages are masked on this phone. On by default.
    public private(set) var filtersOffensiveWords: Bool
    /// Location channels (public chat over the internet) are part of this build. The App
    /// Store build leaves them out: Letterbox is for when there's no internet.
    public let offersLocationChannels: Bool

    public private(set) var unread: [ChannelID: Int] = [:]
    private var timelines: [ChannelID: [ChatMessage]] = [:]
    /// Direct-message partners we have talked to, with the last known nickname.
    public private(set) var directContacts: [Fingerprint: String] = [:]
    /// Delivery updates that arrived before the outgoing message was stored.
    private var earlyDelivery: [String: DeliveryState] = [:]

    public let myFingerprint: Fingerprint
    private let mesh: any MeshTransport
    private let locationChannels: any LocationChannelTransport
    private let locationProvider: any LocationProvider
    private let settings: any SettingsStore
    private let connectivityMonitor: (any ConnectivityMonitor)?
    private let appState: (any BlobStore)?
    private let notifier: (any MessageNotifier)?
    private let eraser: (any LocalDataEraser)?
    private var tasks: [Task<Void, Never>] = []
    /// Whether Letterbox is on screen. Alerts are shown only when it isn't.
    private var isActive = true
    private var askedForNotifications = false
    /// Messages alerted per conversation since the user last looked.
    private var alerted: [ChannelID: Int] = [:]
    private static let maxMessagesPerChannel = 1000
    private static let nicknameKey = "nickname"
    static let hideMessagesKey = "privacy.hideMessages"
    static let bluetoothKey = "transport.bluetooth"
    static let internetKey = "transport.internet"
    static let notificationTextKey = "notifications.showText"
    static let filterKey = "safety.filterWords"

    public init(
        mesh: any MeshTransport,
        locationChannels: any LocationChannelTransport,
        locationProvider: any LocationProvider,
        settings: any SettingsStore,
        connectivity: (any ConnectivityMonitor)? = nil,
        appState: (any BlobStore)? = nil,
        notifier: (any MessageNotifier)? = nil,
        eraser: (any LocalDataEraser)? = nil,
        offersLocationChannels: Bool = true
    ) {
        self.mesh = mesh
        self.locationChannels = locationChannels
        self.locationProvider = locationProvider
        self.settings = settings
        connectivityMonitor = connectivity
        self.appState = appState
        self.notifier = notifier
        self.eraser = eraser
        self.offersLocationChannels = offersLocationChannels
        myFingerprint = mesh.myFingerprint
        let saved = settings.string(for: Self.nicknameKey).map(Nickname.sanitize) ?? ""
        nickname = saved.isEmpty ? Nickname.random() : saved
        hidesMessages = settings.string(for: Self.hideMessagesKey) == "1"
        showsTextInNotifications = settings.string(for: Self.notificationTextKey) == "1"
        filtersOffensiveWords = settings.string(for: Self.filterKey) != "0"
        permissions = TransportPermissions(
            bluetooth: settings.string(for: Self.bluetoothKey) != "0",
            internet: settings.string(for: Self.internetKey) != "0"
        )
        settings.set(nickname, for: Self.nicknameKey)
        if let data = appState?.load(), let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            verified = Dictionary(saved.verified.map { ($0.fingerprint, $0.nickname) }, uniquingKeysWith: { _, last in last })
            blocked = Dictionary((saved.blocked ?? []).map { ($0.fingerprint, $0.nickname) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// What the store keeps across launches (encrypted by the adapter in the app).
    private struct SavedState: Codable {
        struct Verified: Codable {
            var fingerprint: Fingerprint
            var nickname: String
        }
        var verified: [Verified]
        /// Added later; absent in older files.
        var blocked: [Verified]?
    }

    // MARK: - Lifecycle

    public func start() async {
        guard tasks.isEmpty else { return }
        let meshEvents = mesh.events
        let locationEvents = locationChannels.events
        tasks.append(Task { [weak self] in
            for await event in meshEvents { self?.apply(event) }
        })
        tasks.append(Task { [weak self] in
            for await event in locationEvents { self?.apply(event) }
        })
        if let connectivityMonitor {
            let updates = connectivityMonitor.updates
            tasks.append(Task { [weak self] in
                for await reading in updates { self?.connectivity = reading }
            })
            connectivityMonitor.start()
        }
        await mesh.setNickname(nickname)
        if permissions.bluetooth { await mesh.start() }
    }

    public func stop() async {
        await mesh.stop()
        await locationChannels.leave()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    // MARK: - Reading state

    /// The conversation as shown: other people's offensive words masked if the filter is on.
    public func messages(in channel: ChannelID) -> [ChatMessage] {
        let timeline = timelines[channel] ?? []
        return filtersOffensiveWords ? timeline.map(displayed) : timeline
    }

    public func peer(for fingerprint: Fingerprint) -> Peer? {
        peers.first { $0.fingerprint == fingerprint }
    }

    public func title(for channel: ChannelID) -> String {
        switch channel {
        case .mesh: "#nearby"
        case let .location(geohash): "#\(geohash)"
        case let .direct(fingerprint): "@" + (peer(for: fingerprint)?.nickname ?? directContacts[fingerprint] ?? fingerprint.short)
        }
    }

    public var directChannels: [ChannelID] {
        directContacts.keys.sorted { $0.hex < $1.hex }.map(ChannelID.direct)
    }

    // MARK: - Use cases

    public func submit(_ raw: String) async {
        guard !isErased else { return }
        switch ComposerInput.parse(raw) {
        case .empty:
            return
        case let .text(text):
            await send(text, in: selectedChannel)
        case let .nick(name):
            await setNickname(name)
        case let .directMessage(name, text):
            guard let target = peers.first(where: { $0.nickname.caseInsensitiveCompare(name) == .orderedSame }) else {
                system("No one called \(name) is nearby.")
                return
            }
            openDirect(with: target)
            await send(text, in: .direct(target.fingerprint))
        case .who:
            system(peers.isEmpty ? "No one nearby yet." : "Nearby: " + peers.map(\.nickname).joined(separator: ", "))
        case .clear:
            timelines[selectedChannel] = []
        case .help:
            system(ComposerInput.helpText)
        case let .unknown(command):
            system("Unknown command \(command). Type /help.")
        }
    }

    /// A private message that wasn't delivered: take it out of the conversation and send
    /// the same text again, as a new message with a fresh 3 days to arrive.
    public func sendAgain(_ message: ChatMessage) async {
        guard !isErased, message.isOwn, message.delivery == .failed else { return }
        timelines[message.channel]?.removeAll { $0.id == message.id }
        await send(message.text, in: message.channel)
    }

    public func setNickname(_ raw: String) async {
        let clean = Nickname.sanitize(raw)
        guard !clean.isEmpty else { return }
        nickname = clean
        settings.set(clean, for: Self.nicknameKey)
        await mesh.setNickname(clean)
    }

    // MARK: - Permissions

    /// Lets Letterbox use Bluetooth (nearby chat, relaying, envelopes) or stops it entirely.
    public func setBluetoothAllowed(_ allowed: Bool) async {
        guard allowed != permissions.bluetooth else { return }
        permissions.bluetooth = allowed
        settings.set(allowed ? "1" : "0", for: Self.bluetoothKey)
        guard !tasks.isEmpty else { return } // not started yet: start() will respect it
        if allowed {
            await mesh.setNickname(nickname)
            await mesh.start()
        } else {
            await mesh.stop()
            peers = []
        }
    }

    /// Lets Letterbox use the internet (location channels now; private messages and photos later).
    public func setInternetAllowed(_ allowed: Bool) async {
        guard allowed != permissions.internet else { return }
        permissions.internet = allowed
        settings.set(allowed ? "1" : "0", for: Self.internetKey)
        if !allowed {
            await leaveLocation()
            relays = (0, 0)
        }
    }

    /// One row per way of communicating: whether it works, and what it lets you do.
    public var connectionRows: [ConnectionRow] {
        ConnectionReport.rows(
            system: connectivity,
            radio: radio,
            permissions: permissions,
            nearby: peers.count,
            relays: relays,
            inLocationChannel: location != nil,
            envelopes: envelopes,
            offersLocationChannels: offersLocationChannels
        )
    }

    // MARK: - Verification

    public func isVerified(_ fingerprint: Fingerprint) -> Bool {
        verified[fingerprint] != nil
    }

    /// After comparing safety numbers in person, or scanning their code.
    public func markVerified(_ fingerprint: Fingerprint, nickname: String) {
        verified[fingerprint] = Nickname.sanitize(nickname)
        saveState()
    }

    public func clearVerification(_ fingerprint: Fingerprint) {
        guard verified.removeValue(forKey: fingerprint) != nil else { return }
        saveState()
    }

    /// People nearby using the name of someone you verified, but with a different key.
    /// It may be the same person on a new phone, or someone pretending.
    public var impostors: [Peer] {
        let verifiedNames = Set(verified.values.map { $0.lowercased() })
        return peers.filter { verified[$0.fingerprint] == nil && verifiedNames.contains($0.nickname.lowercased()) }
    }

    private func saveState() {
        guard !isErased else { return }
        func list(_ people: [Fingerprint: String]) -> [SavedState.Verified] {
            people.map { SavedState.Verified(fingerprint: $0.key, nickname: $0.value) }.sorted { $0.fingerprint.hex < $1.fingerprint.hex }
        }
        let state = SavedState(verified: list(verified), blocked: list(blocked))
        if let data = try? JSONEncoder().encode(state) { try? appState?.save(data) }
    }

    public func setHidesMessages(_ hidden: Bool) {
        hidesMessages = hidden
        settings.set(hidden ? "1" : "0", for: Self.hideMessagesKey)
    }

    public func toggleHidesMessages() {
        setHidesMessages(!hidesMessages)
    }

    public func setShowsTextInNotifications(_ shown: Bool) {
        showsTextInNotifications = shown
        settings.set(shown ? "1" : "0", for: Self.notificationTextKey)
    }

    /// Called by the UI when Letterbox comes on screen or goes off it.
    public func setActive(_ active: Bool) {
        isActive = active
        if active { clearAlerts(for: selectedChannel) }
    }

    // MARK: - Blocking

    public func isBlocked(_ fingerprint: Fingerprint) -> Bool {
        blocked[fingerprint] != nil
    }

    /// Hides everything this person sends, now and later, until unblocked. Their messages
    /// are still passed on for other people (the mesh needs every phone), just not shown.
    public func block(_ fingerprint: Fingerprint, nickname: String) {
        blocked[fingerprint] = Nickname.sanitize(nickname)
        for channel in timelines.keys {
            timelines[channel]?.removeAll { $0.senderKey == fingerprint.hex && !$0.isOwn }
        }
        saveState()
    }

    public func unblock(_ fingerprint: Fingerprint) {
        guard blocked.removeValue(forKey: fingerprint) != nil else { return }
        saveState()
    }

    private func isFromBlocked(_ message: ChatMessage) -> Bool {
        guard !message.isOwn, !blocked.isEmpty else { return false }
        return blocked.keys.contains { $0.hex == message.senderKey }
    }

    /// Reports a message: its sender is blocked straight away (or, if they couldn't be
    /// identified, the message is hidden). Sending the report by email is up to the UI,
    /// with `ReportText`.
    public func report(_ message: ChatMessage) {
        guard !message.isOwn, message.senderKey != "system" else { return }
        if Self.isFingerprint(message.senderKey) {
            block(Fingerprint(hex: message.senderKey), nickname: message.senderName)
        } else {
            timelines[message.channel]?.removeAll { $0.id == message.id }
        }
    }

    public func setFiltersOffensiveWords(_ on: Bool) {
        filtersOffensiveWords = on
        settings.set(on ? "1" : "0", for: Self.filterKey)
    }

    /// Other people's words, with offensive ones masked if the filter is on.
    public func displayed(_ message: ChatMessage) -> ChatMessage {
        guard filtersOffensiveWords, !message.isOwn, message.senderKey != "system" else { return message }
        let text = ContentFilter.mask(message.text)
        let name = ContentFilter.mask(message.senderName)
        guard text != message.text || name != message.senderName else { return message }
        return ChatMessage(id: message.id, channel: message.channel, senderName: name, senderKey: message.senderKey,
                           text: text, timestamp: message.timestamp, isOwn: message.isOwn,
                           isVerified: message.isVerified, delivery: message.delivery)
    }

    /// The message as it was received, unmasked: what a report should contain.
    public func original(_ message: ChatMessage) -> ChatMessage {
        timelines[message.channel]?.first { $0.id == message.id } ?? message
    }

    static func isFingerprint(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy(\.isHexDigit)
    }

    // MARK: - Erasing

    /// Deletes everything Letterbox keeps on this device and stops it. Bluetooth goes
    /// quiet, messages on screen disappear, and the next launch starts as a new person.
    public func eraseEverything() async {
        guard !isErased else { return }
        await mesh.stop() // stops first, so nothing is saved again after the wipe
        await locationChannels.leave()
        isErased = true
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        eraser?.eraseAll()
        notifier?.clearAll()
        timelines = [:]
        unread = [:]
        alerted = [:]
        peers = []
        directContacts = [:]
        verified = [:]
        blocked = [:]
        envelopes = .empty
        location = nil
        selectedChannel = .mesh
    }

    // MARK: - Alerts

    private func askForNotificationsOnce() async {
        guard !askedForNotifications, let notifier else { return }
        askedForNotifications = true
        await notifier.requestPermission() // asked when you first send, when a reply makes sense
    }

    /// Alerts for a live message from someone else while Letterbox is off screen. Only
    /// #nearby and private messages: location channels can be busy, and caught-up history
    /// is old news.
    private func alertIfNeeded(_ message: ChatMessage) {
        guard let notifier, !isActive, !message.isOwn, !isErased else { return }
        switch message.channel {
        case .mesh, .direct: break
        case .location: return
        }
        alerted[message.channel, default: 0] += 1
        let showText = showsTextInNotifications && !hidesMessages // the privacy screen hides alerts too
        notifier.show(NotificationText.alert(for: message, count: alerted[message.channel] ?? 1, showText: showText))
    }

    private func clearAlerts(for channel: ChannelID) {
        alerted[channel] = nil
        notifier?.clear(conversation: NotificationText.conversation(channel))
    }

    public func openDirect(with peer: Peer) {
        directContacts[peer.fingerprint] = peer.nickname
        selectedChannel = .direct(peer.fingerprint)
    }

    public func joinLocation(_ level: GeohashLevel) async {
        guard offersLocationChannels else { return }
        guard permissions.internet else {
            locationError = "The internet is off in Letterbox. Turn it on in Connections to join location channels."
            return
        }
        locationError = nil
        do {
            let coordinate = try await locationProvider.currentCoordinate()
            let geohash = Geohash.encode(coordinate, precision: level.precision)
            location = (geohash, level)
            await locationChannels.join(geohash: geohash)
            selectedChannel = .location(geohash: geohash)
        } catch LocationError.denied {
            locationError = "Location access is off. Turn it on in Settings to use location channels."
        } catch {
            locationError = "Couldn't get your location. Try again outside or near a window."
        }
    }

    public func leaveLocation() async {
        if case .location = selectedChannel { selectedChannel = .mesh }
        location = nil
        await locationChannels.leave()
    }

    private func send(_ text: String, in channel: ChannelID) async {
        await askForNotificationsOnce()
        switch channel {
        case .mesh:
            guard permissions.bluetooth else {
                system("Bluetooth is off in Letterbox, so #nearby can't send. Turn it on in Connections.")
                return
            }
            append(await mesh.sendPublic(text))
        case .location:
            guard permissions.internet else {
                system("The internet is off in Letterbox. Turn it on in Connections to post here.")
                return
            }
            if let message = await locationChannels.send(text, nickname: nickname) {
                append(message)
            } else {
                system("Not connected to a location channel.")
            }
        case let .direct(fingerprint):
            let route = RoutePlanner.route(
                for: .text,
                recipientNearby: peer(for: fingerprint) != nil,
                recipientKeyKnown: await mesh.canSeal(to: fingerprint),
                recipientHasInternetAddress: false, // internet messaging arrives in phase 2
                permissions: permissions,
                internetOnline: connectivity.internet.isOnline
            )
            if case let .impossible(reason) = route {
                system(reason)
                return
            }
            var message = await mesh.sendPrivate(text, to: fingerprint)
            if let early = earlyDelivery.removeValue(forKey: message.id) { message.delivery = early }
            append(message)
            if !permissions.bluetooth, case let .queue(reason) = route { system(reason) }
        }
    }

    // MARK: - Applying transport events

    private func apply(_ event: MeshEvent) {
        switch event {
        case let .peersChanged(list):
            peers = list
            for peer in list where directContacts[peer.fingerprint] != nil {
                directContacts[peer.fingerprint] = peer.nickname
            }
        case let .publicMessage(message):
            guard !isFromBlocked(message) else { return }
            if append(message) { alertIfNeeded(message) }
        case let .publicHistory(message):
            guard !isFromBlocked(message) else { return }
            append(message, inTimeOrder: true)
        case let .privateMessage(message):
            guard !isFromBlocked(message) else { return }
            if case let .direct(fingerprint) = message.channel {
                directContacts[fingerprint] = message.senderName
            }
            if append(message) { alertIfNeeded(message) }
            if message.channel == selectedChannel, case let .direct(fingerprint) = message.channel {
                Task { await mesh.markRead(messageIDs: [message.id], from: fingerprint) }
            }
        case let .deliveryChanged(id, state):
            updateDelivery(id, state)
        case let .radioChanged(state):
            radio = state
        case let .envelopesChanged(summary):
            envelopes = summary
        case let .outgoingRestored(message, recipientName):
            if case let .direct(fingerprint) = message.channel, directContacts[fingerprint] == nil {
                directContacts[fingerprint] = recipientName
            }
            append(message)
        }
    }

    private func apply(_ event: LocationEvent) {
        switch event {
        case let .message(message):
            guard !isFromBlocked(message) else { return }
            append(message)
        case let .relaysChanged(connected, total):
            relays = (connected, total)
        }
    }

    /// Adds a message once. Live messages go at the end; caught-up ones (`inTimeOrder`)
    /// are placed by when they were sent, so the conversation still reads in order.
    @discardableResult
    private func append(_ message: ChatMessage, inTimeOrder: Bool = false) -> Bool {
        var timeline = timelines[message.channel] ?? []
        guard !timeline.contains(where: { $0.id == message.id }) else { return false }
        if inTimeOrder, let index = timeline.lastIndex(where: { $0.timestamp <= message.timestamp }) {
            timeline.insert(message, at: index + 1)
        } else if inTimeOrder {
            timeline.insert(message, at: 0)
        } else {
            timeline.append(message)
        }
        if timeline.count > Self.maxMessagesPerChannel {
            timeline.removeFirst(timeline.count - Self.maxMessagesPerChannel)
        }
        timelines[message.channel] = timeline
        if message.channel != selectedChannel, !message.isOwn {
            unread[message.channel, default: 0] += 1
        }
        return true
    }

    private func updateDelivery(_ id: String, _ state: DeliveryState) {
        for (channel, timeline) in timelines {
            guard case .direct = channel, let index = timeline.firstIndex(where: { $0.id == id }) else { continue }
            let current = timeline[index].delivery
            // Never move backwards (a late "sent" must not undo "read"), and only
            // something not yet delivered can fail.
            let allowed = state == .failed
                ? Self.rank(current) <= Self.rank(.sent)
                : Self.rank(state) > Self.rank(current)
            guard allowed else { return }
            timelines[channel]?[index].delivery = state
            return
        }
        earlyDelivery[id] = state
    }

    private static func rank(_ state: DeliveryState?) -> Int {
        switch state {
        case nil: 0
        case .queued: 1
        case .failed: 1
        case .inEnvelope: 2
        case .sent: 3
        case .delivered: 4
        case .read: 5
        }
    }

    private func channelOpened(_ channel: ChannelID) {
        unread[channel] = nil
        clearAlerts(for: channel)
        guard case let .direct(fingerprint) = channel else { return }
        let unreadIDs = messages(in: channel).filter { !$0.isOwn }.map(\.id)
        Task { await mesh.markRead(messageIDs: unreadIDs, from: fingerprint) }
    }

    private func system(_ text: String) {
        append(ChatMessage(
            id: UUID().uuidString,
            channel: selectedChannel,
            senderName: "system",
            senderKey: "system",
            text: text,
            timestamp: Date(),
            isOwn: true,
            isVerified: true
        ))
    }
}
