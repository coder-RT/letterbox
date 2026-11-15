# Help and safety screen

**Status:** Shipped · Back to [all features](README.md)

## What it does
**Settings → Help and safety** gathers the safety controls and contact details: the **Hide offensive words** switch, how to block or report, a note that nobody at HelloLetter sees your messages, and links to email the team (when a support address is set), **Questions and answers**, the **Privacy policy** and the website.

## Why
App Review asks chat apps for published contact details and a privacy policy reachable inside the app (guidelines 1.2 and 5.1.1). For users, it's one obvious place to look when something goes wrong.

## How it works
- The support address is set per build from `SUPPORT_EMAIL` (never committed).
- The policy and Q&A are [`privacy-policy.md`](../privacy-policy.md) and [`support.md`](../support.md), published with GitHub Pages at `coder-rt.github.io/letterbox`.

## Tests
Covered by the accessibility audit (`testAccessibilityAuditOnEveryScreen`).

## Code
- [HelpView](../../Letterbox/Views/HelpView.swift)
- [SupportContact](../../Packages/LetterboxKit/Sources/LetterboxApplication/ReportText.swift)
