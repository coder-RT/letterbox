# Bluetooth and internet switches, and automatic routing

**Status:** Shipped · Back to [all features](README.md)

## What it does
In the Connections panel, **Use Bluetooth** and **Use the internet** decide what HelloLetter may use. HelloLetter then picks the best allowed way for each message on its own, and tells you when it has to wait and why.

## Why
Sometimes you want HelloLetter off the radio (to save battery) or off the internet (so relays never see your IP address). And nobody should have to choose a transport per message.

## How it works
`RoutePlanner` decides for each private message:
1. Bluetooth allowed and the person is in reach → **mesh**.
2. Otherwise, Bluetooth allowed and you've met them → **envelope** with passing hikers, while it keeps waiting.
3. Otherwise → **queue**, with a reason shown in the chat (for example "Bluetooth is off in HelloLetter. It will send when you turn it back on in Connections.").

Turning Bluetooth off stops the mesh entirely; turning it back on restarts it, and the other phones see you again. Turning the internet off leaves location channels. An internet route for private messages is modelled for a later phase.

## Limits
- In the App Store build there's no internet use at all, so the internet switch is hidden ([location channels](location-channels.md)).

## Tests
`DomainTests` (every route combination), `StoreMeshIntegrationTests` (Bluetooth off then on, both ways), `testConnectionsPanelAndBluetoothOffThenOn` (UI).

## Code
- [RoutePlanner, TransportPermissions](../../Packages/LetterboxKit/Sources/LetterboxDomain/Connectivity.swift)
- [ChatStore.setBluetoothAllowed](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
