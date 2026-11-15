# Offensive-word filter

**Status:** Shipped · Back to [all features](README.md)

## What it does
Offensive words in other people's messages and nicknames are masked on your phone, keeping the first letter ("f***"). It's **on by default**; turn it off in **Settings → Help and safety → Hide offensive words**.

## Why
#nearby is chat with strangers. App Review asks chat apps to filter objectionable material (guideline 1.2), and most people would rather not see slurs at all.

## How it works
- Matching is **per word**, after folding case and accents, undoing common letter swaps (`@`→a, `0`→o, `!`→i inside a word) and collapsing stretched letters ("fuuuck").
- A short, conservative list of words that are offensive in almost any context, plus a few roots matched at the start of a word ("fucking").
- Ordinary words that merely contain a bad word are left alone: Scunthorpe, assessment, class, shiitake, niggle, Fukushima, cocktail, Dickens.
- Masking happens when messages are shown; the original is kept, so a [report](report.md) carries the real words.

## Limits
- English only, and any word list misses things. Blocking and reporting are the backstop.

## Tests
`ContentFilterTests` (masking, disguised spellings, ordinary words left alone), `StoreSafetyTests`.

## Code
- [ContentFilter](../../Packages/LetterboxKit/Sources/LetterboxApplication/ContentFilter.swift)
- [HelpView (switch)](../../Letterbox/Views/HelpView.swift)
