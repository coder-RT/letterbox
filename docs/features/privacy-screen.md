# Privacy screen

**Status:** Shipped · Back to [all features](README.md)

## What it does
From the **…** menu → **Privacy screen**, every message is blurred so people around you can't read over your shoulder. Tap a message to peek at it for 5 seconds. A banner shows it's on. On iPhone the app also covers itself in the app switcher.

## Why
In a crowded hut or shelter, screens are easy to read from the next bunk. Hiding text should be one tap, and remembered.

## How it works
- The choice is saved in settings and applied by the message list (blur plus a peek timer).
- VoiceOver reads "Hidden message" rather than the text.
- Copy and **Send via AirDrop** are hidden while a message is blurred.
- [Lock-screen alerts](lock-screen-alerts.md) never show names or text while it's on.

## Limits
- The Mac has no app-switcher cover.

## Tests
`ChatStoreTests` (privacy mode), `testPrivacyScreen` (UI, including what VoiceOver reads).

## Code
- [ChatScreen (banner, cover)](../../Letterbox/Views/ChatScreen.swift)
- [MessageList (blur, peek)](../../Letterbox/Views/MessageList.swift)
