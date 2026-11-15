# Erase everything

**Status:** Shipped · Back to [all features](README.md)

## What it does
**Settings → Erase everything** (at the bottom, with a confirmation) deletes everything HelloLetter keeps on the phone: your identity keys, undelivered messages, envelopes you carry, people you verified or blocked, settings and alerts. The chat is replaced by a screen saying it's erased; next launch starts as a new person. Separately, a **fresh install** clears identity keys that iOS kept in the Keychain after the app was deleted.

## Why
For a phone you're about to lose, sell or hand over. And someone who deletes an app expects their identity gone; iOS Keychain items otherwise survive uninstalling.

## How it works
- The mesh stops first, so nothing is saved again after the wipe; then the Keychain items, the encrypted state files and the app's settings are deleted.
- Fresh-install check: if there are no settings yet (a real fresh install), leftover secrets are deleted before keys are loaded; an update keeps your identity.
- No hidden gesture: an accidental wipe in the field would lose undelivered messages. No decoy or duress mode, which is a product and legal decision ([gap analysis](../gap-analysis.md)).

## Tests
`EraseTests`, `LocalDataWipeTests`, `testEraseEverythingAsksFirstThenStops` (UI).

## Code
- [ChatStore.eraseEverything](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
- [DeviceDataEraser, FreshInstall](../../Packages/LetterboxKit/Sources/LetterboxPersistence/LocalDataWipe.swift)
