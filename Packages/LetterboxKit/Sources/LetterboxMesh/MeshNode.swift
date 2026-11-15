import Foundation
import LetterboxCrypto
import LetterboxDomain
import LetterboxWire

/// The mesh engine. Implements the `MeshTransport` port on top of any `LinkLayer`.
///
/// Inbound pipeline for every frame:
///   decode → dedup → freshness → dispatch by type (verify / decrypt) → relay
///
/// Relaying is a controlled flood: TTL starts at 7 and drops by one per hop, each
/// packet ID is handled once, relays wait a random jitter, never send a packet
/// back out of the link it came in on, and send directed packets only toward the
/// recipient when it is a direct neighbour.
public actor MeshNode: MeshTransport {
    public struct Configuration: Sendable {
        public var defaultTTL: UInt8 = 7
        public var announceInterval: TimeInterval = 15
        public var peerTimeout: TimeInterval = 60
        public var maxClockSkew: TimeInterval = 600
        public var relayJitter: ClosedRange<Double> = 0.01...0.15
        public var handshakeTimeout: TimeInterval = 10
        /// How long a private message keeps trying before it's marked as failed.
        /// Three days, so it survives a multi-day trek.
        public var outboxLifetime: TimeInterval = 3 * 24 * 60 * 60
        /// Oldest queued messages are failed beyond this many.
        public var maxQueuedMessages = 500
        public var maintenanceInterval: TimeInterval = 5
        /// After hearing a new peer through relays, announce ourselves at most this often,
        /// so the far side learns us without waiting for the next periodic announce.
        public var newPeerAnnounceCooldown: TimeInterval = 2
        /// A message that hasn't gone out after this long is sealed and handed to
        /// passing phones (couriers) as well.
        public var courierDelay: TimeInterval = 10
        /// How many different couriers get a copy of one message.
        public var maxCourierCopies = 8
        /// Envelopes carried for other people, at most.
        public var maxCarriedEnvelopes = 256
        /// Longest we carry someone else's envelope, whatever its own expiry says.
        public var maxCarryTime: TimeInterval = 3 * 24 * 60 * 60
        /// People remembered so we can seal messages to them after they've gone.
        public var maxContacts = 500
        /// A courier hands an envelope to someone reached through relays at most this
        /// often (in case the hand-off was lost). Direct neighbours get it straight away.
        public var courierRetryInterval: TimeInterval = 30

        // Abuse limits (see docs/security-assessment.md, SEC-01 to SEC-03).
        /// People tracked at once. Beyond this, the least recently heard peer that is
        /// neither a direct neighbour nor in a session is forgotten.
        public var maxPeers = 256
        /// New identities accepted per Bluetooth link per minute (burst of the same size).
        public var newPeersPerLinkPerMinute: Double = 32
        /// Public messages per sender per minute, shown and relayed (burst of the same size).
        public var publicMessagesPerSenderPerMinute: Double = 20
        /// Public messages per link per minute from senders we haven't heard announce,
        /// whose name can't be checked (burst of the same size).
        public var unverifiedMessagesPerLinkPerMinute: Double = 30
        /// Directed packets (handshakes, private messages) relayed per sender per minute.
        public var relayedDirectedPerSenderPerMinute: Double = 120
        /// Receipts kept waiting per person; beyond this, receipt IDs are merged or dropped.
        public var maxPendingReceiptsPerPerson = 2
        /// Message IDs carried in one merged receipt.
        public var maxIDsPerReceipt = 50
        /// Envelopes accepted for carrying per Bluetooth link per minute (burst of the same size).
        public var envelopesPerLinkPerMinute: Double = 30
        /// Share of the carried envelopes one depositor (link) can fill.
        public var maxCarriedPerDepositor = 32

        // Catching up on #nearby (messages sent while you were out of range or off).
        /// How far back missed #nearby messages are offered and accepted. Long enough
        /// for a day out of range; the messages are kept in memory only.
        public var publicHistoryWindow: TimeInterval = 12 * 60 * 60
        /// #nearby messages kept to pass on to phones that missed them.
        public var maxArchivedPublicMessages = 300
        /// Most messages sent in answer to one catch-up request.
        public var maxSyncMessages = 100
        /// Answers to our catch-up request are accepted for this long.
        public var syncResponseWindow: TimeInterval = 30
        /// Ask, or answer, the same link at most this often.
        public var syncInterval: TimeInterval = 60

        public init() {}
    }

    static let prologue = Data("letterbox/mesh/1".utf8)
    private static let maxBufferedCiphertexts = 16
    private static let maxPendingHandshakes = 32
    /// Recent envelope and message IDs kept across restarts to recognise replays.
    private static let persistedRecentIDs = 1000

    public nonisolated let events: AsyncStream<MeshEvent>
    public nonisolated let myFingerprint: Fingerprint
    public nonisolated let peerID: PeerID

    private let continuation: AsyncStream<MeshEvent>.Continuation
    private let link: any LinkLayer
    private let identity: IdentityKeys
    private let config: Configuration
    private let now: @Sendable () -> Date
    private var nickname: String

    private var peers: [PeerID: PeerRecord] = [:]
    private var seen = SeenPackets()
    private var sessions: [PeerID: Session] = [:]
    private var bufferedCiphertexts: [PeerID: [EncryptedPayload]] = [:]
    /// First handshake messages from senders whose announce hasn't reached us yet.
    /// A relayed announce and a handshake can arrive in either order across the mesh.
    private var pendingHandshakes: [PeerID: (message: HandshakePayload, received: Date)] = [:]
    private var lastNewPeerAnnounce: Date?
    /// Waiting for a secure session with that person.
    private var outbox: [Fingerprint: [OutgoingPrivate]] = [:]
    /// Sent, not yet acknowledged; resent if the session is replaced.
    private var awaitingAck: [Fingerprint: [OutgoingPrivate]] = [:]
    private var receivedIDs = RecentIDs()
    private var tasks: [Task<Void, Never>] = []
    /// Reads link events for the node's whole life. An AsyncStream ends for good when its
    /// reader is cancelled, so this one survives `stop()` and events are ignored instead.
    private var linkTask: Task<Void, Never>?
    private var running = false
    private var lastEnvelopes = EnvelopeSummary.empty
    private var newPeerLimiter: RateLimiter<LinkID>
    private var publicLimiter: RateLimiter<PeerID>
    private var unverifiedLimiter: RateLimiter<LinkID>
    private var directedRelayLimiter: RateLimiter<PeerID>
    private var depositLimiter: RateLimiter<LinkID>

    // Store and forward.
    private var contacts: [Fingerprint: Contact] = [:]
    private var carried: CarriedEnvelopes
    private var openedEnvelopes = RecentIDs()
    // Catching up on #nearby.
    private var archive: PublicArchive
    private var pendingSyncs: [LinkID: PendingSync] = [:]
    private var lastSyncRequest: [LinkID: Date] = [:]
    private var lastSyncServed: [LinkID: Date] = [:]
    // Persistence.
    private let store: (any BlobStore)?
    private var dirty = false
    private var restoredMessages: [(ChatMessage, String)] = []

    public init(
        identity: IdentityKeys,
        nickname: String,
        link: any LinkLayer,
        configuration: Configuration = Configuration(),
        peerID: PeerID = .random(),
        store: (any BlobStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = identity
        self.nickname = nickname
        self.link = link
        self.config = configuration
        self.peerID = peerID
        self.store = store
        self.now = now
        myFingerprint = identity.fingerprint
        carried = CarriedEnvelopes(capacity: configuration.maxCarriedEnvelopes, maxLifetime: configuration.maxCarryTime)
        archive = PublicArchive(capacity: configuration.maxArchivedPublicMessages)
        newPeerLimiter = RateLimiter(capacity: configuration.newPeersPerLinkPerMinute, perMinute: configuration.newPeersPerLinkPerMinute)
        publicLimiter = RateLimiter(capacity: configuration.publicMessagesPerSenderPerMinute,
                                    perMinute: configuration.publicMessagesPerSenderPerMinute)
        unverifiedLimiter = RateLimiter(capacity: configuration.unverifiedMessagesPerLinkPerMinute,
                                        perMinute: configuration.unverifiedMessagesPerLinkPerMinute)
        directedRelayLimiter = RateLimiter(capacity: configuration.relayedDirectedPerSenderPerMinute,
                                           perMinute: configuration.relayedDirectedPerSenderPerMinute)
        depositLimiter = RateLimiter(capacity: configuration.envelopesPerLinkPerMinute,
                                     perMinute: configuration.envelopesPerLinkPerMinute)
        (events, continuation) = AsyncStream.makeStream(of: MeshEvent.self, bufferingPolicy: .bufferingNewest(512))

        if let data = store?.load(), let snapshot = try? JSONDecoder().decode(MeshSnapshot.self, from: data),
           snapshot.version == MeshSnapshot.currentVersion {
            let restored = Self.restore(snapshot, configuration: configuration, me: identity.fingerprint)
            outbox = restored.outbox
            contacts = restored.contacts
            carried = restored.carried
            restoredMessages = restored.messages
            openedEnvelopes = RecentIDs(restoring: snapshot.openedEnvelopes ?? [])
            receivedIDs = RecentIDs(restoring: snapshot.receivedMessageIDs ?? [])
        }
    }

    // MARK: - MeshTransport

    public func start() {
        guard !running else { return }
        running = true
        for (message, recipientName) in restoredMessages {
            continuation.yield(.outgoingRestored(message, recipientName: recipientName))
        }
        restoredMessages = []
        publishEnvelopes()
        if linkTask == nil {
            let linkEvents = link.events
            linkTask = Task {
                for await event in linkEvents {
                    self.handle(event)
                }
            }
        }
        tasks.append(Task {
            while !Task.isCancelled {
                self.broadcastAnnounce()
                let jitter = Double.random(in: 0.8...1.2)
                try? await Task.sleep(for: .seconds(self.config.announceInterval * jitter))
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.config.maintenanceInterval))
                self.maintain()
            }
        })
        link.start()
    }

    public func stop() {
        guard running else { return }
        if let packet = makePacket(.leave, payload: Data(), sign: true) {
            transmit(packet)
        }
        running = false
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        link.stop()
        // Our leave makes everyone drop their sessions with us, so drop ours too.
        // Anything sent but not acknowledged goes back in the outbox and is resent
        // over a fresh session once we're back.
        for (fingerprint, unacked) in awaitingAck {
            outbox[fingerprint] = unacked + (outbox[fingerprint] ?? [])
        }
        awaitingAck = [:]
        sessions = [:]
        peers = [:]
        pendingHandshakes = [:]
        bufferedCiphertexts = [:]
        dirty = true
        persist()
    }

    public func setNickname(_ newValue: String) {
        nickname = Nickname.sanitize(newValue)
        if running { broadcastAnnounce() }
    }

    public func sendPublic(_ text: String) -> ChatMessage {
        let payload = PublicMessagePayload(nickname: nickname, text: text)
        let packet = makePacket(.publicMessage, payload: payload.encoded(), sign: true)
        if let packet {
            transmit(packet)
            if let announce = makeAnnounce() { archive.insert(.init(message: packet, announce: announce)) }
        }
        return ChatMessage(
            id: packet?.packetID.hexString ?? UUID().uuidString,
            channel: .mesh,
            senderName: nickname,
            senderKey: myFingerprint.hex,
            text: text,
            timestamp: now(),
            isOwn: true,
            isVerified: true
        )
    }

    public func sendPrivate(_ text: String, to recipient: Fingerprint) -> ChatMessage {
        let id = UUID().uuidString
        let timestamp = now()
        let item = OutgoingPrivate(
            payload: .message(id: id, nickname: nickname, text: text, timestamp: timestamp.milliseconds),
            created: timestamp
        )
        outbox[recipient, default: []].append(item)
        enforceQueueLimit()
        let sent = pump(recipient, silentFor: id)
        dirty = true
        persist() // a message the user just wrote shouldn't be lost if the app is killed
        return ChatMessage(
            id: id,
            channel: .direct(recipient),
            senderName: nickname,
            senderKey: myFingerprint.hex,
            text: text,
            timestamp: timestamp,
            isOwn: true,
            isVerified: true,
            delivery: sent.contains(id) ? .sent : .queued
        )
    }

    public func canSeal(to recipient: Fingerprint) -> Bool {
        contacts[recipient] != nil
    }

    public func markRead(messageIDs: [String], from sender: Fingerprint) {
        guard !messageIDs.isEmpty else { return }
        outbox[sender, default: []].append(OutgoingPrivate(payload: .read(ids: messageIDs), created: now()))
        dirty = true
        pump(sender)
    }

    // MARK: - Link events

    private func handle(_ event: LinkEvent) {
        guard running else { return } // stopped (Bluetooth turned off in Letterbox)
        switch event {
        case .up:
            broadcastAnnounce()
        case let .down(linkID):
            for key in peers.keys {
                peers[key]?.directLinks.remove(linkID)
            }
            pendingSyncs[linkID] = nil
            lastSyncRequest[linkID] = nil
            lastSyncServed[linkID] = nil
            publishPeers()
        case let .frame(data, linkID):
            receive(data, from: linkID)
        case let .radio(state):
            continuation.yield(.radioChanged(state))
            if state == .ready { broadcastAnnounce() }
        }
    }

    private func receive(_ data: Data, from linkID: LinkID) {
        guard let packet = try? Packet.decode(data) else { return }
        let current = now()
        guard seen.insert(packet.packetID, now: current) else { return }
        guard packet.sender != peerID else { return }
        let sent = Date(timeIntervalSince1970: TimeInterval(packet.timestamp) / 1000)
        guard abs(current.timeIntervalSince(sent)) <= config.maxClockSkew else { return }

        let forMe = packet.recipient == nil || packet.recipient == peerID
        var relay = true
        if forMe {
            switch packet.type {
            case .announce: relay = handleAnnounce(packet, from: linkID)
            case .publicMessage: relay = handlePublicMessage(packet, from: linkID) // forged or over the limit: not passed on
            case .leave: handleLeave(packet)
            case .handshake: handleHandshake(packet)
            case .encrypted: handleEncrypted(packet)
            case .courier: handleCourier(packet, from: linkID)
            case .syncRequest:
                relay = false
                handleSyncRequest(packet, from: linkID)
            case .syncResponse:
                relay = false
                handleSyncResponse(packet, from: linkID)
            }
        } else if !directedRelayLimiter.allow(packet.sender, now: current) {
            relay = false // SEC-03: one sender can't flood directed traffic through us
        }

        if relay, packet.recipient != peerID, packet.ttl > 1 {
            scheduleRelay(packet, from: linkID)
        }
    }

    private func scheduleRelay(_ packet: Packet, from linkID: LinkID) {
        var relayed = packet
        relayed.ttl -= 1
        let delay = Double.random(in: config.relayJitter)
        guard delay > 0 else {
            transmit(relayed, excluding: linkID)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.transmit(relayed, excluding: linkID)
        }
    }

    // MARK: - Packet handlers

    /// Returns whether the announce should be relayed.
    @discardableResult
    private func handleAnnounce(_ packet: Packet, from linkID: LinkID) -> Bool {
        guard let announce = try? AnnouncePayload.decode(packet.payload),
              let signature = packet.signature,
              IdentityKeys.verify(signature, for: packet.signingBytes(), signingKey: announce.signingKey)
        else { return false }

        if let existing = peers[packet.sender], existing.noiseKey != announce.noiseKey {
            return false // PeerID already bound to a different identity this session: ignore.
        }

        let isDirect = packet.ttl == config.defaultTTL
        let fingerprint = IdentityKeys.fingerprint(ofNoiseKey: announce.noiseKey)
        let isNew = peers[packet.sender] == nil
        // SEC-01: identities are free to mint, so new ones are rate-limited per link and
        // the table is capped.
        if isNew {
            guard newPeerLimiter.allow(linkID, now: now()), makeRoomForPeer(isDirect: isDirect) else { return false }
        }
        let linkIsNew = isDirect && peers[packet.sender]?.directLinks.contains(linkID) != true
        if isDirect {
            // A link carries exactly one neighbour.
            for key in peers.keys where key != packet.sender {
                peers[key]?.directLinks.remove(linkID)
            }
        }
        var record = peers[packet.sender] ?? PeerRecord(
            peerID: packet.sender,
            nickname: announce.nickname,
            noiseKey: announce.noiseKey,
            signingKey: announce.signingKey,
            fingerprint: fingerprint,
            lastSeen: now(),
            directLinks: []
        )
        record.nickname = Nickname.sanitize(announce.nickname)
        record.lastSeen = now()
        record.announce = packet
        if isDirect { record.directLinks.insert(linkID) }
        peers[packet.sender] = record
        if linkIsNew { requestSync(on: linkID) } // catch up on #nearby from a new neighbour

        publishPeers()
        rememberContact(record)
        deliverCarried(to: record, rightNow: isDirect)
        if isNew {
            if isDirect { dispatchCouriers() } // a new neighbour can carry what's waiting
            if let pending = pendingHandshakes.removeValue(forKey: packet.sender) {
                processHandshake(pending.message, from: packet.sender, record: record)
            }
            if !isDirect { announceToNewPeer() }
            pump(fingerprint)
        }
        return true
    }

    /// Frees a slot in the peer table if it's full. Forgets the least recently heard peer
    /// that is neither a direct neighbour nor in a session; a direct newcomer may also
    /// replace a far-away peer. Returns false if there's no room.
    private func makeRoomForPeer(isDirect: Bool) -> Bool {
        guard peers.count >= config.maxPeers else { return true }
        let evictable = peers.values.filter { $0.directLinks.isEmpty && sessions[$0.peerID] == nil }
        guard let stalest = evictable.min(by: { $0.lastSeen < $1.lastSeen }) else { return false }
        removePeer(stalest.peerID)
        return true
    }

    /// Someone far away just appeared; they may not know us yet. (Direct links
    /// already announce on `.up`.)
    private func announceToNewPeer() {
        let current = now()
        if let last = lastNewPeerAnnounce, current.timeIntervalSince(last) < config.newPeerAnnounceCooldown { return }
        lastNewPeerAnnounce = current
        broadcastAnnounce()
    }

    /// Returns whether the message was accepted (and so should be relayed).
    private func handlePublicMessage(_ packet: Packet, from linkID: LinkID) -> Bool {
        guard let message = try? PublicMessagePayload.decode(packet.payload) else { return false }
        let record = peers[packet.sender]
        var verified = false
        if let record {
            guard let signature = packet.signature else { return false } // known sender, unsigned: forged
            verified = IdentityKeys.verify(signature, for: packet.signingBytes(), signingKey: record.signingKey)
            if !verified { return false } // Known sender, bad signature: forged.
        }
        // SEC-03: limit after verifying, so forgeries can't use up a real person's allowance.
        // Senders we can't check share a smaller allowance per link.
        let current = now()
        let allowed = record != nil
            ? publicLimiter.allow(packet.sender, now: current)
            : unverifiedLimiter.allow(linkID, now: current)
        guard allowed else { return false }
        if verified, let announce = record?.announce {
            archive.insert(.init(message: packet, announce: announce))
        }
        continuation.yield(.publicMessage(ChatMessage(
            id: packet.packetID.hexString,
            channel: .mesh,
            senderName: Nickname.sanitize(record?.nickname ?? message.nickname),
            senderKey: record?.fingerprint.hex ?? "peer:\(packet.sender.hex)",
            text: message.text,
            timestamp: Date(milliseconds: packet.timestamp),
            isOwn: false,
            isVerified: verified
        )))
        return true
    }

    private func handleLeave(_ packet: Packet) {
        guard let record = peers[packet.sender], let signature = packet.signature,
              IdentityKeys.verify(signature, for: packet.signingBytes(), signingKey: record.signingKey)
        else { return }
        removePeer(packet.sender)
        publishPeers()
    }

    // MARK: - Noise sessions

    private func handleHandshake(_ packet: Packet) {
        let sender = packet.sender
        guard let message = try? HandshakePayload.decode(packet.payload) else { return }
        guard let record = peers[sender] else {
            // Can't check their key against an announce yet. Keep an opening message
            // until the announce arrives (later stages need a session we started).
            if message.stage == 0 { bufferHandshake(message, from: sender) }
            return
        }
        processHandshake(message, from: sender, record: record)
    }

    private func bufferHandshake(_ message: HandshakePayload, from sender: PeerID) {
        if pendingHandshakes[sender] == nil, pendingHandshakes.count >= Self.maxPendingHandshakes,
           let oldest = pendingHandshakes.min(by: { $0.value.received < $1.value.received })?.key {
            pendingHandshakes[oldest] = nil
        }
        pendingHandshakes[sender] = (message, now())
    }

    private func processHandshake(_ message: HandshakePayload, from sender: PeerID, record: PeerRecord) {
        switch message.stage {
        case 0:
            if case let .handshaking(existing, _) = sessions[sender], existing.role == .initiator, peerID < sender {
                return // Simultaneous open: the lower PeerID stays initiator.
            }
            guard var handshake = try? NoiseXXHandshake(role: .responder, identity: identity, prologue: Self.prologue),
                  (try? handshake.readMessage(message.noiseMessage)) != nil,
                  let reply = try? handshake.writeMessage()
            else { return }
            sessions[sender] = .handshaking(handshake, started: now())
            sendHandshake(stage: 1, reply, to: sender)

        case 1:
            guard case var .handshaking(handshake, _) = sessions[sender], handshake.role == .initiator,
                  (try? handshake.readMessage(message.noiseMessage)) != nil,
                  let final = try? handshake.writeMessage(),
                  let transport = try? handshake.finish()
            else { return }
            guard transport.remoteStaticKey == record.noiseKey else {
                sessions[sender] = nil // Someone else's key behind this PeerID.
                return
            }
            sendHandshake(stage: 2, final, to: sender)
            establish(sender, transport)

        default:
            guard case var .handshaking(handshake, _) = sessions[sender], handshake.role == .responder,
                  (try? handshake.readMessage(message.noiseMessage)) != nil,
                  let transport = try? handshake.finish()
            else { return }
            guard transport.remoteStaticKey == record.noiseKey else {
                sessions[sender] = nil
                return
            }
            establish(sender, transport)
        }
    }

    private func initiateHandshake(with peer: PeerID) {
        guard var handshake = try? NoiseXXHandshake(role: .initiator, identity: identity, prologue: Self.prologue),
              let first = try? handshake.writeMessage()
        else { return }
        sessions[peer] = .handshaking(handshake, started: now())
        sendHandshake(stage: 0, first, to: peer)
    }

    private func sendHandshake(stage: UInt8, _ noiseMessage: Data, to peer: PeerID) {
        let payload = HandshakePayload(stage: stage, noiseMessage: noiseMessage).encoded()
        if let packet = makePacket(.handshake, recipient: peer, payload: payload, sign: false) {
            transmit(packet)
        }
    }

    private func establish(_ peer: PeerID, _ transport: NoiseTransport) {
        sessions[peer] = .established(transport, sendNonce: 0, replay: ReplayWindow())
        if let fingerprint = peers[peer]?.fingerprint {
            // Anything sent over a previous session and never acknowledged goes again;
            // the receiver drops duplicates by message ID.
            if let unacked = awaitingAck.removeValue(forKey: fingerprint) {
                outbox[fingerprint] = unacked + (outbox[fingerprint] ?? [])
                dirty = true
            }
            publishPeers()
            for buffered in bufferedCiphertexts.removeValue(forKey: peer) ?? [] {
                decryptAndDispatch(buffered, from: peer)
            }
            pump(fingerprint)
        }
    }

    private func handleEncrypted(_ packet: Packet) {
        guard let payload = try? EncryptedPayload.decode(packet.payload) else { return }
        switch sessions[packet.sender] {
        case .established:
            decryptAndDispatch(payload, from: packet.sender)
        case .handshaking:
            // Can overtake the final handshake message on another mesh path.
            var buffer = bufferedCiphertexts[packet.sender] ?? []
            if buffer.count < Self.maxBufferedCiphertexts { buffer.append(payload) }
            bufferedCiphertexts[packet.sender] = buffer
        case nil:
            // They think we share a session; we lost it. Start a fresh one.
            if peers[packet.sender] != nil { initiateHandshake(with: packet.sender) }
        }
    }

    private func decryptAndDispatch(_ payload: EncryptedPayload, from peer: PeerID) {
        guard case .established(let transport, let sendNonce, var replay) = sessions[peer],
              let record = peers[peer],
              replay.wouldAccept(payload.nonce),
              let plaintext = try? transport.receive.decrypt(
                  nonce: payload.nonce, ad: peer.bytes + peerID.bytes, ciphertext: payload.ciphertext
              ),
              let message = try? PrivatePayload.decode(plaintext)
        else { return }
        replay.record(payload.nonce)
        sessions[peer] = .established(transport, sendNonce: sendNonce, replay: replay)
        dispatchPrivate(message, from: record.fingerprint)
    }

    /// Handles an authenticated private payload, whether it came over a live session
    /// or in a courier envelope.
    private func dispatchPrivate(_ message: PrivatePayload, from sender: Fingerprint) {
        switch message {
        case let .message(id, nickname, text, timestamp):
            let isNew = receivedIDs.insert(id)
            queueReceipt(for: id, to: sender)
            dirty = true
            if isNew {
                continuation.yield(.privateMessage(ChatMessage(
                    id: id,
                    channel: .direct(sender),
                    senderName: Nickname.sanitize(nickname),
                    senderKey: sender.hex,
                    text: text,
                    timestamp: Date(milliseconds: timestamp),
                    isOwn: false,
                    isVerified: true
                )))
            }
            pump(sender)
        case let .delivered(ids):
            let acked = Set(ids)
            let isAcked = { (item: OutgoingPrivate) in item.messageID.map(acked.contains) ?? false }
            // A receipt can arrive by courier while the message is still queued here.
            awaitingAck[sender]?.removeAll(where: isAcked)
            outbox[sender]?.removeAll(where: isAcked)
            if awaitingAck[sender]?.isEmpty == true { awaitingAck[sender] = nil }
            if outbox[sender]?.isEmpty == true { outbox[sender] = nil }
            dirty = true
            ids.forEach { continuation.yield(.deliveryChanged(messageID: $0, state: .delivered)) }
            publishEnvelopes()
        case let .read(ids):
            ids.forEach { continuation.yield(.deliveryChanged(messageID: $0, state: .read)) }
        }
    }

    /// Sends what is queued for this person if a session exists, or starts one.
    /// Returns IDs of chat messages handed to the radio. `silentFor` skips the
    /// `.sent` event for a message the caller reports itself.
    @discardableResult
    private func pump(_ fingerprint: Fingerprint, silentFor: String? = nil) -> Set<String> {
        guard let queue = outbox[fingerprint], !queue.isEmpty, let peer = currentPeerID(for: fingerprint) else {
            return []
        }
        guard sessions[peer]?.isEstablished == true else {
            if sessions[peer] == nil { initiateHandshake(with: peer) }
            return []
        }
        var sentIDs = Set<String>()
        var remaining: [OutgoingPrivate] = []
        for item in queue {
            guard sendEncrypted(item.payload, to: peer) else {
                remaining.append(item)
                continue
            }
            if let id = item.messageID {
                sentIDs.insert(id)
                awaitingAck[fingerprint, default: []].append(item)
                if id != silentFor { continuation.yield(.deliveryChanged(messageID: id, state: .sent)) }
            }
        }
        outbox[fingerprint] = remaining.isEmpty ? nil : remaining
        if remaining.count != queue.count { dirty = true }
        return sentIDs
    }

    private func sendEncrypted(_ message: PrivatePayload, to peer: PeerID) -> Bool {
        guard case .established(let transport, let nonce, let replay) = sessions[peer],
              let ciphertext = try? transport.send.encrypt(
                  nonce: nonce, ad: peerID.bytes + peer.bytes, plaintext: message.encoded()
              )
        else { return false }
        sessions[peer] = .established(transport, sendNonce: nonce + 1, replay: replay)
        let payload = EncryptedPayload(nonce: nonce, ciphertext: ciphertext).encoded()
        guard let packet = makePacket(.encrypted, recipient: peer, payload: payload, sign: false) else { return false }
        transmit(packet)
        return true
    }

    // MARK: - Outgoing packets

    private func broadcastAnnounce() {
        guard running, let packet = makeAnnounce() else { return }
        transmit(packet)
    }

    private func makeAnnounce() -> Packet? {
        let payload = AnnouncePayload(
            nickname: nickname,
            noiseKey: identity.noisePublic,
            signingKey: identity.signingPublic
        )
        return makePacket(.announce, payload: payload.encoded(), sign: true)
    }

    private func makePacket(_ type: PacketType, recipient: PeerID? = nil, payload: Data, sign: Bool) -> Packet? {
        guard payload.count <= Packet.maxPayload else { return nil }
        var packet = Packet(
            type: type,
            ttl: config.defaultTTL,
            timestamp: now().milliseconds,
            packetID: Packet.randomPacketID(),
            sender: peerID,
            recipient: recipient,
            payload: payload
        )
        if sign { packet.signature = identity.sign(packet.signingBytes()) }
        _ = seen.insert(packet.packetID, now: now()) // Ignore our own echoes.
        return packet
    }

    private func transmit(_ packet: Packet, excluding ingress: LinkID? = nil) {
        let frame = packet.encoded()
        if let recipient = packet.recipient,
           let links = peers[recipient]?.directLinks.subtracting([ingress].compactMap { $0 }),
           !links.isEmpty {
            links.forEach { link.send(frame, to: $0) }
        } else {
            link.broadcast(frame, excluding: ingress)
        }
    }

    // MARK: - Peers and maintenance

    private func currentPeerID(for fingerprint: Fingerprint) -> PeerID? {
        peers.values.filter { $0.fingerprint == fingerprint }.max { $0.lastSeen < $1.lastSeen }?.peerID
    }

    private func removePeer(_ peer: PeerID) {
        peers[peer] = nil
        sessions[peer] = nil
        bufferedCiphertexts[peer] = nil
    }

    private func publishPeers() {
        let snapshot = peers.values.map { record in
            Peer(
                peerID: record.peerID,
                nickname: record.nickname,
                fingerprint: record.fingerprint,
                isDirect: !record.directLinks.isEmpty,
                hasSecureSession: sessions[record.peerID]?.isEstablished == true,
                lastSeen: record.lastSeen
            )
        }
        .sorted { $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending }
        continuation.yield(.peersChanged(snapshot))
    }

    private func maintain() {
        let current = now()
        seen.prune(now: current)
        archive.prune(olderThan: current.addingTimeInterval(-config.publicHistoryWindow).milliseconds)
        pendingSyncs = pendingSyncs.filter { current.timeIntervalSince($0.value.requested) <= config.syncResponseWindow }
        let carriedBefore = carried.count
        carried.prune(now: current)
        if carried.count != carriedBefore { dirty = true }

        let expired = peers.values.filter { current.timeIntervalSince($0.lastSeen) > config.peerTimeout }
        expired.forEach { removePeer($0.peerID) }
        if !expired.isEmpty { publishPeers() }

        pendingHandshakes = pendingHandshakes.filter { current.timeIntervalSince($0.value.received) <= config.handshakeTimeout }

        for (peer, session) in sessions {
            if case let .handshaking(_, started) = session, current.timeIntervalSince(started) > config.handshakeTimeout {
                sessions[peer] = nil
                bufferedCiphertexts[peer] = nil
            }
        }

        for fingerprint in Set(outbox.keys).union(awaitingAck.keys) {
            let isStale = { (item: OutgoingPrivate) in current.timeIntervalSince(item.created) > self.config.outboxLifetime }
            for item in (outbox[fingerprint] ?? []) + (awaitingAck[fingerprint] ?? []) where isStale(item) {
                if let id = item.messageID { continuation.yield(.deliveryChanged(messageID: id, state: .failed)) }
                dirty = true
            }
            outbox[fingerprint]?.removeAll(where: isStale)
            awaitingAck[fingerprint]?.removeAll(where: isStale)
            if outbox[fingerprint]?.isEmpty == true { outbox[fingerprint] = nil }
            if awaitingAck[fingerprint]?.isEmpty == true { awaitingAck[fingerprint] = nil }
            pump(fingerprint) // Retries the handshake after a timeout.
        }

        dispatchCouriers()
        publishEnvelopes()
        if dirty { persist() }
    }
}

