# Connections panel

**Status:** Shipped · Back to [all features](README.md)

## What it does
Tap the icons at the top left to see what works right now and what each thing lets you do: **Bluetooth** (and how many people are nearby), **Internet**, **Wi-Fi**, **Mobile network** (signal type, whether texts can go), **Satellite**, **Location**, **Relays** and **Envelopes**. Each row says Working, Off, Not allowed, and so on, in plain words.

## Why
Offline, the first question is "what can I use?". One panel answers it, including things outside HelloLetter (like SMS on one bar of signal) that might get a message through.

## How it works
- Readings come from the system: `NWPathMonitor` for internet and Wi-Fi, CoreTelephony for the mobile radio, CoreLocation for the permission, and the Bluetooth radio state.
- All wording lives in `ConnectionReport`, so every case is unit-tested.
- **Satellite** can't be detected by apps; the row says so and suggests Messages or Emergency SOS, rather than guessing.
- In builds without [location channels](location-channels.md), the Location and Relays rows are hidden and Internet says nothing in HelloLetter needs it.

## Tests
`ChatStoreTests` (every status in `ConnectionReport`), `ConnectivityMappingTests`, `testConnectionsPanelAndBluetoothOffThenOn`, `testOfflineDeviceAndInternetSwitch` (UI).

## Code
- [ConnectionReport](../../Packages/LetterboxKit/Sources/LetterboxApplication/ConnectionReport.swift)
- [SystemConnectivityMonitor](../../Packages/LetterboxKit/Sources/LetterboxDevice/SystemConnectivityMonitor.swift)
- [ConnectionsSheet](../../Letterbox/Views/ConnectionsSheet.swift)
