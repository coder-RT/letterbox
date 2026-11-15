# Abuse protection (limits on what one phone can do)

**Status:** Shipped · Back to [all features](README.md)

## What it does
Nothing visible: these limits stop one hostile phone in range from flooding the mesh, filling memory or pushing out other people's messages.

## Why
Anyone can install HelloLetter and send anything over Bluetooth. Without limits, a single phone could make the mesh useless for everyone around it, exactly when people depend on it.

## How it works
Defaults in `MeshNode.Configuration`, each covered by a security test:

| Limit | Default | Protects against |
|---|---|---|
| People tracked | 256; 32 new identities per link per minute | Peer-table floods (SEC-01) |
| Public messages | 20 per verified sender per minute; 30 per link from senders that can't be checked | Spam floods (SEC-03) |
| Relayed private traffic | 120 per sender per minute | Flooding through you (SEC-03) |
| Receipts waiting | 2 per person, 50 IDs each | Receipt amplification (SEC-02) |
| Bluetooth send queues | 1,024 chunks per link, 4,096 for notifications | Memory growth (SEC-08) |
| Envelopes carried | 256; 30 deposits per link per minute; 32 per depositor | Flushing others' mail (SEC-15) |
| Catch-up | 100 messages per answer; once a minute per link | History floods (SEC-16) |

Limits are checked **after** signatures, so forgeries can't use up a real person's allowance, and rejected messages aren't relayed.

## Tests
`SecurityDASTTests` (11 attack tests on a running node), `PublicCatchUpTests`, `SecurityRelayFuzzTests`; see the [security assessment](../security-assessment.md).

## Code
- [MeshNode.Configuration](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshNode.swift)
- [RateLimiter](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshSupport.swift)
