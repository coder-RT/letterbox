# Mac app

**Status:** Shipped · Back to [all features](README.md)

## What it does
The same HelloLetter on a Mac (macOS 15 or later): #nearby, private messages, envelopes and everything else, talking to iPhones over Bluetooth.

## Why
A laptop at a base camp or hut can be a relay and a bigger screen, and a Mac is the easiest second device for testing the mesh.

## How it works
- Built from the same sources as the iPhone app (`LetterboxMac` scheme); the composition root wires the same adapters.
- The window opens at 520×760 with a unified toolbar.
- `make mac-zip` builds a shareable copy: Release (no location channels), universal (Apple Silicon and Intel), ad-hoc signed with no account, in `build/dist/`. Recipients drag it to Applications, open it, then allow it once in **System Settings → Privacy & Security → Open Anyway**.

## Limits
- No mobile-network row and no app-switcher cover.
- Not notarized without a paid Apple account.

## Code
- [LetterboxApp](../../Letterbox/App/LetterboxApp.swift)
- [project.yml (LetterboxMac target)](../../project.yml)
