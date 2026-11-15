# Envelopes: messages carried by other people

**Status:** Shipped (needs a three-phone field test) · Back to [all features](README.md)

## What it does
If a private message can't reach someone, HelloLetter seals it in an **envelope** and hands copies to people you pass. When one of them meets your friend, it's delivered, and the receipt comes back the same way. The people carrying it can't read it. An envelope icon with a number next to your message shows how many are carrying it; **… → Envelopes** shows yours on their way and how many you carry for others.

## Why
A group that splits up can still swap messages: anyone walking between them carries the news across. That's delivery with no radio path at all, the most "offline" thing HelloLetter does.

## How it works
- After **10 seconds** undelivered, and only if you've met the recipient before (so you know their key), the message is sealed to them with **Noise X**, one-way encryption to their static key.
- Copies go to up to **8** phones in direct range, including ones that walk past later (packet type `courier`, TTL 1, so couriers never pass them to other couriers).
- An envelope shows only a random ID, a **recipient tag** and an expiry, all bound into the seal. The recipient recognises its tag and opens it; nobody else can.
- Couriers carry at most **256** envelopes for at most **3 days**, hand them over when they meet the recipient (directly, or retried every 30 seconds through relays), and remember the last 1,000 opened envelope IDs so a replay isn't shown twice.
- One depositor can fill at most 32 slots, at 30 a minute, so a hostile phone can't push out everyone else's mail (SEC-15).

## Limits
- **No forward secrecy:** someone who later steals the recipient's key could open captured envelopes.
- The recipient tag is derived from the recipient's public fingerprint, so a courier who has seen their announce can tell who an envelope is for (SEC-05, planned for protocol v2).

## Tests
`NoiseXSealTests`, `MeshNodeTests` (carried between people who never meet, copy limits, carry time, forged or extended envelopes), `SecurityDASTTests` (floods, replays), `testEnvelopeCarriedByAPassingHiker` (UI).

## Code
- [Courier, CarriedEnvelopes](../../Packages/LetterboxKit/Sources/LetterboxMesh/Courier.swift)
- [Noise X seal](../../Packages/LetterboxKit/Sources/LetterboxCrypto/NoiseXSeal.swift)
- [EnvelopesView](../../Letterbox/Views/EnvelopesView.swift)
