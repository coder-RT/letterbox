# Accessibility

**Status:** Shipped · Back to [all features](README.md)

## What it does
HelloLetter works with VoiceOver, Dynamic Type up to the largest accessibility sizes, and high-contrast colours in light and dark mode.

## Why
It's the right thing to do, and the people who most need offline communication include people with disabilities. Clear, legible screens also help everyone reading a phone outdoors, cold and tired.

## How it works
- Apple's **accessibility audit** runs on every screen in the UI tests (and on Settings scrolled to the end), with a screenshot kept when it fails.
- Colours are chosen for contrast: ink blue `#1D4ED8` (≈6.7:1 on white), secondary text ≈9.5:1, an accessible red for destructive actions.
- Rows wrap and grow at the largest sizes; toolbar buttons support the Large Content Viewer.
- VoiceOver labels describe state in words ("Delivered to their phone", "Hidden message").

## Tests
`testAccessibilityAuditOnEveryScreen`, `testScreenshotsLargestText`, `testScreenshotsDark` (UI). Details and documented exclusions: [design.md](../design.md).

## Code
- [Theme (colours, RowLabel)](../../Letterbox/Views/Theme.swift)
- [Audit test](../../LetterboxUITests/LetterboxUITests.swift)
