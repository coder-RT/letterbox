# Pager theme

**Status:** Shipped · Back to [all features](README.md)

![The HelloLetter pager icon](../assets/app-icon.png)

## What it does
An optional look inspired by 90s pagers: an LCD-green screen, a top status line with dot-matrix lettering and a seven-segment counter, date and clock, monospaced messages, and inverted "highlighted line" bubbles for your own messages. Choose it in **Settings → Appearance → Pager**; **Classic** stays the default. A dark version follows Dark Mode (green on near-black, like a backlit LCD at night).

## Why
A pager is the classic way a short message reached you without a phone call or the internet — exactly what HelloLetter does. The theme makes that idea visible and gives the app a personality, while Classic remains for anyone who prefers the standard iOS look.

## How it works
- **Typography**, as on real pagers, but only where it's decoration:
  - The top strip uses **DSEG7 Classic** (seven-segment) for the people count, date and 24-hour clock (seven segments can't draw "AM/PM"), and **DotGothic16** (dot-matrix) for the brand, like the maker's name on a pager.
  - Everything people read (**messages, names and timestamps**) uses the **system monospaced font**: it keeps the LCD feel, scales with Dynamic Type and keeps full contrast.
  - Why the split: LCD glyphs are dots and thin segments. Apple's accessibility audit found that they don't contrast or scale like text, which matches how they read on a real pager. So the strip is decorative and hidden from VoiceOver; its information is already in the title (channel), the people button (who's in range) and the iPhone's clock.
  - Both fonts are under the SIL Open Font License; the licences ship with the app in `Letterbox/Resources/Fonts/`.
- **Colours** are chosen for contrast: every text colour is at least 5.8:1 on its background in light and dark mode (table in [design.md](../design.md#pager-theme)). "Not delivered" uses a dark red that stays readable on green.
- The accessibility audit runs on the Pager chat screen too.
- The theme is a setting only (`AppTheme`, saved with the other settings); nothing about messaging changes.

## Limits
- Applies to the chat screen; sheets (Settings, Connections, …) keep the standard look.

## Tests
`AppearanceTests` (default, saved, unknown value), `testPagerTheme` (UI: switching, messages readable, back to Classic), the accessibility audit on the Pager chat, and Pager screenshots in light and dark.

## Code
- [Pager.swift (palette, fonts, status line)](../../Letterbox/Views/Pager.swift)
- [AppTheme](../../Packages/LetterboxKit/Sources/LetterboxApplication/AppTheme.swift)
- [MessageList (bubbles, timestamps)](../../Letterbox/Views/MessageList.swift)
