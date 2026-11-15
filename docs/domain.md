# HelloLetter domain map

HelloLetter is built around one core domain: **messaging without the internet**. Everything else either supports it or is generic plumbing. The code follows ports and adapters: the domain defines small protocols (ports), and each Apple or network API is wrapped by an adapter behind one of them. The words in the glossary below are used the same way in the app, the docs and the code.

## Bounded contexts

| Context | Kind | What it owns | Modules |
|---|---|---|---|
| **Offline messaging** | Core | Peers, hops, sessions, private messages, the outbox, envelopes, couriers, delivery receipts | `LetterboxMesh`, `LetterboxWire`, `LetterboxCrypto` |
| **Routing and connectivity** | Supporting | Which ways of communicating work now, which ones the user allows, which way a message goes | `LetterboxDomain/Connectivity.swift`, `LetterboxApplication/ConnectionReport.swift`, `LetterboxDevice` |
| **Location channels** | Supporting | Public chat rooms per area over Nostr relays (internet only) | `LetterboxNostr` |
| **Conversation** | Supporting | Timelines, unread counts, commands, nickname, privacy mode | `LetterboxApplication` (`ChatStore`, `ComposerInput`) |
| **Identity and contacts** | Generic | Device keys, fingerprints, people met | `LetterboxCrypto/IdentityKeys`, `LetterboxMesh/Courier.swift` (`Contact`) |
| **Persistence** | Generic | Keychain secrets, settings, the encrypted state file | `LetterboxPersistence` |

Internet private messages and photos (phase 2) will join *Routing and connectivity* as a new transport, with an adapter in `LetterboxNostr`.

## Glossary

| Term | Meaning | In code |
|---|---|---|
| **Peer** | A phone running HelloLetter that we can currently reach, directly or through others | `Peer`, `PeerRecord` |
| **Hop** | One phone-to-phone step. A message travels at most 7 hops | `Configuration.defaultTTL` |
| **#nearby** | The public chat with everyone in Bluetooth reach | `ChannelID.mesh` |
| **Private message** | An end-to-end encrypted message to one person | `PrivatePayload.message` |
| **Session** | A live encrypted link between two peers (Noise XX) | `Session`, `NoiseTransport` |
| **Outbox** | Your private messages not yet acknowledged. Saved, up to 3 days | `MeshNode.outbox`, `awaitingAck` |
| **Envelope** | A private message sealed so only the recipient can open it (Noise X), carried by other phones | `CourierEnvelope`, `NoiseXSeal` |
| **Courier** | A phone carrying someone else's envelope until it meets the recipient | `CarriedEnvelopes` |
| **Delivery receipt** | The recipient's phone confirming a message arrived (and later that it was read) | `PrivatePayload.delivered`, `.read` |
| **Contact** | Someone we've met, kept with their public key so we can seal envelopes to them | `Contact` |
| **Fingerprint** | A person's stable identity: SHA-256 of their public key | `Fingerprint` |
| **Safety number** | 8 groups of 4 digits two people compare in person; the same on both phones | `SafetyNumber` (LetterboxCrypto) |
| **Verified** | Someone whose safety number you compared or whose code you scanned | `ChatStore.verified` |
| **Impostor** | Someone nearby using a verified person's name with a different key | `ChatStore.impostors` |
| **Transport** | A way HelloLetter itself sends messages: Bluetooth mesh, envelope, internet (phase 2) | `Route` |
| **Permission** | Whether the user lets HelloLetter use Bluetooth or the internet | `TransportPermissions` |
| **Connection** | One way of communicating shown to the user, with its status: Bluetooth, internet, Wi-Fi, mobile network, satellite, location, relays, envelopes | `ConnectionKind`, `ConnectionRow` |
| **Route** | The way a particular message will go, or why it can't go yet | `RoutePlanner.route` |
| **Location channel** | A public chat room for a geohash area, over Nostr relays | `ChannelID.location` |

## Ports and adapters

| Port (in `LetterboxDomain` unless noted) | Adapter in the app | Fake in tests |
|---|---|---|
| `MeshTransport` | `MeshNode` (`LetterboxMesh`), the engine itself | `FakeMesh` |
| `LinkLayer` (`LetterboxMesh`) | `BLELinkLayer` (`LetterboxBLE`, CoreBluetooth) | `InMemoryRadio` / `InMemoryLink` |
| `LocationChannelTransport` | `NostrLocationChannel` (`LetterboxNostr`) | `FakeLocationChannels` |
| `LocationProvider` | `CoreLocationProvider` (app target) | `FakeLocation` |
| `ConnectivityMonitor` | `SystemConnectivityMonitor` (`LetterboxDevice`: Network, CoreTelephony, CoreLocation) | `FakeConnectivity` |
| `SecretStore` | `KeychainSecretStore` (`LetterboxPersistence`) | `MemorySecrets` |
| `SettingsStore` | `UserDefaultsSettingsStore` (`LetterboxPersistence`) | `MemorySettings` |
| `BlobStore` | `EncryptedFileStore` (`LetterboxPersistence`) | `InMemoryBlobStore` |

`AppContainer` in the app target is the only place that knows which adapter backs which port.

## Domain services

- **`RoutePlanner`** picks the way for each private message: Bluetooth if the person is in reach, the internet if they're far and it's allowed (phase 2), otherwise an envelope, otherwise a queue with a reason. It's a pure function, so every combination is tested.
- **`ConnectionReport`** turns raw device readings and permissions into one plain-language row per connection. All user-facing wording about connectivity lives here.
- **`Courier`** seals and opens envelopes and computes the recipient tag that lets a courier recognise the person an envelope is for.

## What the device can and can't tell us

| Connection | Source | Notes |
|---|---|---|
| Bluetooth | CoreBluetooth manager state | On, off, not allowed, unsupported |
| Internet, Wi-Fi | `NWPathMonitor` | Connected via Wi-Fi, mobile data or cable; Low Data Mode. Whether the Wi-Fi radio itself is on can't be read |
| Mobile network | `CTTelephonyNetworkInfo` radio access technology | 5G, LTE, 3G, 2G or no service. No signal strength. Not on Mac |
| Texts | `MFMessageComposeViewController.canSendText()` | Whether the phone can send texts at all, not whether there's signal |
| Satellite | none | No public API. The app says so instead of guessing |
| Location | `CLLocationManager.authorizationStatus` | Permission only |
