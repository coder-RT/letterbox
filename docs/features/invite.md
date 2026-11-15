# Invite someone

**Status:** Shipped · Back to [all features](README.md)

## What it does
Shares a short note on how to get HelloLetter ("I'm using HelloLetter to chat with no internet or signal…") through AirDrop, Messages or any app. It's offered in **Send outside HelloLetter**, on the empty Nearby list, and on the empty #nearby screen when nobody's around.

## Why
HelloLetter only works if the people you'll be with have it, and they need to install it **before** the trip, while they still have internet. The invite appears exactly where you notice nobody else has it.

## How it works
`ShareText.invite` builds the note with a link to the project, adding your nickname unless it's a random "anon" one. It's a plain `ShareLink`.

## Tests
`ShareTextTests` (no personal identifiers in shared text), `testInviteOpensTheShareSheet`, `testEmptyNearbyExplainsItselfWhenAlone` (UI).

## Code
- [ShareText](../../Packages/LetterboxKit/Sources/LetterboxApplication/ShareText.swift)
- [ChatScreen (empty state)](../../Letterbox/Views/ChatScreen.swift)
