# Verifying someone (safety number and QR code)

**Status:** Shipped · Back to [all features](README.md)

## What it does
Meet someone in person and confirm their messages really come from them. Compare the **safety number** on both screens, or scan their **QR code**. They then get a **Verified** badge, and HelloLetter warns you if someone else nearby uses their name with a different key. Find it at people icon → ⓘ next to a name; your own code is in **Settings → Your safety code**.

## Why
Nicknames can be copied by anyone. Without verification, someone could pretend to be your friend and send you the wrong meeting point.

## How it works
- The safety number is 8 groups of 4 digits from a SHA-256 hash of both people's key fingerprints, sorted first, so it's the same on both phones.
- The QR code holds `letterbox:verify:1:<fingerprint>`; scanning uses the camera through VisionKit and checks the code belongs to this person, not someone else.
- Verified people are saved encrypted on the phone. **Impostor warning:** someone nearby using a verified person's name with another key is flagged.

## Tests
`CryptoEdgeCaseTests` and `WireVectorTests` for the number and code, `ChatStoreVerificationTests` (mark, clear, survives a restart, impostors), `testVerifyingSomeone` (UI). QR scanning needs a real camera.

## Code
- [SafetyNumber, VerifyCode](../../Packages/LetterboxKit/Sources/LetterboxCrypto/Verification.swift)
- [PersonView, QRScanner](../../Letterbox/Views/VerifyViews.swift)
