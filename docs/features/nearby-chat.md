# #nearby: group chat over Bluetooth

**Status:** Shipped · Back to [all features](README.md)

## What it does
#nearby is a public chat with everyone around you who runs HelloLetter. You type, and every phone in range (and in range of those, up to 7 hops) shows it. No internet, SIM card or account.

## Why
This is the core of HelloLetter's purpose, offline communication when there's no internet: a hiking group, a crowd with no signal, a hut in a valley. Everyone in the group sees the same conversation without exchanging numbers first.

## How it works
- Each phone **announces** itself every ~15 seconds (with ±20% jitter): its nickname and two public keys, signed with Ed25519. A peer that goes quiet for 60 seconds is forgotten.
- A message is a **signed packet** (`publicMessage`, up to 2,000 bytes of text) flooded over the mesh ([multi-hop relay](multi-hop-relay.md)).
- Receivers check the signature against the key the sender announced. If they haven't heard the sender's announce yet, the message still shows, with a **?** for "couldn't confirm who sent this".
- The composer says where the message goes: "Message everyone nearby".
- People in range are listed under the people icon, each marked as **in direct range** or **via others**.

## Limits
- Public by design: anyone nearby running HelloLetter can read it.
- Range between two phones is roughly 10–50 m in the open.
- Each verified sender may post 20 messages a minute ([abuse protection](abuse-protection.md)).

## Tests
`MeshNodeTests` (relay across hops, dedup, forged senders), `testNearbyChatGetsAReply` (UI).

## Code
- [MeshNode.sendPublic, handlePublicMessage](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshNode.swift)
- [Payloads (announce, public message)](../../Packages/LetterboxKit/Sources/LetterboxWire/Payloads.swift)
- [ChatScreen](../../Letterbox/Views/ChatScreen.swift)
