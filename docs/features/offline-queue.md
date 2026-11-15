# Offline queue (messages that wait)

**Status:** Shipped · Back to [all features](README.md)

## What it does
A private message to someone out of reach waits on your phone and goes out as soon as they come within reach, for up to **3 days**. It survives the app closing or the phone restarting. If it never gets through, it's marked "Not delivered" and you can **Send again**.

## Why
On a multi-day trek, people drift in and out of range. A message written at breakfast should still arrive when your friend catches up at lunch, without you resending it.

## How it works
- Each recipient has an outbox. Sent but unacknowledged messages are resent if the session is replaced.
- Limits: 3 days per message, 500 messages in total (the oldest fail first).
- The queue is saved in an **encrypted file** (ChaCha20-Poly1305, key in the Keychain, readable after first unlock) and restored at launch, showing as waiting again.
- After 10 seconds without delivery, a sealed copy can also go with passing hikers ([envelopes](envelopes.md)).
- **Send again** (touch and hold a failed message) removes it and sends the same text as a new message with a fresh 3 days.

## Limits
- Only your own undelivered messages are saved; chats themselves live in memory.

## Tests
`MeshNodeTests` (queue, expiry, survives restarts), `SendAgainTests`, `PersistenceTests` (encrypted file store).

## Code
- [Outbox in MeshNode](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshNode.swift)
- [EncryptedFileStore](../../Packages/LetterboxKit/Sources/LetterboxPersistence/EncryptedFileStore.swift)
- [ChatStore.sendAgain](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
