# Location channels

**Status:** Debug builds only (left out of the App Store build) · Back to [all features](README.md)

## What it does
Public chat rooms for your area, carried over the internet: pick a size from **block** to **region** in the channel list (tap the channel name at the top).

## Why
When there is internet, it's useful to reach people in the same town or region who aren't within Bluetooth range. It's left out of the App Store build because HelloLetter is for when there's no internet, and internet chat with strangers widens what App Review expects to be moderated.

## How it works
- Your coarse location becomes a **geohash** at the chosen precision (region 2, province 4, city 5, neighbourhood 6, block 7 characters).
- HelloLetter derives a **separate secp256k1 key for each geohash** from a device seed, so posts in different areas can't be linked to each other or to your mesh identity.
- Messages are Nostr events of HelloLetter's own kind **23471**, signed (Schnorr) and sent through four public relays. Relays forward them without storing them. Every event's signature and area are checked on arrival.
- Controlled by `LETTERBOX_LOCATION_CHANNELS` in `project.yml`: on in Debug, off in Release.

## Limits
- Relays see your IP address; there's no Tor (SEC-13).
- Location is used only when you join, and your exact position is never sent.

## Tests
`NostrTests`, `NostrLocationChannelTests`, `SecurityRelayFuzzTests` (hostile relay traffic), `testStoreBuildLeavesOutLocationChannels` (UI).

## Code
- [NostrLocationChannel](../../Packages/LetterboxKit/Sources/LetterboxNostr/NostrLocationChannel.swift)
- [RelayPool](../../Packages/LetterboxKit/Sources/LetterboxNostr/RelayPool.swift)
- [Geohash](../../Packages/LetterboxKit/Sources/LetterboxDomain/Geohash.swift)
- [BuildSettings](../../Letterbox/App/BuildSettings.swift)
