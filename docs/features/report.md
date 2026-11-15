# Report a message

**Status:** Shipped · Back to [all features](README.md)

## What it does
Touch and hold someone's message → **Report…**. The sender is **blocked at once** (or, if HelloLetter couldn't confirm who sent it, that message is hidden). If the build has a support address, you can also **email a report**; Mail sends it once there's signal.

## Why
App Review requires a way to report objectionable content in chat apps (guideline 1.2, which since 2026 explicitly covers anonymous chat). HelloLetter has no server, so the report has to work offline: the immediate part (blocking) happens on your phone.

## How it works
- The confirmation opens after the long-press menu has closed (opened during its closing animation, it could be dropped).
- The email contains the reported message **as received** (not masked by the [word filter](word-filter.md)), the sender's nickname and key, where and when it was sent, and the app version. Nothing about the reporter, apart from the email address Mail sends from.
- The support address comes from `SUPPORT_EMAIL` in `Makefile.local` at build time, so nothing personal is committed. Without it, Report blocks only.

## Tests
`ReportTextTests`, `StoreSafetyTests`, `testReportingSomeoneBlocksThem` (UI).

## Code
- [ReportText, SupportContact](../../Packages/LetterboxKit/Sources/LetterboxApplication/ReportText.swift)
- [ChatStore.report](../../Packages/LetterboxKit/Sources/LetterboxApplication/ChatStore.swift)
- [ChatScreen (confirmation)](../../Letterbox/Views/ChatScreen.swift)
- [BuildSettings](../../Letterbox/App/BuildSettings.swift)
