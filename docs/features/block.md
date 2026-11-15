# Block someone

**Status:** Shipped · Back to [all features](README.md)

## What it does
**Block** on a person's page (people icon → ⓘ) hides everything they send: earlier messages, new ones in #nearby and private chats, caught-up history and alerts. They aren't told. **Unblock** undoes it.

## Why
Rate limits stop floods, but not someone posting unpleasant things slowly. Blocking is the simplest control a person has, and App Review requires it for chat apps (guideline 1.2).

## How it works
- Blocked people are saved encrypted on the phone and survive restarts.
- Messages are matched by the sender's key fingerprint, so a blocked person can't get around it by changing nickname.
- Your phone still **relays** their packets for others: the mesh needs every phone, and hiding is your choice, not everyone's.

## Limits
- A sender whose announce your phone never heard has no confirmed key; those messages can be hidden one by one with [Report](report.md).

## Tests
`BlockingTests`, `testBlockingSomeoneHidesTheirMessages` (UI).

## Code
- [ChatStore.block, unblock](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
- [PersonView](../../Letterbox/Views/VerifyViews.swift)