// MARK: - Catching up on #nearby

extension MeshNode {
    /// Asks a neighbour we just connected to for the #nearby messages we missed.
    /// Link-local (TTL 1): it lists what we already have, so only the gaps come back.
    private func requestSync(on linkID: LinkID) {
        let current = now()
        if let last = lastSyncRequest[linkID], current.timeIntervalSince(last) < config.syncInterval { return }
        lastSyncRequest[linkID] = current
        pendingSyncs[linkID] = PendingSync(requested: current, remaining: config.maxSyncMessages)
        let request = SyncRequestPayload(
            since: current.addingTimeInterval(-config.publicHistoryWindow).milliseconds,
            have: archive.ids(limit: SyncRequestPayload.maxIDs)
        )
        guard var packet = makePacket(.syncRequest, payload: request.encoded(), sign: false) else { return }
        packet.ttl = 1
        link.send(packet.encoded(), to: linkID)
    }

    /// Sends a neighbour the archived #nearby messages it lacks, at most once per
    /// `syncInterval` per link and `maxSyncMessages` at a time.
    private func handleSyncRequest(_ packet: Packet, from linkID: LinkID) {
        let current = now()
        if let last = lastSyncServed[linkID], current.timeIntervalSince(last) < config.syncInterval { return }
        guard let request = try? SyncRequestPayload.decode(packet.payload) else { return }
        lastSyncServed[linkID] = current
        let oldest = max(request.since, current.addingTimeInterval(-config.publicHistoryWindow).milliseconds)
        for entry in archive.missing(from: Set(request.have), since: oldest, limit: config.maxSyncMessages) {
            let payload = SyncResponsePayload(message: entry.message.encoded(), announce: entry.announce.encoded())
            guard var reply = makePacket(.syncResponse, payload: payload.encoded(), sign: false) else { continue }
            reply.ttl = 1
            link.send(reply.encoded(), to: linkID)
        }
    }

