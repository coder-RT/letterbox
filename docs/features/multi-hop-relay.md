# Multi-hop relay (the mesh)

**Status:** Shipped · Back to [all features](README.md)

## What it does
Messages hop from phone to phone, up to 7 times, so people out of each other's direct range can still talk if others stand between them. A group strung out along a trail acts as a chain.

## Why
Bluetooth reaches only tens of metres. Relaying turns a handful of phones into a network that covers a camp or a stretch of trail, which is what makes offline chat practical.

## How it works
Every inbound frame goes through one pipeline in `MeshNode.receive`: **decode → dedup → freshness → handle → relay**.
- **TTL 7:** each hop lowers it by one; at 1 the packet stops.
- **Dedup:** each packet has a random 8-byte ID; a phone handles and relays each ID once (it remembers 4,096 IDs for 10 minutes).
- **Freshness:** packets more than 10 minutes from the phone's clock are dropped, which stops old recordings being replayed.
- **Jitter:** relays wait a random 10–150 ms, so neighbours don't all transmit at once.
- **No echo:** a packet is never sent back out of the link it came in on. Packets for one person go only toward them when they're a direct neighbour.
- **Bluetooth:** every phone is both a peripheral (advertising HelloLetter's own service) and a central (scanning and connecting, up to 8 links, ignoring signals weaker than −92 dBm). Frames are split into chunks that fit the link's MTU and reassembled on the other side, with bounded send queues.

## Limits
- It's a flood: every phone carries everything. Fine for groups; very large crowds would want smarter routing ([gap analysis](../gap-analysis.md)).
- iOS slows Bluetooth in the background ([background](background-and-relaunch.md)).

## Tests
`MeshNodeTests`: lines, a 16-node grid, loops, the 7-hop limit, partitions; `WireTests` and `WireEdgeCaseTests`: chunking across MTUs, fuzzing.

## Code
- [MeshNode.receive, scheduleRelay, transmit](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshNode.swift)
- [Packet format](../../Packages/LetterboxKit/Sources/LetterboxWire/Packet.swift)
- [BLE chunking (LinkFramer)](../../Packages/LetterboxKit/Sources/LetterboxWire/LinkFramer.swift)
- [BLELinkLayer (CoreBluetooth)](../../Packages/LetterboxKit/Sources/LetterboxBLE/BLELinkLayer.swift)
