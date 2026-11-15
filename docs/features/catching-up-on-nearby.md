# Catching up on #nearby

**Status:** Shipped · Back to [all features](README.md)

## What it does
If you were out of range, had the app closed, or arrived late, HelloLetter fetches the **#nearby messages from the last 12 hours** that you missed, from the first person you meet. They appear in the order they were written, with names checked. Because every phone passes on what it caught up on, someone walking between two groups carries the conversation across.

## Why
Private messages already wait and travel by envelope, but a public "Meet at the hut at 5" sent while you were 2 km away was lost for good. On a trail, those are often the messages that matter most.

## How it works
- When a phone gets a **new direct neighbour**, it sends a link-local `syncRequest` (TTL 1, never relayed) listing the IDs of the recent #nearby messages it already holds (up to 300).
- The neighbour answers with what's missing (at most 100), each as a `syncResponse`: the original message exactly as its author signed it, plus the **author's signed announce**, so both signatures can be checked as if the message had arrived live.
- Answers are accepted only on a link we asked, within 30 seconds; nothing older than 12 hours or from the future; a message can't claim the ID of a live person with a different key. Each link is asked or answered at most once a minute.
- Messages are kept **in memory only** (at most 300). Only messages whose signature was checked are passed on. Caught-up messages never raise an alert.

## Limits
- Someone who saw a public message can show it to someone who missed it. That's the point, and the message was public.

## Tests
`PublicCatchUpTests` (latecomer, walker between groups, restart, nothing twice, bounds, unsolicited/forged/stale/excessive history, ID theft, never relayed), `caughtUpMessagesAreSlottedInByWhenTheyWereSent`, `testCatchingUpOnNearbyAfterArriving` (UI). Security review: SEC-16.

## Code
- [Catch-up in MeshNode (requestSync, handleSyncRequest, handleSyncResponse)](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshNode.swift)
- [PublicArchive](../../Packages/LetterboxKit/Sources/LetterboxMesh/MeshSupport.swift)
- [Sync payloads](../../Packages/LetterboxKit/Sources/LetterboxWire/SyncPayloads.swift)