    /// A missed #nearby message from a neighbour. Accepted only in answer to our own
    /// request on that link, and only if the author's announce and the message's
    /// signature both check out, exactly as for a live message. Old timestamps are
    /// allowed here (that's the point) but nothing older than the history window.
    private func handleSyncResponse(_ packet: Packet, from linkID: LinkID) {
        let current = now()
        guard var pending = pendingSyncs[linkID], pending.remaining > 0,
              current.timeIntervalSince(pending.requested) <= config.syncResponseWindow
        else { return } // unsolicited, late, or more than we asked for
        pending.remaining -= 1
        pendingSyncs[linkID] = pending

        guard let payload = try? SyncResponsePayload.decode(packet.payload),
              let message = try? Packet.decode(payload.message), message.type == .publicMessage,
              let announcePacket = try? Packet.decode(payload.announce), announcePacket.type == .announce,
              message.sender == announcePacket.sender,
              let announce = try? AnnouncePayload.decode(announcePacket.payload),
              let announceSignature = announcePacket.signature,
              IdentityKeys.verify(announceSignature, for: announcePacket.signingBytes(), signingKey: announce.signingKey),
              let signature = message.signature,
              IdentityKeys.verify(signature, for: message.signingBytes(), signingKey: announce.signingKey),
              let text = try? PublicMessagePayload.decode(message.payload)
        else { return }

        let sent = Date(milliseconds: message.timestamp)
        guard current.timeIntervalSince(sent) <= config.publicHistoryWindow,
              sent.timeIntervalSince(current) <= config.maxClockSkew
        else { return }
        if let live = peers[message.sender], live.noiseKey != announce.noiseKey { return } // ID taken by someone else
        guard !archive.contains(message.packetID), seen.insert(message.packetID, now: current) else { return }

        archive.insert(.init(message: message, announce: announcePacket)) // so we can pass it on in turn
        let fingerprint = IdentityKeys.fingerprint(ofNoiseKey: announce.noiseKey)
        continuation.yield(.publicHistory(ChatMessage(
            id: message.packetID.hexString,
            channel: .mesh,
            senderName: Nickname.sanitize(announce.nickname),
            senderKey: fingerprint.hex,
            text: text.text,
            timestamp: sent,
            isOwn: fingerprint == myFingerprint,
            isVerified: true
        )))
    }
}

