# Private messages (end-to-end encrypted)

**Status:** Shipped · Back to [all features](README.md)

## What it does
One-to-one messages only you and the other person can read. Phones that relay them see only ciphertext.

## Why
Public chat isn't enough: people need to say things just to one person ("I'm turning back, my knee hurts") without everyone nearby reading it, and without trusting the phones in between.

## How it works
- The first message to someone starts a **Noise XX** handshake (`Noise_XX_25519_ChaChaPoly_SHA256`, prologue `letterbox/mesh/1`): three messages carried as directed packets through the mesh.
- Each side checks that the key proven in the handshake is the key the other person **announced**. A mismatch ends the session.
- Messages then travel as `encrypted` packets with an **explicit nonce** and a **replay window**, so they survive loss and reordering across different mesh paths, and a replayed packet is ignored.
- Handshakes time out after 10 seconds and are retried. Up to 16 ciphertexts that arrive before the session is ready are kept.
- If the person isn't around, the message waits in the [offline queue](offline-queue.md); if they still can't be reached, it can travel in an [envelope](envelopes.md).
- Open a private chat from the people icon → ⓘ → **Send a private message**, or type `/msg name text`.

## Limits
- Forward secrecy within a session; envelopes don't have it.
- Your nickname and public keys are visible to anyone nearby ([security assessment](../security-assessment.md), SEC-04).

## Tests
`NoiseTests` (byte for byte against the published Noise vectors), `CryptoEdgeCaseTests` (replay window, tampering), `MeshNodeTests` (DMs through relays that never see plaintext, simultaneous handshakes), `testPrivateMessageIsDeliveredAndAnswered` (UI).

## Code
- [Noise XX](../../Packages/LetterboxKit/Sources/LetterboxCrypto/Noise.swift)
- [Sessions in MeshNode](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshNode.swift)
- [Identity keys](../../Packages/LetterboxKit/Sources/LetterboxCrypto/IdentityKeys.swift)
