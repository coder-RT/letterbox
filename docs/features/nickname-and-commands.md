# Nickname and typed commands

**Status:** Shipped · Back to [all features](README.md)

## What it does
Set the name others see in **Settings → Nickname** (until then you're a random name like `anon4821`). Typed commands work in the composer, handy with gloves on:

| Command | Does |
|---|---|
| `/msg ana at the bridge` | Private message to Ana |
| `/who` | Lists who's in range |
| `/nick Ana` | Changes your nickname |
| `/clear` | Clears this conversation on your phone |
| `/help` | Shows the commands |

## Why
A recognisable name is how a group knows who's talking. Commands are faster than tapping through menus in the cold.

## How it works
Nicknames are cleaned (no line breaks or control characters, at most 24 characters) before they're announced; until you set one you're `anon` plus four digits. Commands are parsed in `ComposerInput`; anything else is sent as a message.

## Tests
`ChatStoreTests` (commands, nickname handling), `DomainTests` (nickname cleaning).

## Code
- [ComposerInput](../../Packages/LetterboxKit/Sources/LetterboxApplication/Command.swift)
- [Nickname](../../Packages/LetterboxKit/Sources/LetterboxDomain/Chat.swift)
