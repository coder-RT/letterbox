# Letterbox features, scored

Last scored: 2026-11-15, after the gap analysis against the reference docs (see [gap-analysis.md](gap-analysis.md)): catching up on #nearby, lock-screen alerts, background relaunch, blocking and erasing.

Each feature is scored 1–5 on three things:

- **Value:** how much it helps people with no internet, such as hikers.
- **Done:** how complete it is today.
- **Tests:** how well automated tests cover it. "–" means it can't sensibly be unit-tested (layout, platform).

**Overall** is the average of the three, or of the two scored ones. Planned features show only their value, as a priority signal.

## Offline messaging (core)

| Feature | Status | Value | Done | Tests | Overall | Notes |
|---|---|---|---|---|---|---|
| #nearby group chat over Bluetooth | Shipped | 5 | 4 | 5 | 4.7 | Range roughly 10–50 m between phones |
| Multi-hop relay (7 hops), dedup, loop protection | Shipped | 5 | 5 | 5 | 5.0 | Tested on lines, grids, loops and partitions |
| Private messages, end-to-end encrypted (Noise XX) | Shipped | 5 | 5 | 5 | 5.0 | Checked against published Noise vectors |
| Delivery and read receipts | Shipped | 4 | 5 | 5 | 4.7 | |
| Offline queue: 3 days, 500 messages, saved and encrypted | Shipped | 5 | 4 | 5 | 4.7 | Survives restarts |
| Envelopes: messages carried by other hikers | Shipped | 5 | 4 | 5 | 4.7 | Needs a field test with 3 phones |
| Envelopes screen and envelope icon with carrier count | Shipped | 4 | 4 | 5 | 4.3 | Unit, integration and UI tests (simulated courier) |
| Signatures, forgery and replay protection | Shipped | 4 | 5 | 5 | 4.7 | Found and fixed a nonce-0 replay bug |
| Catching up on #nearby: missed public messages (last 12 hours) from the first neighbour you meet | Shipped | 5 | 4 | 5 | 4.7 | Also carries messages between groups that never meet; signature checked; only answers to your own request |
| Emoji over Bluetooth | Shipped | 3 | 5 | 4 | 4.0 | Text is UTF-8; no internet needed |
| Send outside Letterbox (AirDrop or other apps, one-way) | Shipped | 4 | 4 | 4 | 4.0 | Offline to nearby Apple devices; they tap Accept and can't reply unless they install Letterbox |
| Invite someone (share a note with how to get Letterbox) | Shipped | 4 | 5 | 4 | 4.3 | In "Send outside Letterbox" and on the empty Nearby list |
| Nickname and commands (`/msg`, `/who`, `/nick`, `/clear`, `/help`) | Shipped | 3 | 5 | 5 | 4.3 | |
| Verification: safety number, QR scan, Verified badge, impostor warning | Shipped | 4 | 4 | 4 | 4.0 | QR scan needs a real camera to test |
| Lock-screen alerts for #nearby and private messages | Shipped | 5 | 4 | 5 | 4.7 | Local only; names and text hidden unless you choose, and always with the privacy screen on |
| Running in the background, relaunched by iOS for Bluetooth (state restoration) | Shipped, needs field test | 5 | 4 | 1 | 3.3 | iOS slows Bluetooth in the background; can't be automated |
| Block a person | Shipped | 3 | 4 | 5 | 4.0 | Hides their messages everywhere; your phone still relays them for others |
| Report a message (blocks the sender; optional email report) | Shipped | 3 | 4 | 5 | 4.0 | App Review guideline 1.2; email goes to the publisher's support address when set |
| Offensive-word filter, on by default | Shipped | 3 | 4 | 5 | 4.0 | On the phone only; Settings → Help and safety |
| Conversation history | Memory only, by design | 3 | 2 | 4 | 3.0 | Only your undelivered messages are saved; catching up refills #nearby after a restart |

## Routing and connectivity

| Feature | Status | Value | Done | Tests | Overall | Notes |
|---|---|---|---|---|---|---|
| Connections panel: status for Bluetooth, internet, Wi-Fi, mobile, satellite, location, relays, envelopes | Shipped | 5 | 4 | 5 | 4.7 | Unit, integration and UI tests; satellite honestly shown as undetectable |
| Toolbar connection chip | Shipped | 4 | 4 | – | 4.0 | |
| Bluetooth and internet toggles (permissions) | Shipped | 4 | 5 | 5 | 4.7 | Turning Bluetooth off and on was tested end to end |
| Automatic route choice (`RoutePlanner`) | Shipped | 4 | 3 | 5 | 4.0 | Internet route arrives in phase 2 |
| Mobile signal type (5G, LTE…) | Shipped | 3 | 3 | 4 | 3.3 | No signal strength API; iPhone only |
| Satellite status | Not possible | 3 | 1 | 5 | 3.0 | No public API; the app explains instead |

## Internet features

| Feature | Status | Value | Done | Tests | Overall | Notes |
|---|---|---|---|---|---|---|
| Location channels over Nostr relays | Debug builds only | 2 | 4 | 4 | 3.3 | Needs internet; relays see your IP. Left out of the App Store build |
| Private messages over the internet | Phase 2 | 4 | – | – | – | Sealed, through Nostr relays |
| Photos over the internet | Phase 2 | 3 | – | – | – | Shrunk to about 50 KB, EXIF and GPS removed |
| Videos | Later | 2 | – | – | – | |
| Tor for relay connections | Planned | 2 | – | – | – | |

## App and platform

| Feature | Status | Value | Done | Tests | Overall | Notes |
|---|---|---|---|---|---|---|
| Privacy screen (menu, banner, tap to peek, app-switcher cover) | Shipped | 3 | 5 | 5 | 4.3 | UI test checks VoiceOver reads "Hidden message" |
| Accessibility (audit clean on every screen, Dynamic Type, contrast, VoiceOver) | Shipped | 4 | 4 | 5 | 4.3 | See docs/design.md for the three documented exclusions |
| iPhone app | Shipped | 5 | 4 | – | 4.5 | |
| Mac app | Shipped | 2 | 4 | – | 3.0 | No mobile network or app-switcher cover |
| iPad layout | Planned | 1 | – | – | – | |
| Erase everything (Settings, with a confirmation) | Shipped | 3 | 5 | 5 | 4.3 | Keys, state files, settings and alerts; a reinstall also clears keys left in the Keychain |
| Privacy manifest (`PrivacyInfo.xcprivacy`) | Shipped | 2 | 5 | – | 3.5 | Needed for App Store submission |
| Wire-format golden vectors (`docs/wire-test-vectors.json`) | Shipped | 2 | 5 | 5 | 4.0 | For other implementations; a test fails if the format drifts |

## Field tests still needed

These are covered by automated tests on a simulated radio, but not yet tried on real phones:

1. **Envelopes end to end** with three phones: A and C never meet; B walks between them. Check the message arrives and the receipt comes back.
2. **Mobile network row** on an iPhone with and without signal, and in airplane mode.
3. **Bluetooth toggle** off and on: the other phone should drop you, then see you again.
4. **Background delivery:** how long a message takes to arrive with Letterbox in the background.
5. **Range** between two phones in open terrain, in forest and through rock.
6. **State restoration:** with Letterbox in the background, simulate iOS closing it (see the release checklist in [gap-analysis.md](gap-analysis.md)), then bring a second phone into range: Letterbox should relaunch and the message should arrive.
7. **Lock-screen alert** with the phone locked: shows "New private message" only, and the name and text once you turn that on.
8. **Catching up across groups:** A and B talk, B walks to C, and C sees what A said.