// MARK: - Store and forward

extension MeshNode {
    /// An envelope handed to us by a neighbour, or delivered to us by a courier.
    private func handleCourier(_ packet: Packet, from linkID: LinkID) {
        guard let envelope = try? CourierEnvelope.decode(packet.payload) else { return }
        let current = now()
        guard Date(milliseconds: envelope.expiry) > current else { return }

        if envelope.recipientTag == Courier.tag(for: myFingerprint, envelopeID: envelope.id) {
            openEnvelope(envelope)
            return
        }
        // Only carry envelopes handed over directly (TTL 1, no recipient), never ones
        // passing through on their way to someone else.
        guard packet.recipient == nil, packet.ttl == 1 else { return }
        // A hostile neighbour could otherwise fill every slot with junk and push out the
        // mail we carry for others: limit how fast and how much one link can deposit.
        guard depositLimiter.allow(linkID, now: current),
              carried.insert(envelope, received: current, depositor: linkID, perDepositorLimit: config.maxCarriedPerDepositor)
        else { return }
        dirty = true
        publishEnvelopes()
        // The recipient may be standing next to us already.
        for record in peers.values where !record.directLinks.isEmpty {
            deliverCarried(to: record, rightNow: true)
        }
    }

    private func openEnvelope(_ envelope: CourierEnvelope) {
        guard !openedEnvelopes.contains(envelope.id.hexString),
              let opened = Courier.open(envelope, as: identity)
        else { return }
        _ = openedEnvelopes.insert(envelope.id.hexString) // only genuine envelopes take up memory
        dirty = true
        let sender = IdentityKeys.fingerprint(ofNoiseKey: opened.senderKey)
        guard sender != myFingerprint else { return }
        // Now we can reply by courier too, even if we've never met them.
        var nickname = contacts[sender]?.nickname ?? sender.short
        if case let .message(_, name, _, _) = opened.payload, !Nickname.sanitize(name).isEmpty {
            nickname = Nickname.sanitize(name)
        }
        updateContact(Contact(fingerprint: sender, nickname: nickname, noiseKey: opened.senderKey, lastSeen: now()))
        dispatchPrivate(opened.payload, from: sender)
    }

