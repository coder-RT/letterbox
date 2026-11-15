# Send outside HelloLetter (AirDrop)

**Status:** Shipped · Back to [all features](README.md)

## What it does
**… → Send outside HelloLetter** sends a one-way message to someone who doesn't have the app, through the share sheet. **AirDrop** works with no internet to iPhones, iPads and Macs nearby; they tap Accept. Messages or Mail also work when there's signal. Touch and hold one of **your own** messages for **Send via AirDrop…**.

## Why
Bluetooth chat needs HelloLetter on both phones, and iPhones block unsolicited messages from strangers. AirDrop is the one offline way to reach someone without the app.

## How it works
- The sheet is pre-filled with your current draft; the box shows "Your message". An optional line adds how to get HelloLetter.
- The send button always reads "Send via AirDrop or another app" and is grey until there's text.
- Only your own messages can be shared, and only while visible: passing on other people's words is their call.
- No new permissions or networking: it's the system share sheet.

## Limits
- One-way: they can reply in HelloLetter only if they install it.
- Messages and Mail send it over the internet, outside HelloLetter's encryption; the sheet says so.

## Tests
`ShareTextTests`, `testSendOutsideLetterbox`, `testOwnMessageCanBeSentViaAirDropOnlyWhileVisible` (UI), and a real-device AirDrop test (`DeviceTests`).

## Code
- [OutsideMessageSheet](../../Letterbox/Views/OutsideMessageSheet.swift)
- [ShareText](../../Packages/LetterboxKit/Sources/LetterboxApplication/ShareText.swift)
