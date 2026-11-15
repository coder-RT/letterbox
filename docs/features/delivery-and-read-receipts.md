# Delivery and read receipts

**Status:** Shipped · Back to [all features](README.md)

## What it does
Ticks next to your private messages show how far each one got:

| Mark | Meaning |
|---|---|
| Clock | Waiting for the person to come in reach |
| Envelope with a number | That many people are carrying it to them ([envelopes](envelopes.md)) |
| One tick | Sent |
| Circled tick | On their phone |
| Filled tick | Read |
| Red mark, "Not delivered. Hold to send again" | HelloLetter gave up after 3 days |

Touch and hold a message to see its status in words.

## Why
Offline, you can't assume a message arrived. Knowing whether it reached the other phone tells you whether to wait, walk, or try another way.

## How it works
- The receiver sends an encrypted **delivered** receipt as soon as it decrypts the message, and a **read** receipt when the conversation is open.
- Receipts travel like private messages: over the mesh, or by envelope when the sender is out of reach.
- A message's state only moves forward: a late "sent" never overwrites "read".
- Receipts waiting for someone are merged (at most 2 pending per person, 50 message IDs each), so they can't pile up ([abuse protection](abuse-protection.md)).

## Tests
`ChatStoreTests` (state ordering, early receipts), `MeshNodeTests`, `testPrivateMessageIsDeliveredAndAnswered` (UI).

## Code
- [DeliveryState](../../Packages/LetterboxKit/Sources/LetterboxDomain/Chat.swift)
- [ChatStore.updateDelivery](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
- [DeliveryIcon](../../Letterbox/Views/MessageList.swift)
