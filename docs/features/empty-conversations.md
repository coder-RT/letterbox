# Conversations that explain themselves

**Status:** Shipped · Back to [all features](README.md)

## What it does
An empty conversation says what it is and what to do:
- **#nearby:** needs no internet or signal; who's in range; that anyone arriving in the next 12 hours can catch up on what you send; and, when nobody's around, **Invite someone**.
- **Private chat:** only the two of you can read it; HelloLetter keeps trying for 3 days if they're out of range.
- **Location channel:** public chat over the internet; relays see your IP address.

## Why
From the usability review based on *Don't Make Me Think*: every screen should answer "what is this, and what can I do here?". A first-time user alone on a trail otherwise sees a blank screen and assumes it's broken.

## Tests
`testEmptyNearbyExplainsItselfWhenAlone` (UI).

## Code
- [ChatEmptyState in ChatScreen](../../Letterbox/Views/ChatScreen.swift)
