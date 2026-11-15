# Letterbox security assessment

| | |
|---|---|
| Date | 2026-11-15 |
| Code | assessed at commit `c476cbc`; fixes in `b5f1f9d` and the following commit (branch `security`) |
| Platforms tested | iPhone 16 Pro on iOS 27.0.1 (real device), iOS 26.5 and 27.2 simulators, macOS app |
| Standard | [OWASP DevSecOps Verification Standard (DSOVS)](https://github.com/OWASP/www-project-devsecops-verification-standard), commit `09be4c6` (2026-08-01) |
| Re-run | `make security` (scanners and DAST suites), `make test`, `make ui-test` |

## Status after fixes (2026-11-15)

| Finding | Severity | Status |
|---|---|---|
| SEC-01 Peer table flood | Medium | **Fixed.** Capped at 256 and 32 new identities per link per minute. DAST: 1,000 forged gives 32 peers; 400 over 10 links gives 256 |
| SEC-02 Receipt amplification | Medium | **Fixed.** Receipts merged (at most 2 pending, 50 IDs each); the queue limit covers all items. DAST: 300 envelopes give 2 receipt envelopes (was 300) |
| SEC-03 No rate limit | Medium | **Fixed.** Per-sender and per-link limits, checked after the signature; rejected messages aren't relayed. DAST: 30 of 500 relayed (was 500) |
| SEC-04 Trackable identity | Medium | Open: needs protocol v2 (identity rotation) |
| SEC-05 Envelope privacy limits | Low | Open by design: protocol v2 (rotating tags, prekeys) |
| SEC-06 Crypto dependency behind | Low | **Fixed.** Upgraded to swift-secp256k1 0.25.1; x-only keys validated when created |
| SEC-07 Replay after restart | Low | **Fixed.** Recent envelope and message IDs saved in the encrypted state file. DAST: replay after restart is ignored |
| SEC-08 Bluetooth queues have no limit | Low | **Fixed.** 1,024 chunks per write queue, 4,096 for notifications |
| SEC-09 Clipboard syncs | Low | **Fixed on iOS:** local-only, expires after 2 minutes. macOS has no local-only option |
| SEC-10 Test code in Release | Low | Accepted for now: the test entry point is compiled out (verified). Xcode can't link a package product for Debug only, so this needs moving the simulated world into a debug-only module |
| SEC-11 First announce wins a PeerID | Low | Open: to be designed with protocol v2 (bind PeerID to proof of key) |
| SEC-12 to SEC-14 | Info | Accepted or documented |

All 9 mesh DAST tests now assert the fixed behaviour; no known issues remain in the suite.

## Summary (at the time of the assessment)

Letterbox has **no critical or high-severity vulnerabilities**: no hardcoded secrets, no known-vulnerable dependencies, no static-analysis findings, no way to forge or read another person's messages, and the app survived every crash and fuzzing attack thrown at it.

The weaknesses found are **denial of service by someone in Bluetooth range** and **privacy limits of the protocol**:

| Severity | Count | Findings |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 4 | SEC-01 peer-table flood, SEC-02 receipt amplification, SEC-03 no rate limit, SEC-04 trackable identity |
| Low | 7 | SEC-05 to SEC-11 |
| Informational | 3 | SEC-12 to SEC-14 |

Three of the four medium findings were **confirmed dynamically**: attacks against a running engine succeeded, and they're recorded as known issues in the DAST suite. Each one will start failing its test the moment it's fixed.

## Scope and threat model

**In scope:**
- The iOS and macOS app.
- The mesh protocol over Bluetooth: packets, Noise XX sessions, Noise X envelopes and couriers.
- Location channels over Nostr relays.
- Local storage: Keychain, the encrypted state file, settings.
- The build and the shipped binary.
- The source repository.

**Out of scope:** the Nostr relays themselves, Apple's platform security, and physical attacks on an unlocked phone.

| Attacker | Can do | Goal |
|---|---|---|
| **Nearby phone** (in Bluetooth range, may run modified software) | Send any frame, mint any number of identities, replay captured traffic, relay or drop packets | Read or forge private messages, impersonate people, crash or exhaust phones, flood the mesh |
| **Passive listener** (a Bluetooth sniffer) | Record everything on the air | Read messages, track people across days |
| **Courier** (an honest-but-curious hiker carrying envelopes) | Store, delay, replay or drop envelopes | Read envelopes, learn who talks to whom |
| **Nostr relay or poster** | Send any JSON, see IP addresses | Crash the app, forge posts, locate users |
| **Someone holding the phone** (locked) | Read files at rest | Read queued messages and contacts |
| **Repository reader** | Read the public GitHub repo | Find secrets or personal data |

## Methodology

| Activity | Tool or method | DSOVS control |
|---|---|---|
| Secret scanning (history and files) | gitleaks 8.x | CODE-002 |
| Manual secure code review | Line review of protocol, crypto, parsing, storage, UI privacy | CODE-003 |
| Static analysis | semgrep 1.185.0 (`p/swift`, `p/secrets`, `p/insecure-transport`), metrics off | CODE-004 |
| Dependency vulnerabilities | osv-scanner 2.7.1, GitHub advisories for each dependency | CODE-005 |
| Licence check | GitHub licence metadata | CODE-006 |
| Dynamic testing (DAST) | New attack suites run against a live engine (`SecurityDASTTests`, `SecurityRelayFuzzTests`); real-device and real-Bluetooth tests | TEST-002 |
| Binary and configuration review | Release build: `strings`, `otool`, `nm`, `codesign`, Info.plist | OPR-002, REL-004 |
| Security regression tests | Existing forgery, replay and tamper tests (323 package tests, 11 UI tests) | TEST-005 |

**About DAST for this app.** The DSOVS DAST tools (ZAP, Nuclei) scan web applications over HTTP. Letterbox has no web server. Its running attack surface is the Bluetooth mesh protocol and the relay WebSocket traffic, so DAST here means attacking a running engine with hostile frames, as a malicious phone nearby would. These suites run on demand (`make security`), which is DSOVS level 1.

## Findings

### SEC-01 Peer table has no size limit (Medium, confirmed)

Every validly signed announce adds an entry to the peer table, and an attacker can generate new identities for free.
- **Evidence:** `SecurityDASTTests.peerTableFloodWithFreshIdentities`. 1,000 forged identities produced **1,000 peers** on the victim. The list stays until each entry times out after 60 s, and the attacker can keep refreshing it.
- **Impact:** memory and CPU use grow without bound. The People list fills with ghosts, real people get hard to find, and every peer change is republished to the UI.
- **Fix:** cap the table at about 256 entries. Evict the least recently seen, while preferring direct, verified and in-session peers. Rate-limit new identities per Bluetooth link.

### SEC-02 Receipts for a stranger's messages are amplified through couriers (Medium, confirmed)

Anyone who knows your public key, which is in every announce, can seal envelopes to you. Each one you open queues a delivery receipt to its sender. If the sender is unreachable, those receipts are sealed into envelopes and handed to up to 8 neighbours each.
- **Evidence:** `SecurityDASTTests.envelopesFromAStrangerAmplifyIntoQueuedReceiptsAndCourierTraffic`. 300 attacker envelopes made the victim hand **300 receipt envelopes to a single neighbour**. With 8 couriers that's 2,400.
- **Why it isn't capped:** the 500-message queue limit only applies to messages you write, not to receipts. These receipts are also saved to disk.
- **Impact:** storage, battery and airtime exhaustion, and the victim's phone becomes a traffic amplifier.
- **Fix:**
  - Apply the queue limit to every outbox item.
  - Cap receipts per sender.
  - Don't seal receipts for senders you've never met directly, or batch them into one receipt per sender.

### SEC-03 No per-sender rate limit on relayed traffic (Medium, confirmed)

Each new packet is relayed to every neighbour, up to 7 hops.
- **Evidence:** `SecurityDASTTests.publicMessageFloodIsRelayedWithoutRateLimit`. **500 of 500** spam messages from one sender were relayed onward.
- **Impact:** one phone can saturate a whole group's mesh, drain batteries and push real messages out.
- **Fix:** per-sender and per-link token buckets, for example 20 public messages a minute per sender. Drop the excess before relaying. Give unknown or unverified senders lower limits.

### SEC-04 Announces broadcast a stable identity in clear text (Medium, privacy)

Announces carry your nickname and long-term public keys, unencrypted. The Bluetooth service ID is also fixed for every Letterbox phone.
- **Evidence:** code review (`AnnouncePayload`, `BLELinkLayer.serviceUUID`); already noted in the README.
- **Impact:**
  - A passive listener can recognise the same person across days, even though the PeerID changes on every launch.
  - Anyone can tell a phone runs Letterbox.
- **Fix:** rotate announce identities and reveal long-term keys only inside the encrypted handshake (bitchat's `PEER-ID-ROTATION.md` is a reference). Consider rotating the advertised service data. This is a protocol change, so it needs a version bump.

### SEC-05 Envelope privacy limits (Low, by design)

- A courier who has seen the recipient's announce can test the recipient tag, and so learn who an envelope is for.
- Envelopes are sealed with Noise X, which has no forward secrecy: someone who later steals the recipient's static key can open envelopes they captured.
- **Evidence:** design review; already documented in the README.
- **Fix:** accept and document as now, or move to rotating recipient tags plus prekeys (bitchat's courier and prekey design).

### SEC-06 Crypto dependency one release behind (Low)

`swift-secp256k1` is pinned at 0.24.0; the latest is 0.25.1.
- **0.25.0** changed code paths that could abort on attacker-controlled input so they throw errors instead. For example, x-only keys are now validated when they're created.
- **The only published advisory** (GHSA-7g3x-fj89-693j) affects 0.25.0's MuSig API only, which Letterbox doesn't use.
- **Evidence:**
  - osv-scanner: no known vulnerabilities in 0.24.0.
  - `SecurityEventKeyFuzzTests`: 2,000 Nostr events with random public keys, about half of them invalid curve points, were all **rejected without a crash**. Not exploitable today.
- **Fix:** upgrade to 0.25.1. It has breaking API changes (signature serialisation, throwing initialisers), so migrate and rerun the Nostr tests.

### SEC-07 A replayed envelope is shown again after a restart (Low, confirmed)

The list of envelopes already opened, and the list of private message IDs already received, are kept in memory only.
- **Evidence:** `SecurityDASTTests.aReplayedEnvelopeIsShownAgainAfterTheRecipientRestarts`. After the recipient restarted, a replayed envelope was **shown again**. Before the restart, the replay was dropped.
- **Impact:** a courier can make an old message reappear, and trigger another receipt, until the envelope expires (up to 3 days).
- **Fix:** save recently opened envelope IDs and received message IDs in the encrypted state file.

### SEC-08 Bluetooth send queues have no limit (Low)

`BLELinkLayer.writeQueues` and `notifyQueue` grow without limit while a link is slow.
- **Evidence:** code review.
- **Impact:** combined with SEC-03, memory grows on a congested link.
- **Fix:** cap each queue and drop the oldest relayed frames first; keep your own messages.

### SEC-09 Copied text syncs to other devices (Low)

"Copy" writes to the general clipboard, which Universal Clipboard can sync to your other Apple devices.
- **Evidence:** `Clipboard.copy` in `MessageList.swift`.
- **Fix:** on iOS, `UIPasteboard.general.setItems(_, options: [.localOnly: true, .expirationDate: now + 2 min])`.

### SEC-10 Test-only code is linked into Release builds (Low)

The UI-test mode is compiled out of Release: `strings` finds no `-ui-testing` flag and no `UITestWorld`. But the `LetterboxTestSupport` library is still linked, so `InMemoryRadio`, `SimulatedPhone` and `ScriptedConnectivityMonitor` ship in the binary unused.
- **Evidence:** a Release build, then `strings -a Letterbox | grep …`.
- **Fix:** link `LetterboxTestSupport` only in Debug, with a debug-only target or a build setting, or move the simulated world into a debug-only module.

### SEC-11 First announce wins a PeerID (Low)

If an attacker announces a victim's PeerID with the attacker's own keys before the real announce reaches a phone, that phone ignores the real person for the rest of the session.
- **Evidence:** code review (`handleAnnounce`, "PeerID already bound"), and the existing test `announceClaimingAKnownPeerIDWithOtherKeysIsIgnored`.
- **Impact:** a targeted denial of service for one person, one session at a time. It can't be used to read or forge messages.
- **Fix:** when two keys claim one PeerID, keep both until a handshake proves which is real, or derive the PeerID from the key.

### SEC-12 Unsigned public messages from strangers are shown (Informational)

A public message from a sender whose announce we haven't heard is shown with a "?" marker, and its nickname isn't verified.
- **Fix:** none needed. It's a usability trade-off, and the marker is explained in the message's long-press info.

### SEC-13 Location channels reveal your IP address to relays (Informational)

This is already explained in the app and the README. The "Use the internet" switch turns it off completely.
- **Fix:** Tor or a proxy option, already on the roadmap.

### SEC-14 Development builds allow debugging (Informational)

The installed build is signed with a development profile, so `get-task-allow` is true. App Store and TestFlight builds turn this off automatically.

## What was verified secure

| Area | Result | Evidence |
|---|---|---|
| Private messages | End-to-end encrypted. Relays and couriers never see plaintext | `directMessageIsEncryptedEndToEndThroughARelay`, `aCourierCarriesTheMessage…` (no plaintext in any frame) |
| Noise implementation | Byte-exact against published test vectors; Noise X matches a separate step-by-step reference | `matchesPublishedVectors`, `matchesAStepByStepReferenceOfTheSpec` |
| Forgery | Forged senders, announces, leaves and envelopes are rejected; a courier can't extend expiry or fake the sender | `messagesForgedInAKnownPeersNameAreDropped`, `forgedLeaveDoesNotKickAPeer`, `aCourierCannotExtendTheExpiryOrForgeTheSender`, `mutatedCopiesOfARealPacketNeverImpersonateItsSender` |
| Replay (live session) | The replay window rejects reused nonces; the nonce-0 replay bug was found and fixed earlier | `replayedReceiptWithANewPacketIDIsIgnored`, `nonceZeroCanOnlyBeUsedOnce` |
| Malformed input | No crash from 4,000 random frames, 2,000 relay frames, deep JSON nesting or every single-bit flip of a packet | `randomAndCorruptedFramesNeverCrashOrWedgeANode`, `hostileRelayMessagesNeverCrashOrForgePosts`, `everySingleBitFlipIsHandled` |
| Size limits | 32 KB packets, 2,000-byte text, 4 KB envelopes, 256 carried envelopes, 32 pending handshakes, frame reassembly bounded | `oversizedAndStaleFramesAreRejected`, `envelopeStorageFloodStaysCapped` |
| Data at rest | Keys in the Keychain (`AfterFirstUnlockThisDeviceOnly`); state file encrypted with ChaCha20-Poly1305 under a Keychain key; iOS file protection | `EncryptedFileStoreTests` (file reveals nothing; wrong key or tampering reads as empty) |
| Verification | Safety numbers are symmetric and stable; QR codes are strict; impostors are flagged | `VerificationTests`, `impostorsUseAVerifiedNameWithAnotherKey` |
| Network | TLS (`wss://`) only, no transport-security exceptions; relay messages capped at 512 KB; Nostr signatures checked | Info.plist review, `SecurityRelayFuzzTests` |
| Privacy in the UI | Privacy screen blurs text, blocks copying and hides text from VoiceOver; app-switcher cover | `testPrivacyScreen` (UI test) |
| Logging | No message text, keys or nicknames are logged | Code review of all `Logger` calls |
| Binary | Position-independent, stack protection, automatic memory management, no unsafe C functions; test mode compiled out | Release build: `otool`, `nm`, `strings` |
| Secrets and personal data in the repo | None. Device ID and team ID live in the git-ignored `Makefile.local`; local hooks block personal identifiers | gitleaks: history and every folder clean (3 reviewed false positives in `.gitleaksignore`) |

## DSOVS maturity scorecard

Levels run from 0 (none) to 3 (fully automated and governed). "N/A" means the control doesn't apply to a serverless, single-developer mobile app.

| Control | Level now | Evidence | Next step |
|---|---|---|---|
| CODE-001 Secure development environment | 0 | — | Write a short checklist: FileVault, Xcode from the App Store, 2FA on Apple ID and GitHub |
| CODE-002 Hardcoded secrets detection | **1** | gitleaks via `make security`; `.gitleaksignore` reviewed | Add gitleaks to a CI workflow (level 2) |
| CODE-003 Manual secure code review | **1** | This review and its checklist (below) | Use the checklist on every pull request |
| CODE-004 SAST | **1** | semgrep via `make security` | Run in CI and fail the build on findings |
| CODE-005 SCA | **1** | osv-scanner via `make security`; advisory check; dependency now current (0.25.1) | Dependabot or osv-scanner in CI |
| CODE-006 Licence compliance | 1 (manual) | Only dependency is MIT | **Add a LICENSE to the repo**; run a licence scan in CI |
| CODE-007 IDE secure code analysis | 0 | — | Optional: semgrep IDE plugin |
| CODE-008 Container scanning | N/A | No containers | — |
| CODE-009 Secure dependency management | 0 (partly mitigated) | Exact version pin plus `Package.resolved` revision | Review each upgrade; keep a single dependency |
| DES-001 Architecture design review | **1** | `docs/domain.md`, `docs/design.md`, this report | Review new protocol features before building them |
| DES-002 Threat modelling | **1** | Threat model above | Update it with each protocol change |
| OPR-001 Environment hardening | N/A | No servers | — |
| OPR-002 Application hardening | **1** | Release binary checks | Script the binary checks into `make security` |
| OPR-003/004 Security logging | N/A by design | An offline, private app shouldn't phone home | Keep local-only diagnostics |
| OPR-005 Responsible disclosure | 0 | — | **Add `SECURITY.md`** and enable GitHub private vulnerability reporting |
| OPR-006 Certificate management | N/A | Relays' TLS; no own certificates | — |
| OPR-007 Attack surface management | N/A | No hosted assets | — |
| ORG-001 to ORG-004 Organisation | N/A (solo) | — | Revisit if the team grows |
| REL-001 Artifact signing | **1** | Apple code signing with your own team | Distribution signing for TestFlight |
| REL-002 Artifact management | 0 | — | Archive signed builds per release |
| REL-003 Secret management | **1** | Device keys in the Keychain; no build secrets; personal IDs git-ignored | — |
| REL-004 Secure configuration | **1** | Minimal entitlements, sandbox on Mac, no transport-security exceptions | Add a release checklist |
| REL-005 to REL-008 Release policy and compliance | 0 | — | A release checklist covering `make security` and the binary checks |
| REQ-001 to REQ-003 Requirements | 0 | — | Write abuse stories for new features (for example "a stranger floods envelopes") |
| REQ-004 Security issue tracking | 0 | Findings and their status live in this document | **Open GitHub issues for the remaining open findings (SEC-04, SEC-05, SEC-10, SEC-11)** |
| TEST-001 Security test management | **1** | Simulated mesh and in-memory stores keep tests separate from real data | — |
| TEST-002 DAST | **1** | On-demand DAST suites, real-device and real-Bluetooth tests | Run in CI (level 2) |
| TEST-003 IAST | 0 | — | Optional: Address Sanitizer and Thread Sanitizer runs of the test suite |
| TEST-004 Penetration testing | 0 (first ad-hoc test done) | This assessment | External review before a public App Store release |
| TEST-005 Security test coverage | **2** | Scope defined above; security regression tests run in every `make test` | Grow the DAST suite as findings are fixed |

**Quickest wins toward level 2:**
1. A GitHub Actions workflow that runs `make test` and `make security` on every push.
2. Issues for each finding.
3. A `SECURITY.md`.
4. A LICENSE file.

## Secure code review checklist

Used for this review. Apply it to future changes.

- [ ] Every collection filled from the network or Bluetooth has a size limit and an eviction rule.
- [ ] Every input parser rejects truncated, oversized and trailing data, and never crashes (no `!` on untrusted data).
- [ ] Signatures and MACs are checked before the content is acted on, and bound to the sender's identity.
- [ ] Replays are rejected: nonces, IDs and expiry, including across restarts.
- [ ] Nothing secret or personal is logged, put on the clipboard, or saved outside encrypted storage.
- [ ] New protocol fields are additive (TLV), and wire changes bump the protocol version.
- [ ] Each new feature gets a DAST test for its abuse case.
- [ ] No personal identifiers in code, bundle IDs, commits or docs (enforced by local hooks).

## Remediation plan

| Priority | Finding | Effort | Status |
|---|---|---|---|
| 1 | SEC-02 Cap receipts, apply the queue limit to all items | Small | Done |
| 2 | SEC-01 Cap the peer table | Small | Done |
| 3 | SEC-03 Per-sender and per-link rate limiting | Medium | Done |
| 4 | SEC-07 Save opened envelope and received message IDs | Small | Done |
| 5 | SEC-06 Upgrade swift-secp256k1 to 0.25.1 | Medium (API migration) | Done |
| 6 | SEC-08 Cap Bluetooth queues; SEC-09 local-only clipboard | Small each | Done |
| 6b | SEC-10 Debug-only test support | Small to medium | Accepted for now |
| 7 | SEC-11 PeerID conflict handling | Medium | Open (protocol v2) |
| 8 | SEC-04 / SEC-05 Identity rotation and envelope privacy | Large (protocol v2) | Open |

**New limits and their defaults** (in `MeshNode.Configuration`):

| Setting | Default | Why |
|---|---|---|
| `maxPeers` | 256 | People tracked at once |
| `newPeersPerLinkPerMinute` | 32 | New identities from one Bluetooth link |
| `publicMessagesPerSenderPerMinute` | 20 | A verified person posting in #nearby |
| `unverifiedMessagesPerLinkPerMinute` | 30 | Posts from senders we can't check, per link |
| `relayedDirectedPerSenderPerMinute` | 120 | Handshakes and private messages passed on for one sender |
| `maxPendingReceiptsPerPerson` / `maxIDsPerReceipt` | 2 / 50 | Receipts waiting for someone out of reach |

If real groups hit these, raise them. The DAST suite shows what each one protects against.

When a fix lands, its `withKnownIssue` in `SecurityDASTTests` reports an unexpected pass. Remove the wrapper, so the test becomes a regression test.
