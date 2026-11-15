# HelloLetter architecture

How the code is organised, which patterns it uses and why, how a message travels, and the wire format. For the domain model and glossary see [domain.md](domain.md); for each feature in detail see [features](features/README.md).

HelloLetter runs its **own network**: its own Bluetooth service ID, its own packet format and its own Nostr event kind, so it only talks to other copies of HelloLetter.

**Internal names.** The app was called Letterbox during development. Users never see the internal names, and they keep it on purpose: module names (`LetterboxKit`, `LetterboxMesh`…), the Xcode targets, the wire-protocol context strings (`letterbox/mesh/1`, `letterbox/courier/1`, the `LB` packet magic), the Bluetooth service UUIDs and the Keychain service (`app.letterbox.secrets`). Changing the protocol strings would make new builds unable to talk to existing ones, for no benefit to users.

## Ports and adapters

The app is split along **ports and adapters** (hexagonal architecture), organised around one core domain: messaging without the internet. [domain.md](domain.md) has the bounded contexts, the glossary and the full port and adapter table.

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
                │ SecretStore · SettingsStore · BlobStore ·           │
                │ MessageNotifier · LocalDataEraser                   │
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

Each module lists its dependencies in [Package.swift](../Packages/LetterboxKit/Package.swift), so a forbidden import (for example, the application layer importing CoreBluetooth) fails to compile.

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

**Carried by other hikers (couriers):** if a private message still hasn't gone after 10 seconds, and you've met the recipient before (so you know their key), HelloLetter seals it to them with Noise X and hands copies to up to 8 phones in direct range, including ones that walk past later. A courier can't read it: it sees only a random ID, a recipient tag and an expiry, all bound into the seal. When a courier meets the recipient, directly or through other phones, it delivers the envelope. The recipient replies with a delivery receipt, which travels back the same way, by courier if need be. Couriers carry at most 256 envelopes, for at most 3 days each, and never pass them to other couriers. Courier messages have no forward secrecy: someone who later steals the recipient's key could open captured envelopes.

**Catching up:** when two phones meet directly, each asks the other (link-local, TTL 1) for the #nearby messages from the last 12 hours it doesn't have, listing the IDs it holds. Answers carry each message as its author signed it plus the author's signed announce, are accepted only in reply to a request on that link, and are never relayed. See [catching up on #nearby](features/catching-up-on-nearby.md).

**Location channel** (Debug builds only): your coarse location becomes a geohash. HelloLetter derives a separate secp256k1 key for that geohash from a device seed, so posts in different areas can't be linked to each other or to your mesh identity. Messages are ephemeral events (kind 23471) that relays forward but don't store.

## Wire format

```
magic "LB" | ver | type | TTL | flags | timestamp ms (8) | packetID (8) | sender (8) | [recipient (8)] | len (2) | payload | [Ed25519 sig (64)]
```

Types: `announce` 0x01, `publicMessage` 0x02, `leave` 0x03, `handshake` 0x10, `encrypted` 0x11, `courier` 0x12, `syncRequest` 0x13, `syncResponse` 0x14. Payloads are TLV, so fields can be added without breaking older versions. Golden vectors for other implementations are in [wire-test-vectors.json](wire-test-vectors.json), checked by `WireVectorTests`. Details are in [Packet.swift](../Packages/LetterboxKit/Sources/LetterboxWire/Packet.swift).
