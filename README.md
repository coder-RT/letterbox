# Letterbox

A peer-to-peer chat app for iPhone and Mac with no accounts and no servers.

- **Nearby chat over Bluetooth.** Phones form a mesh, and messages hop phone to phone (up to 7 hops) with no internet.
- **Private messages.** End-to-end encrypted with the Noise protocol (XX pattern). Phones that relay them see only ciphertext.
- **Envelopes.** A private message to someone out of range is sealed and carried by hikers you pass, and delivered when one of them meets the person.
- **Connections panel.** Shows what works right now (Bluetooth, internet, Wi-Fi, mobile network, satellite, location, relays, envelopes), with switches for whether Letterbox may use Bluetooth and the internet.
- **Location channels.** Public chat rooms for your area (block to region), carried over public Nostr relays when you have internet.

Letterbox runs its **own network**. It uses its own Bluetooth service ID, its own packet format and its own Nostr event kind, so it only talks to other copies of Letterbox.

## Guides

- [Texting Without Internet: A Hiker's Field Guide](docs/offline-texting-hiking-guide.md): how to use Letterbox, SMS and satellite texting on the trail, plus what to do when nothing works.
- [Features, scored](docs/features.md): every feature with its value, completeness and test coverage, and the field tests still needed.
- [Design and accessibility](docs/design.md): screen-by-screen changes, icons and their licences, colours with contrast ratios, the accessibility checklist.
- [Domain map](docs/domain.md): the bounded contexts, a glossary of terms, and which port and adapter each concept lives in.

## Running it

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and, for the iPhone, your Apple ID signed in to Xcode (Xcode → Settings → Accounts).

For the iPhone, also create a `Makefile.local` (it's ignored by git) with your own values:

```make
DEVICE := <your iPhone's identifier, from: xcrun devicectl list devices>
DEVELOPMENT_TEAM := <your Apple developer team ID, from Xcode → Settings → Accounts>
```

```bash
make test         # all LetterboxKit tests, no device needed
make ui-test      # iPhone UI tests in the simulator: simulated mesh, accessibility audits, screenshots
make run-mac      # build and open the Mac app
make install-ios  # build, install and launch on your iPhone (cable or same Wi-Fi)
```

Or `make gen && open Letterbox.xcodeproj` and press ⌘R with the `Letterbox` (iPhone) or `LetterboxMac` scheme.

To try the mesh, run it on two devices, for example your iPhone and your Mac. The iOS Simulator has no Bluetooth.

On the iPhone, the first launch may need: Settings → General → VPN & Device Management → trust your developer certificate, and Settings → Privacy & Security → Developer Mode on.

## Architecture: ports and adapters

The app is split along **ports and adapters** (hexagonal architecture), organised around one core domain: messaging without the internet. [docs/domain.md](docs/domain.md) has the bounded contexts, the glossary and the full port and adapter table.

```
                ┌──────────────────────── App target (SwiftUI) ───────────────────────┐
                │  Views                     AppContainer  ← composition root         │
                └───────┬──────────────────────────┬──────────────────────────────────┘
                        │ observes                 │ wires adapters into ports
                ┌───────▼─────────────┐            │
                │ LetterboxApplication  │            │
                │ ChatStore, commands │            │
                └───────┬─────────────┘            │
                        │ uses ports only          │
                ┌───────▼─────────────────────────────────────────────┐
                │ LetterboxDomain: entities + ports                     │
                │ MeshTransport · LocationChannelTransport ·          │
                │ LocationProvider · ConnectivityMonitor ·            │
                │ SecretStore · SettingsStore · BlobStore             │
                └───────▲──────────────▲──────────────▲───────────────┘
                        │ implements   │              │
      ┌─────────────────┴───┐   ┌──────┴────────┐  ┌──┴──────────────────┐
      │ LetterboxMesh         │   │ LetterboxNostr  │  │ LetterboxPersistence  │
      │ MeshNode (engine)   │   │ relays, NIP-01│  │ Keychain, defaults  │
      │   │ LinkLayer port  │   └───────────────┘  └─────────────────────┘
      │   ▼                 │
      │ LetterboxBLE adapter  │   LetterboxWire: packets, TLV, BLE chunking (pure)
      │ (CoreBluetooth)     │   LetterboxCrypto: identity keys, Noise XX and X (CryptoKit)
      └─────────────────────┘   LetterboxDevice: network, mobile radio, location permission
```

Each module lists its dependencies in [Package.swift](Packages/LetterboxKit/Package.swift), so a forbidden import (for example, the application layer importing CoreBluetooth) fails to compile.

### Which patterns are used, and why

| Pattern | Where | Why |
|---|---|---|
| **Adapter** (ports and adapters) | `BLELinkLayer`, `NostrLocationChannel`, `KeychainSecretStore`, `EncryptedFileStore`, `CoreLocationProvider`, `SystemConnectivityMonitor` | Each wraps one Apple or network API behind a small domain protocol. The engine and UI never see CoreBluetooth or URLSession, so they're testable with fakes and the radio is swappable. |
| **Two-level ports** | `MeshTransport` (what the app needs) over `LinkLayer` (what the engine needs) | The mesh engine is pure logic over "send frame to neighbour". The in-memory radio in tests and the BLE adapter in the app both implement it, which is how a 4-node mesh runs in a unit test. |
| **Pipeline** | `MeshNode.receive`: decode → dedup → freshness → verify or decrypt → relay | Each inbound step is small and in order, which keeps the engine from growing into one huge class. |
| **State machine** | `Session`: `handshaking` → `established`, plus `DeliveryState` that only moves forward | Makes the handshake races (both sides start at once, final message overtaken) and out-of-order receipts explicit. |
| **Actors** | `MeshNode`, `RelayPool`, `NostrLocationChannel` | Swift 6 strict concurrency: no locks or dispatch queues in the core. CoreBluetooth stays on one serial queue inside its adapter. |
| **Observer** | `AsyncStream` events → `@Observable ChatStore` → SwiftUI | One typed event stream per transport, consumed in one place. |
| **Composition root** | `AppContainer` | The only file that knows which adapter backs which port. |

Routing is a pure domain service, `RoutePlanner`: for each private message it picks Bluetooth if the person is in reach, otherwise an envelope, otherwise a queue with a reason, respecting the user's Bluetooth and internet switches. The internet route is already modelled and arrives with phase 2.

## How a message travels

**Public, nearby:** `ChatStore` → `MeshNode.sendPublic` builds a packet (TTL 7, random 8-byte packet ID, Ed25519 signature) → `BLELinkLayer` splits it into MTU-sized chunks → each neighbour reassembles, checks it hasn't seen the packet ID, verifies the signature against the sender's announced key, shows it, and relays it with TTL − 1 after a short random delay. It never sends the packet back out of the link it arrived on.

**Private:** the first message to someone starts a Noise XX handshake (3 messages, sent as directed packets). Each side checks that the key proven in the handshake matches the key the peer announced. Messages then travel as `encrypted` packets with an explicit nonce and a replay window, which survives loss and reordering across mesh paths. The recipient replies with an encrypted delivery ack, and later a read receipt. If the person isn't around, the message waits in the outbox (up to 3 days, up to 500 messages) and goes out when they appear.

**Carried by other hikers (couriers):** if a private message still hasn't gone after 10 seconds, and you've met the recipient before (so you know their key), Letterbox seals it to them with Noise X and hands copies to up to 8 phones in direct range, including ones that walk past later. A courier can't read it: it sees only a random ID, a recipient tag and an expiry, all bound into the seal. When a courier meets the recipient, directly or through other phones, it delivers the envelope. The recipient replies with a delivery receipt, which travels back the same way, by courier if need be. Couriers carry at most 256 envelopes, for at most 3 days each, and never pass them to other couriers. Courier messages have no forward secrecy: someone who later steals the recipient's key could open captured envelopes.

**Location channel:** your coarse location becomes a geohash. Letterbox derives a separate secp256k1 key for that geohash from a device seed, so posts in different areas can't be linked to each other or to your mesh identity. Messages are ephemeral events (kind 23471) that relays forward but don't store.

## Wire format

```
magic "LB" | ver | type | TTL | flags | timestamp ms (8) | packetID (8) | sender (8) | [recipient (8)] | len (2) | payload | [Ed25519 sig (64)]
```

Types: `announce` 0x01, `publicMessage` 0x02, `leave` 0x03, `handshake` 0x10, `encrypted` 0x11, `courier` 0x12. Payloads are TLV, so fields can be added without breaking older versions. Details are in [Packet.swift](Packages/LetterboxKit/Sources/LetterboxWire/Packet.swift).

## Tests

`make test` runs 313 package tests (parameterized tests count once), all without a device or radio, and `make ui-test` runs 11 iPhone UI tests in the simulator:
- **Domain:** geohash encoding at every level and the map's edges, nickname cleaning, identifiers and hex parsing
- **Wire format:** every packet type, the exact byte layout, forward-compatible TLV fields, payload limits, BLE chunking across MTUs, and fuzzing with random bytes and every single-bit flip
- **Crypto:** the Noise implementation byte for byte against the published conformance vectors, handshake turn-taking and tampering, nonce encoding, the replay window, and signatures
- **Mesh, on an in-memory radio:** multi-hop relay and the 7-hop limit, flood dedup, a 16-node grid, DMs through relays that never see plaintext, simultaneous handshakes, groups that meet, lost sessions, the offline queue and its expiry, couriers (a message and its receipt carried between people who never meet, copy limits, carry time, forged or extended envelopes, delivery through relays), surviving restarts, and attacks (forged senders, announces and leaves, replayed receipts, stale timestamps, garbage frames)
- **Nostr:** NIP-01 serialization and signing, and the location channel fed with simulated relay traffic: filtering, dedup, echoes and per-area keys
- **Persistence:** Keychain and settings stores (Keychain tests skip themselves where the Keychain isn't available)
- **ChatStore:** commands, channels, unread counts, delivery states, location channels, nickname handling, privacy mode, the Bluetooth and internet switches, and envelope summaries
- **Routing and connectivity:** every combination in the route planner, every status in the connections panel, and the device readings mapping
- **Store and engine together:** the real `ChatStore` on the real mesh engine with simulated phones: private messages with receipts, Bluetooth off then on (both ways), envelope summaries from hand-off to receipt, verification and impostor detection
- **UI tests (simulator):** nearby chat, private messages with ticks, verifying someone, the privacy screen, the Connections panel with Bluetooth off then on, an offline device with the internet switch, an envelope carried by a passing hiker, Apple's accessibility audit on every screen, and screenshots in light, dark and the largest text size

## Privacy notes and known limits

- **Privacy mode:** the eye button in the top bar blurs every message so people nearby can't read your screen. Tap a message to peek at it for 5 seconds. The choice is remembered, and on iPhone the app also covers itself in the app switcher while privacy mode is on.

- PeerIDs are random per launch, but announces carry your nickname and public keys in cleartext. Anyone in radio range who sees two announces can tell they're the same device.
- Private messages have forward secrecy within a session; courier envelopes don't.
- Undelivered messages, the people you've met (nickname and public key) and envelopes you carry for others are saved to disk, encrypted with a key kept in the Keychain, so they survive the app closing.
- Location channels connect to Nostr relays directly, so relays see your IP address. There's no Tor yet.
- Conversations themselves are kept in memory only, apart from your own undelivered messages.

## Next steps

- Tor for relay connections
- Emergency wipe (keys and state)
- CoreBluetooth state restoration for longer background operation
- Mac app icon sizes and an iPad layout

## Acknowledgements

Letterbox's overall approach is inspired by [bitchat](https://github.com/permissionlesstech/bitchat): a Bluetooth mesh with TTL-limited flooding, Noise XX for private messages, and geohash location channels over Nostr. Its [whitepaper](https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md) is a useful reference for the design choices. Letterbox has its own wire format, Bluetooth service ID and Nostr event kind, so the two apps don't talk to each other.