    /// Hands this person every envelope we carry for them. `rightNow` (they're a direct
    /// neighbour) skips the retry wait; someone heard through relays gets a retry at
    /// most every `courierRetryInterval`.
    private func deliverCarried(to record: PeerRecord, rightNow: Bool) {
        guard carried.count > 0 else { return }
        let envelopes = carried.due(for: record.fingerprint, now: now(),
                                    retryInterval: rightNow ? 0 : config.courierRetryInterval)
        for envelope in envelopes {
            if let packet = makePacket(.courier, recipient: record.peerID, payload: envelope.encoded(), sign: false) {
                transmit(packet)
            }
        }
    }

    /// Seals messages that have waited too long and hands copies to direct neighbours.
    private func dispatchCouriers() {
        courierPass(&outbox)
        courierPass(&awaitingAck)
        publishEnvelopes()
    }

    private func courierPass(_ queues: inout [Fingerprint: [OutgoingPrivate]]) {
        let current = now()
        let neighbours = peers.values.filter { !$0.directLinks.isEmpty }
        for fingerprint in Array(queues.keys) {
            guard let contact = contacts[fingerprint], var items = queues[fingerprint] else { continue }
            var changed = false
            for index in items.indices where current.timeIntervalSince(items[index].created) >= config.courierDelay {
                if items[index].envelope == nil {
                    let expiry = items[index].created.addingTimeInterval(config.outboxLifetime)
                    guard let envelope = Courier.seal(items[index].payload, to: contact, from: identity, expiry: expiry) else { continue }
                    items[index].envelope = envelope
                    changed = true
                }
                if spray(&items[index], to: fingerprint, among: neighbours) { changed = true }
            }
            if changed {
                queues[fingerprint] = items
                dirty = true
            }
        }
    }

