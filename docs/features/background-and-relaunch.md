# Running in the background, and relaunch by iOS

**Status:** Shipped, needs a field test · Back to [all features](README.md)

## What it does
HelloLetter keeps relaying and receiving with the phone locked or another app open. If iOS closes it to free memory, iOS relaunches it in the background when a HelloLetter phone comes into range, so you stay reachable.

## Why
A phone in a pocket is the normal state on a hike. If HelloLetter only worked on screen, the mesh would fall apart whenever people put their phones away.

## How it works
- The app declares the `bluetooth-central` and `bluetooth-peripheral` background modes.
- Both Bluetooth managers use **state restoration** identifiers. On relaunch, HelloLetter takes back the connections, the published service and its subscribers that iOS kept open, rather than duplicating them.
- The mesh starts when the **app launches**, not from a view: a background relaunch creates no window, so a view-based start would never run.

## Limits
- iOS slows Bluetooth in the background, so messages take longer.
- If you swipe HelloLetter away yourself, iOS treats that as quitting: it stays closed until you open it.
- Can't be tested in the simulator; the steps for a real-device check are in the [release checklist](../gap-analysis.md#release-checklist).

## Code
- [BLELinkLayer (willRestoreState)](../../Packages/LetterboxKit/Sources/LetterboxBLE/BLELinkLayer.swift)
- [LetterboxApp (start at launch)](../../Letterbox/App/LetterboxApp.swift)
