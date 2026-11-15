# Lock-screen alerts

**Status:** Shipped · Back to [all features](README.md)

## What it does
When HelloLetter isn't on screen, new #nearby and private messages raise an alert, one per conversation with a count ("3 new private messages"), cleared when you open that conversation. By default alerts show **no name and no text**. Turn on **Settings → Alerts → Show names and text in alerts** to see them; the privacy screen always hides them.

## Why
With the phone in your pocket on a trail, you'd otherwise never know a reply had arrived. But anyone can read a locked screen, so the safe default reveals nothing.

## How it works
- **Local notifications** created on the phone; there's no push server, so nothing leaves the device.
- Only live messages from other people in #nearby and private chats; never your own, caught-up history, location channels, duplicates or blocked people.
- Permission is asked the first time you send a message, when a reply makes sense, not at launch.
- The UI tells the store when HelloLetter comes on or goes off screen.

## Tests
`AlertTests` (7 tests: wording, hidden by default, opting in, privacy screen override, no alerts for own/history/duplicates, clearing, asking once), `NotificationTextTests`.

## Code
- [NotificationText](../../Packages/LetterboxKit/Sources/LetterboxApplication/NotificationText.swift)
- [SystemMessageNotifier](../../Packages/LetterboxKit/Sources/LetterboxDevice/SystemMessageNotifier.swift)
- [ChatStore.alertIfNeeded](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