    /// Returns true if anyone new was handed a copy.
    private func spray(_ item: inout OutgoingPrivate, to recipient: Fingerprint, among neighbours: [PeerRecord]) -> Bool {
        guard let envelope = item.envelope, item.couriers.count < config.maxCourierCopies else { return false }
        let fresh = neighbours.filter { $0.fingerprint != recipient && !item.couriers.contains($0.fingerprint) }
        guard !fresh.isEmpty else { return false }
        let wasCarried = !item.couriers.isEmpty
        for courier in fresh.prefix(config.maxCourierCopies - item.couriers.count) {
            guard let link = courier.directLinks.first,
                  var packet = makePacket(.courier, payload: envelope.encoded(), sign: false)
            else { continue }
            packet.ttl = 1 // straight to this neighbour, never relayed
            self.link.send(packet.encoded(), to: link)
            item.couriers.insert(courier.fingerprint)
        }
        if !wasCarried, !item.couriers.isEmpty, let id = item.messageID {
            continuation.yield(.deliveryChanged(messageID: id, state: .inEnvelope))
        }
        return !item.couriers.isEmpty
    }

    private func rememberContact(_ record: PeerRecord) {
        updateContact(Contact(fingerprint: record.fingerprint, nickname: record.nickname, noiseKey: record.noiseKey, lastSeen: now()))
    }

