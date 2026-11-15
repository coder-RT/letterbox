# Gap analysis: HelloLetter against bitchat's design docs

Date: 2026-11-15. Compared against bitchat's architecture, BLE, sync, routing, peer-ID rotation, service-UUID, push-to-talk, private-media, Tor, build-verification and privacy documents, and its courier test vectors.

**Motto: offline communication when there is no internet.** Each gap was judged by one question: does it change whether a message gets through, or stays private, when nobody has signal? Every gap is either fixed here or has a stated reason.

## Summary

| | Count | Items |
|---|---|---|
| Fixed in this pass | 10 | Catching up on #nearby, lock-screen alerts, background relaunch, a Bluetooth restart bug, courier deposit flood (SEC-15), erase everything, keys surviving an uninstall, blocking, privacy manifest, wire-format golden vectors |
| Already equivalent | 14 | See [Already covered](#already-covered-checked-in-the-code) |
| Deferred, with a reason | 15 | See [Not done, and why](#not-done-and-why) |

## Fixed in this pass

### 1. Catching up on #nearby (missed public messages)

**Gap.** Private messages already had an outbox and couriers, but a #nearby message sent while you were out of range, switched off, or not there yet was lost for good. On a trail, "Meet at the hut at 5" is exactly that kind of message. bitchat solves this with gossip sync.

**Done.** When a phone gets a new direct neighbour, it sends a link-local request (TTL 1) listing the IDs of the recent #nearby messages it already holds. The neighbour answers with what's missing: each message exactly as its author signed it, plus the author's signed announce so it can be checked. Messages are kept for 12 hours (at most 300, in memory only). Because every phone passes on what it caught up on, a walker carries news between two groups that never meet. It also refills #nearby after the app restarts, since chats live in memory.

**Simpler than bitchat, on purpose.** bitchat sends compact Golomb-coded filters, sized for a 1,000-packet archive. HelloLetter lists up to 300 8-byte IDs: at most 2.4 KB once per meeting, with no filter maths to get wrong.

**Security** (SEC-16 in the [assessment](security-assessment.md)): answers are accepted only to our own request, on that link, for 30 seconds, and at most 100 of them. Both signatures are checked. A message can't claim a live person's ID with another key, and nothing is relayed.

**Verified.** 9 package tests (latecomer, a walker between groups, restart with your own messages shown as yours, nothing sent twice, bounds, unsolicited, forged, stale or excessive history, ID theft, never relayed), a ChatStore ordering test, and the UI test `testCatchingUpOnNearbyAfterArriving`.

### 2. Lock-screen alerts

**Gap.** HelloLetter posted no notifications. With the phone in a pocket you'd never know a reply had come, which defeats offline messaging on a hike.

**Done.** Local notifications (no push server, nothing leaves the phone) for #nearby and private messages while HelloLetter is off screen. There's one alert per conversation, updated with a count and cleared when you open it. A locked screen can be read by anyone, so by default an alert says only "New private message" or "New message in #nearby". Names and text appear only if you turn on **Settings → Alerts**, and never while the privacy screen is on. Permission is asked when you first send a message, when a reply makes sense, not at launch. Caught-up history, location channels and blocked people never raise an alert.

**Verified.** 7 tests: wording, hidden by default, opting in, the privacy screen overriding it, no alert for your own messages, history or duplicates, clearing when opened, and asking once.

### 3. Running after iOS closes HelloLetter (Bluetooth state restoration)

**Gap.** HelloLetter had the Bluetooth background modes but no state restoration. When iOS ended it to free memory, the phone dropped off the mesh until someone opened the app again.

**Done.** Both Bluetooth managers now pass restore identifiers. Restored connections, our published service and its subscribers are taken back rather than duplicated. The app also starts the mesh when it launches, not from a view: a background relaunch creates no window, so a view-based start never ran.

**Verified.** The app builds for iOS and macOS (the restoration code is iOS-only). The behaviour itself needs a real device; see the [release checklist](#release-checklist).

### 4. Bug found: no advertising after Bluetooth was turned off and on in HelloLetter

`stop()` left the old characteristic in place, so the next start skipped publishing the service. The phone stopped advertising while it could still connect out, which hid the problem. Fixed in `BLELinkLayer.stop()`.

### 5. Courier deposit flood (SEC-15)

**Gap.** bitchat's couriers keep per-depositor quotas. HelloLetter's didn't: one hostile phone could deposit 256 envelopes that expire later than everyone else's and evict every genuine one.

**Done.** At most 30 deposits per link per minute, and one depositor fills at most 32 of the 256 slots.

**Verified.** 3 DAST tests, including a genuine envelope surviving 1,000 junk deposits and still reaching its recipient.

### 6. Erase everything

**Gap.** There was no way to wipe HelloLetter from a phone you're about to lose or hand over.

**Done.** **Settings → Erase everything**, with a confirmation. Mesh traffic stops first, so nothing is saved again. It then deletes the Keychain items, the encrypted state files, the settings and any delivered alerts. The chat is replaced by a screen saying it's erased, and the next launch starts as a new person.

**Unlike bitchat:** no hidden triple-tap, because an accidental wipe in the field loses undelivered messages. There's also no decoy or duress mode. As bitchat's own privacy assessment says, that's a product and legal decision, not a default.

**Verified.** Store tests (stops the mesh, wipes, writes nothing afterwards), eraser tests on a temporary folder and settings domain, and the UI test `testEraseEverythingAsksFirstThenStops`.

### 7. Keys surviving an uninstall

**Gap.** iOS Keychain items outlive the app. Delete HelloLetter, reinstall it, and you were still the same person, which isn't what someone deleting the app expects.

**Done.** A fresh install (no settings yet) clears leftover secrets before loading keys. An update from an earlier version keeps your identity, because the nickname setting shows it isn't a fresh install.

**Verified.** 2 tests.

### 8. Blocking

**Gap.** There was nothing between rate limits and walking away. Someone posting within the limit could still spam #nearby or your private messages.

**Done.** **Block** on a person's page hides everything they send: earlier messages, new ones, caught-up history and alerts. It's saved encrypted and survives restarts. Your phone still relays their packets for others, because the mesh needs every phone.

**Verified.** A store test and the UI test `testBlockingSomeoneHidesTheirMessages`.

### 9. Privacy manifest

**Gap.** HelloLetter had no `PrivacyInfo.xcprivacy`, which App Store submission requires.

**Done.** The manifest declares no tracking, no collected data, and one required-reason API: UserDefaults with reason CA92.1 (the app's own settings). Both apps bundle it.

### 10. Wire-format golden vectors

**Gap.** bitchat pins its courier format with test vectors because three encoding mistakes fail silently. HelloLetter had no published vectors.

**Done.** [`wire-test-vectors.json`](wire-test-vectors.json) covers keys and fingerprint, the payloads, packet signing bytes and encoding, the sync request, the courier tag and prologue, the safety number and the QR payload, plus the same traps (milliseconds, what's signed, randomised signatures). `WireVectorTests` recomputes every value, so the format can't drift without a test failing.

## Already covered (checked in the code)

| bitchat has | HelloLetter |
|---|---|
| Outbox sealed at rest, Keychain key | `EncryptedFileStore` (ChaCha20-Poly1305); 3 days and 500 messages (bitchat: 24 h, 100 per peer) |
| Couriers: Noise X sealing, copy budget, expiry | 8 couriers, 3 days, retried until expiry |
| Controlled flood: TTL 7, dedup, jitter, no echo | Same: 10–150 ms jitter, seen-set of 4,096 for 10 minutes |
| Freshness check on packets | ±10 minutes (bitchat: 2); old messages come in only through solicited catch-up |
| Ingress caps and rate limits | SEC-01 to SEC-03 and SEC-08 limits |
| Signed announces and public messages; Noise XX for private | Same, checked against published Noise vectors |
| Delivery and read receipts | Same; merged and capped (SEC-02) |
| Verification by QR or safety number | Signal-style safety number, QR scan, impostor warning |
| Keychain items stay on the device | `AfterFirstUnlockThisDeviceOnly` |
| File protection | `completeUntilFirstUserAuthentication` on iOS |
| App-switcher cover | Shown with the privacy screen on, like Signal's opt-in setting |
| Redacting logger, no message content in logs | `os.Logger`; only link and relay identifiers are public |
| Minimal advertisement | Service UUID only: no name, no manufacturer or service data |
| Separate Nostr identity per area | `NostrKeys.forGeohash` |

## Not done, and why

| Item | Why not now | Revisit when |
|---|---|---|
| **Rotating peer IDs and encrypted announces** (SEC-04) | Rotation alone does nothing while announces carry the static keys in clear (bitchat's own conclusion), and the PeerID's binding to the key must be replaced in the same change (SEC-11). That's a wire-protocol v2 | Protocol v2: rotation, announce confidentiality and binding together |
| **Courier tag anyone can compute** (SEC-05) | The tag hashes the recipient's public fingerprint, the same mistake bitchat's rotation doc warns about. A real fix derives tags from a shared secret, with prekeys for forward secrecy: a v2 change | Protocol v2, together with SEC-04 |
| **Padding private messages to fixed sizes** | It hides only length; content is already encrypted. It changes the encrypted payload format, so it should ship once, with v2, not as a second breaking change | Protocol v2 |
| **Hiding that HelloLetter is in use** (service UUID) | Not achievable while strangers must find each other: anyone can run the open-source app and compute any UUID it uses, and connecting reveals the GATT layout anyway. bitchat reached the same conclusion. The honest position is to say so | Never as the default; maybe an opt-in, contact-only mode |
| **Source routing and neighbour lists in announces** | Neighbour lists broadcast who is standing near whom, a social graph. Hiking groups are small and flooding is reliable on thin chains; a routed packet dies at one broken hop | Field tests show congestion |
| **Fan-out subsets and TTL clamping in dense meshes** | They trade delivery for airtime in crowds; hiking meshes are thin lines. Floods are already bounded by the rate limits and caps | Testing at festival scale |
| **Voice (push-to-talk), voice notes, photos, files** | A Bluetooth mesh carries a few KB/s per link. Each feature means the microphone or photo library, large transfers and more attack surface. Text first | Text is solid on real devices |
| **Private group chats** | #nearby plus private messages cover a small group; group keys and rosters are a large feature | After v2 identity work, which group membership depends on |
| **Bulletin board (expiring posts for an area)** | Catching up already covers 12 hours of #nearby; boards also need persistence and location | Users ask for notes longer than a day |
| **Gateway and bridge** (a phone with signal links the mesh to the internet) | It suits the motto (one person with signal helps everyone), but it's internet work that depends on private messages over the internet (phase 2) | Phase 2, internet private messages |
| **Private messages over Nostr** | Internet route, planned as phase 2; `RoutePlanner` already has the hook | Phase 2 |
| **Tor** | Internet only. Location channels are opt-in and their IP exposure is stated (SEC-13). Bundling Tor means a Rust binary with its own provenance and update burden | Internet private messages ship |
| **Presence heartbeats for location channels** | Internet only, and it broadcasts that you're in an area every minute: a privacy cost with no offline benefit | – |
| **Separate Bluetooth network for debug builds** | Only matters once real users exist next to test builds | First TestFlight or App Store build |
| **Reproducible or signed builds and a source manifest** | No binaries are distributed yet; people build from source. The verification steps below cover source | First distributed binary: sign tags, publish a manifest, add a mirror |

Not applicable: per-fragment resync (HelloLetter chunks per link and reassembles at each hop), the private-media wire migration, and the architecture refactors (HelloLetter already has a single store, a link-layer port and a simulated radio, the shape those docs move towards).

## Release checklist

Run before each release, and whenever storage, notifications or Bluetooth code changes.

1. **New storage reaches Erase everything.** Every new Keychain item, file under `Application Support/Letterbox`, or setting must be deleted by `DeviceDataEraser`. Add a test.
2. **Privacy manifest.** Re-scan for required-reason APIs (file timestamps, system uptime, disk space, UserDefaults outside the app) and update `PrivacyInfo.xcprivacy`.
3. **Wire format.** `swift test` must pass `WireVectorTests`. If a vector changes on purpose, regenerate it (`LETTERBOX_WRITE_VECTORS=1`), review the diff, and decide whether old phones can still talk to new ones.
4. **Locked screen.** Lock a real phone, send it a private message: the alert says "New private message" and nothing else. Turn on names and text, check again, then turn on the privacy screen: hidden again.
5. **App switcher.** With the privacy screen on, the app-switcher snapshot shows the cover.
6. **State restoration** on a real iPhone: open HelloLetter and put it in the background. Swiping it away counts as the user quitting and turns restoration off, so end it the way iOS would instead: `xcrun devicectl device process signal --device <id> --pid <pid> --signal SIGKILL` (find the pid with `xcrun devicectl device info processes --device <id>`). Bring a second phone into range: HelloLetter should relaunch in the background and the message arrive with an alert. Not yet confirmed on a device; record the result in [features](features/README.md).
7. **Bluetooth off and on in HelloLetter:** the other phone sees you again within a few seconds, in both directions.
8. **`make security`:** gitleaks, osv-scanner, semgrep and the security tests.
9. **Verify your source.** Before building a release, `git status --porcelain --ignored` prints only expected build output, and `git rev-parse HEAD` matches the commit you meant to build. Record that commit somewhere outside GitHub.
