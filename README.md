# HelloLetter

Offline communication when there's no internet: a peer-to-peer chat app for iPhone and Mac with no accounts and no servers.

- **Nearby chat over Bluetooth.** Phones form a mesh, and messages hop phone to phone (up to 7 hops) with no internet or signal.
- **Private messages.** End-to-end encrypted with the Noise protocol. Phones that relay them see only ciphertext.
- **Envelopes.** A private message to someone out of range is sealed and carried by people you pass, and delivered when one of them meets the person.
- **Nothing missed.** Messages wait up to 3 days for someone out of reach, and #nearby catches you up on the last 12 hours when you come back in range.
- **Alerts** with the phone locked, hiding names and text unless you choose otherwise.
- **Safety:** verify people in person, block, report, an offensive-word filter, a privacy screen, and Erase everything.
- **Reaching people without the app:** invite them, or send a one-way message over AirDrop, which works offline.

HelloLetter runs its **own network** (its own Bluetooth service, packet format and Nostr event kind), so it only talks to other copies of HelloLetter.

## Documentation

**Using HelloLetter**
- [Features](docs/features/README.md): one page per feature (what it does, why, how), plus scores and the field tests still needed.
- [Texting without internet: a hiker's field guide](docs/offline-texting-hiking-guide.md): HelloLetter, SMS and satellite texting on the trail.
- [Support: questions and answers](docs/support.md) and [Privacy policy](docs/privacy-policy.md), the public pages, also at [coder-rt.github.io/letterbox](https://coder-rt.github.io/letterbox/support).

**How it's built**
- [Architecture](docs/architecture.md): ports and adapters, the patterns used and why, how a message travels, the wire format.
- [Domain map](docs/domain.md): bounded contexts, glossary, and which port and adapter each concept lives in.
- [Design and accessibility](docs/design.md): screens, icons, colours with contrast ratios, the usability review and test script.
- [Testing](docs/testing.md): what's tested at each layer, and how to run unit, UI, device and security tests.
- [Wire-format test vectors](docs/wire-test-vectors.json): for other implementations.

**Security and release**
- [Security assessment](docs/security-assessment.md): threat model, findings with evidence, the OWASP DSOVS scorecard, `make security`.
- [Gap analysis](docs/gap-analysis.md): compared with bitchat's design docs. What was added, what's left out and why, and the release checklist.
- [Publishing on the App Store](docs/app-store-release.md) and the [store listing](docs/app-store-listing.md): what App Review needs, what's built, the steps from account to release, and ready-to-paste listing text.

## Running it

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and, for the iPhone, your Apple ID signed in to Xcode (Xcode → Settings → Accounts).

For the iPhone, also create a `Makefile.local` (it's ignored by git) with your own values:

```make
DEVICE := <your iPhone's identifier, from: xcrun devicectl list devices>
DEVELOPMENT_TEAM := <your Apple developer team ID, from Xcode → Settings → Accounts>
SUPPORT_EMAIL := <optional: where reports and questions go; see docs/app-store-release.md>
```

```bash
make test         # all LetterboxKit tests, no device needed
make ui-test      # iPhone UI tests in the simulator: simulated mesh, accessibility audits, screenshots
make security     # secret, dependency and static scans, plus the DAST attack suites
make run-mac      # build and open the Mac app
make mac-zip      # shareable Mac app (Release, universal, ad-hoc signed) in build/dist
make archive-ios  # App Store build: archive and upload to TestFlight (paid team in Makefile.local)
make install-ios  # build, install and launch on your iPhone (cable or same Wi-Fi)
```

Or `make gen && open Letterbox.xcodeproj` and press ⌘R with the `HelloLetter` (iPhone) or `LetterboxMac` scheme.

To try the mesh, run it on two devices, for example your iPhone and your Mac. The iOS Simulator has no Bluetooth.

On the iPhone, the first launch may need: Settings → General → VPN & Device Management → trust your developer certificate, and Settings → Privacy & Security → Developer Mode on.

## Known limits

- Anyone in Bluetooth range can see your nickname and public keys, and so recognise your phone while you keep the same identity. Erase everything starts a new one.
- Envelopes have no forward secrecy; live private sessions do.
- Chats are kept in memory only; your own undelivered messages, the people you've met and envelopes you carry are saved encrypted.
- Location channels (Debug builds only) connect to Nostr relays directly, so relays see your IP address.

What's deliberately not built yet, and why, is in the [gap analysis](docs/gap-analysis.md#not-done-and-why).

## Acknowledgements

The Pager theme uses [DSEG](https://github.com/keshikan/DSEG) by keshikan and [DotGothic16](https://github.com/fontworks-fonts/DotGothic16) by Fontworks, both under the SIL Open Font License (licences in `Letterbox/Resources/Fonts/`).

HelloLetter's overall approach is inspired by [bitchat](https://github.com/permissionlesstech/bitchat): a Bluetooth mesh with TTL-limited flooding, Noise XX for private messages, and geohash location channels over Nostr. Its [whitepaper](https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md) is a useful reference for the design choices. HelloLetter has its own wire format, Bluetooth service ID and Nostr event kind, so the two apps don't talk to each other.
