# Testing HelloLetter

## Running the tests

```bash
make test         # all LetterboxKit package tests: no device or radio needed
make ui-test      # iPhone UI tests in the simulator (simulated mesh, accessibility audits, screenshots)
make security     # gitleaks, osv-scanner, semgrep, and the DAST attack suites
```

- **UI tests** run the real app in a test mode (`-ui-testing`): the real store and mesh engine on a simulated radio with simulated phones (`UITestWorld`). Scenarios are picked with `UITEST_SCENARIO` (`nearby`, `alone`, `catchup`, `envelope`), plus `UITEST_CONNECTIVITY` and `UITEST_LOCATION_CHANNELS=off` for the App Store build's behaviour.
- **Real-device tests** (`LetterboxUITests/DeviceTests.swift`) skip themselves in the simulator. They check real connections, a real Bluetooth exchange with a Mac (`EXPECT_MAC_PEER`) and a real AirDrop (`AIRDROP_TARGET`). Run them on an iPhone with UI Automation enabled (Settings → Developer).
- A full UI run takes about 10–12 minutes per simulator; we run it on iOS 26.5 and 27.2.
- When the accessibility audit fails, it keeps a screenshot of each screen it checked, attached to the test result.

## What's covered

`make test` runs 364 package tests (parameterized tests count once), all without a device or radio, and `make ui-test` runs 20 iPhone UI tests in the simulator:
- **Domain:** geohash encoding at every level and the map's edges, nickname cleaning, identifiers and hex parsing
- **Wire format:** golden vectors published in [wire-test-vectors.json](wire-test-vectors.json), every packet type, the exact byte layout, forward-compatible TLV fields, payload limits, BLE chunking across MTUs, and fuzzing with random bytes and every single-bit flip
- **Crypto:** the Noise implementation byte for byte against the published conformance vectors, handshake turn-taking and tampering, nonce encoding, the replay window, and signatures
- **Mesh, on an in-memory radio:** multi-hop relay and the 7-hop limit, flood dedup, a 16-node grid, DMs through relays that never see plaintext, simultaneous handshakes, groups that meet, lost sessions, the offline queue and its expiry, couriers (a message and its receipt carried between people who never meet, copy limits, carry time, forged or extended envelopes, delivery through relays), surviving restarts, catching up on missed #nearby messages (latecomers, walkers between groups, restarts), and attacks (forged senders, announces and leaves, replayed receipts, stale timestamps, garbage frames, envelope floods, forged or unsolicited history)
- **Nostr:** NIP-01 serialization and signing, and the location channel fed with simulated relay traffic: filtering, dedup, echoes and per-area keys
- **Persistence:** Keychain and settings stores (Keychain tests skip themselves where the Keychain isn't available), erasing everything, and clearing keys left by a deleted app
- **ChatStore:** commands, channels, unread counts, delivery states, location channels, nickname handling, privacy mode, the Bluetooth and internet switches, envelope summaries, lock-screen alerts (hidden by default), blocking and erasing
- **Routing and connectivity:** every combination in the route planner, every status in the connections panel, and the device readings mapping
- **Store and engine together:** the real `ChatStore` on the real mesh engine with simulated phones: private messages with receipts, Bluetooth off then on (both ways), envelope summaries from hand-off to receipt, verification and impostor detection
- **UI tests (simulator):** nearby chat, private messages with ticks, verifying someone, the privacy screen, the Connections panel with Bluetooth off then on, an offline device with the internet switch, an envelope carried by a passing hiker, catching up on #nearby after arriving, the empty #nearby screen when you're alone, blocking and reporting someone, the App Store build without location channels, erasing everything, Apple's accessibility audit on every screen, and screenshots in light, dark and the largest text size

## Security tests

The DAST suites attack a running node the way a hostile phone in range would, and assert the fixed behaviour; see the [security assessment](security-assessment.md) for each finding. Wire-format drift is caught by `WireVectorTests` against [wire-test-vectors.json](wire-test-vectors.json).

## Before a release

See the release checklist in the [gap analysis](gap-analysis.md#release-checklist) and the field tests still needed in [features](features/README.md#field-tests-still-needed).