    private func updateContact(_ contact: Contact) {
        let existing = contacts[contact.fingerprint]
        // Only a new person, or a changed name or key, is worth writing to disk.
        if existing?.nickname != contact.nickname || existing?.noiseKey != contact.noiseKey { dirty = true }
        contacts[contact.fingerprint] = contact
        if contacts.count > config.maxContacts,
           let oldest = contacts.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            contacts[oldest.fingerprint] = nil
        }
    }

    /// Fails the oldest queued messages beyond the limit.
    private func enforceQueueLimit() {
        var total = outbox.values.reduce(0) { $0 + $1.count }
        guard total > config.maxQueuedMessages else { return }
        let oldestFirst = outbox.flatMap { key, items in items.map { (key, $0) } }.sorted { $0.1.created < $1.1.created }
        for (fingerprint, item) in oldestFirst where total > config.maxQueuedMessages {
            outbox[fingerprint]?.removeAll { $0.created == item.created && $0.messageID == item.messageID }
            if outbox[fingerprint]?.isEmpty == true { outbox[fingerprint] = nil }
            if let id = item.messageID { continuation.yield(.deliveryChanged(messageID: id, state: .failed)) }
            total -= 1
        }
        dirty = true
        publishEnvelopes()
    }

    /// SEC-02: receipts for one person are merged into at most a few pending items, so a
    /// stranger's flood of messages can't turn into a flood of queued (and couriered) receipts.
    private func queueReceipt(for id: String, to sender: Fingerprint) {
        var queue = outbox[sender] ?? []
        let receiptIndices = queue.indices.filter {
            if case .delivered = queue[$0].payload { return true }
            return false
        }
        if let last = receiptIndices.last, case let .delivered(ids) = queue[last].payload,
           queue[last].envelope == nil, ids.count < config.maxIDsPerReceipt {
            // Not sealed yet: merge into it.
            queue[last] = OutgoingPrivate(payload: .delivered(ids: ids + [id]), created: queue[last].created)
        } else if receiptIndices.count < config.maxPendingReceiptsPerPerson {
            queue.append(OutgoingPrivate(payload: .delivered(ids: [id]), created: now()))
        } else {
            return // Enough receipts already waiting for this person; this one is dropped.
        }
        outbox[sender] = queue
        enforceQueueLimit()
    }

    /// Tells the app about our envelopes on their way and those we carry, when that changes.
    private func publishEnvelopes() {
        let outgoing = (awaitingAck.flatMap { key, items in items.map { (key, $0) } }
            + outbox.flatMap { key, items in items.map { (key, $0) } })
            .compactMap { recipient, item -> OutgoingEnvelope? in
                guard let id = item.messageID, item.envelope != nil, !item.couriers.isEmpty else { return nil }
                return OutgoingEnvelope(messageID: id, recipient: recipient, carriers: item.couriers.count,
                                        expires: item.created.addingTimeInterval(config.outboxLifetime))
            }
            .sorted { $0.expires < $1.expires }
        let summary = EnvelopeSummary(outgoing: outgoing, carryingForOthers: carried.count)
        guard summary != lastEnvelopes else { return }
        lastEnvelopes = summary
        continuation.yield(.envelopesChanged(summary))
    }

    // MARK: Persistence

    private func persist() {
        guard let store, dirty else { return }
        let items = (awaitingAck.flatMap { key, items in items.map { (key, $0) } }
            + outbox.flatMap { key, items in items.map { (key, $0) } })
            .sorted { $0.1.created < $1.1.created }
            .map { recipient, item in
                MeshSnapshot.Item(recipient: recipient, payload: item.payload.encoded(), created: item.created,
                                  envelope: item.envelope?.encoded(), couriers: Array(item.couriers))
            }
        let snapshot = MeshSnapshot(
            outbox: items,
            contacts: Array(contacts.values),
            carried: carried.items.values.map { MeshSnapshot.Carried(envelope: $0.envelope.encoded(), received: $0.received) },
            openedEnvelopes: Array(openedEnvelopes.order.suffix(Self.persistedRecentIDs)),
            receivedMessageIDs: Array(receivedIDs.order.suffix(Self.persistedRecentIDs))
        )
        guard let data = try? JSONEncoder().encode(snapshot), (try? store.save(data)) != nil else { return }
        dirty = false
    }

    struct Restored {
        var outbox: [Fingerprint: [OutgoingPrivate]] = [:]
        var contacts: [Fingerprint: Contact] = [:]
        var carried: CarriedEnvelopes
        var messages: [(ChatMessage, String)] = []
    }

    static func restore(_ snapshot: MeshSnapshot, configuration: Configuration, me: Fingerprint) -> Restored {
        var restored = Restored(carried: CarriedEnvelopes(capacity: configuration.maxCarriedEnvelopes,
                                                          maxLifetime: configuration.maxCarryTime))
        for contact in snapshot.contacts { restored.contacts[contact.fingerprint] = contact }
        for stored in snapshot.outbox {
            guard let payload = try? PrivatePayload.decode(stored.payload) else { continue }
            var item = OutgoingPrivate(payload: payload, created: stored.created)
            item.envelope = stored.envelope.flatMap { try? CourierEnvelope.decode($0) }
            item.couriers = Set(stored.couriers)
            restored.outbox[stored.recipient, default: []].append(item)
            if case let .message(id, nickname, text, timestamp) = payload {
                let message = ChatMessage(
                    id: id, channel: .direct(stored.recipient), senderName: nickname, senderKey: me.hex, text: text,
                    timestamp: Date(milliseconds: timestamp), isOwn: true, isVerified: true,
                    delivery: item.couriers.isEmpty ? .queued : .inEnvelope
                )
                let name = restored.contacts[stored.recipient]?.nickname ?? stored.recipient.short
                restored.messages.append((message, name))
            }
        }
        for stored in snapshot.carried {
            if let envelope = try? CourierEnvelope.decode(stored.envelope) {
                _ = restored.carried.insert(envelope, received: stored.received)
            }
        }
        return restored
    }
}

extension Date {
    var milliseconds: UInt64 { UInt64(max(0, timeIntervalSince1970 * 1000)) }

    init(milliseconds: UInt64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
