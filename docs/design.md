# Letterbox design and accessibility

Letterbox is for people who are often outdoors, tired, wearing gloves, in bright sun or at night, and with no signal. The design choices follow from that.

## Principles

1. **Offline first, and say so.** The app always shows what works right now (the Connections chip) and explains in plain words why something can't be sent.
2. **Status is never colour alone.** Every status has an icon and a word as well as a colour (Working, Off, Off in Letterbox, Not allowed).
3. **Plain words, no jargon.** Use "Envelope", "Nearby" and "Safety number", not "courier packet", "mesh" or "fingerprint hash".
4. **Nothing hidden that matters, nothing shown that doesn't.** Codes live on the person's Verify screen, not in every list.
5. **Readable at every size.** All text uses Dynamic Type styles and wraps. Layouts switch to stacked rows at accessibility sizes.

## Screens: what changed and why

| Screen | Problem found | Change |
|---|---|---|
| Chat | Connections button missing: it shared a toolbar slot with Settings, and iOS 26 showed only one | Leading: connection chip. Trailing: people count, then a `…` menu (Privacy screen, Envelopes, Connections, Settings) |
| Chat | People button showed no count in the glass toolbar | Custom label: `person.2` plus the number, with a spoken label "1 person nearby" |
| Chat | The eye icon for blurring read as "seen/read" | **Privacy screen** in the menu with `hand.raised`, plus a "Messages hidden · Show" banner while it's on |
| Chat | No way to see a message's status in words | Long-press "Info": status in words with the time, and Copy (only while visible) |
| Chat | Own bubbles in dark mode put white text on a light blue (about 2.4:1) | A separate `OwnBubble` colour, at least 5:1 with white |
| Chat | Timestamps too faint and small | Medium weight in the readable secondary colour |
| Nearby | Names and codes drawn in light teal (the list button tint) | Fixed `Color.primary` and readable secondary colours |
| Nearby | Raw fingerprints up front, hard to compare and read aloud | Removed from lists. A ⓘ button opens the person's Verify screen. Rows show the reach as text ("In direct range") and a Verified badge |
| Person (new) | — | Safety number as 8 groups of 4 digits (2 columns at large sizes), QR scan, "Numbers match: mark as verified" |
| Settings | Raw fingerprint; greyed-out Save button | "Your safety code" (QR). Save appears only when there's a change |
| Connections | Badges and icons in system green and orange, too faint on white | Darker status colours (below) |
| All lists | First section header faded under the toolbar's scroll edge; grey headers and footers too faint | Top content margin; headers in primary colour; footers in readable secondary |
| All lists | `Label` in list rows didn't wrap or grow at the largest sizes | `RowLabel`: icon plus wrapping text |

## Icons

All icons are **SF Symbols**. They come with Xcode, match the system controls, scale with Dynamic Type and weight, mirror for right-to-left languages, and carry labels for VoiceOver. Nothing is downloaded.

| Use | Symbol | Why |
|---|---|---|
| Privacy screen | `hand.raised` | Apple's own privacy glyph; reads as "stop, private", unlike an eye (which reads as "seen") |
| Envelope (carried message) | `envelope` | The app's core metaphor |
| Carried by hikers | `figure.walk` | A person carrying it |
| Verified | `checkmark.seal.fill` | The common "verified" mark |
| Verify, scan | `qrcode.viewfinder`, `qrcode` | Says "scan a code" |
| Bluetooth chat | `antenna.radiowaves.left.and.right` | Radio, without implying the internet |
| Internet | `globe` | |
| Wi-Fi, Mobile | `wifi`, `cellularbars` | Match the status bar |
| Satellite | `dot.radiowaves.up.forward` | Signal going up |
| In direct range, via others | `dot.radiowaves.left.and.right`, `point.3.connected.trianglepath.dotted` | Direct versus hopping |
| More | `ellipsis.circle` | Standard overflow menu |
| Send outside Letterbox | `square.and.arrow.up` | The system's share symbol: it opens the share sheet, with AirDrop first |
| Invite someone | `person.badge.plus` | Adding a person |
| Alerts setting | `bell.badge` | The system's notification symbol |
| Erase everything | `trash` | Deleting, shown in red with a confirmation |
| Block, unblock | `nosign` | "Not allowed"; `hand.raised` already means the privacy screen |
| Report | `exclamationmark.bubble` | A problem with a message |
| Help and safety | `lifepreserver` | Help; distinct from the privacy and block symbols |
| Hide offensive words | `eye.slash` | Hidden from view |

### Licensing

- **SF Symbols:** free to use in apps on Apple platforms under the Xcode and SF Symbols licence. They **may not be used in app icons, logos or trademarks**, so the app icon must be original artwork.
- **Lucide** (lucide.dev) is ISC-licensed. It can be bundled and redistributed in an app if the licence notice is included; some icons come from Feather (MIT). It's a fine choice for the website or docs. In the app it would look foreign next to system controls, wouldn't scale with Dynamic Type for free, and adds assets to maintain. **Decision: not used in the app.**

## Colour

| Token | Light | Dark | Increase Contrast | Use |
|---|---|---|---|---|
| Accent (ink blue) | `#1D4ED8` (≈6.7:1 on white) | `#7AA2F7` (≈8:1 on black) | `#1E3A8A` / `#A5C0FF` | Buttons, links, icons |
| Own bubble | `#1D4ED8` | `#3B63D9` (white text ≈5.3:1) | `#1E3A8A` / `#1E40AF` | Your messages |
| Secondary text | `#45454A` (≈9.5:1) | `#ADADB2` (≈9:1) | — | Captions, timestamps, footers |
| Good | `#1A7F37` (≈5:1) | `#4CD964` | — | Working, Verified |
| Warning | `#B45309` (≈5:1) | `#FFB340` | — | Off in Letterbox, impostor warning |
| Bad | `#C0262D` (≈6:1) | `#FF6961` | — | Not allowed, Not delivered |
| Sender names | Hue per person, brightness 0.42 | Brightness 0.92 | — | Tell people apart |

**Why ink blue?** It's the colour of letters and airmail, which fits the name. It passes WCAG AA for text in both modes, and stays distinct from the status colours. Postbox red was rejected because red already means errors and failed delivery.

**Why custom status colours?** The system green on white is about 2.2:1, which Apple's own accessibility audit flags for small text and icons.

## Accessibility checklist (automated)

`make ui-test` runs Apple's accessibility audit (`performAccessibilityAudit`) on every screen: Chat, Channels, People, Person, Connections, Envelopes and Settings. It also captures screenshots in light mode, dark mode and the largest text size (Accessibility XXXL). The audit is clean, with three documented exclusions:

1. **Toolbar items, for Dynamic Type only.** iOS caps text in navigation bars by design. They support the Large Content Viewer instead (touch and hold), which the audit can't see.
2. **List section headers and footers, for Dynamic Type only.** iOS lists stop growing them at accessibility sizes. They're still checked for contrast.
3. **Rows pushed off screen when the audit enlarges text, for Dynamic Type only.** These are tagged `row-label`. The largest-text screenshots show they grow and wrap.

**Also done:**
- VoiceOver labels on every control, with spoken people counts, delivery states, safety numbers and hidden messages ("Hidden message").
- The privacy screen blurs text, disables copying, and keeps VoiceOver from reading hidden text.
- Touch targets are system toolbar and list sizes, 44 pt or more.

**Still to do:**
- Reduce Motion: the blur animation is short, but should respect the setting.
- Localisation: strings are English-only.

## Usability review: lessons from *Don't Make Me Think*

Reviewed 2026-11-15 against Steve Krug's *Don't Make Me Think, Revisited* (3rd edition), using the current screenshots. The book's main point fits a hiking app well: people scan rather than read, take the first option that looks right, and muddle through rather than learn how things work. On a trail they'll also be cold, tired and wearing gloves.

### What changed

| Screen | Problem | Principle | Change |
|---|---|---|---|
| Empty chat | "No messages yet. Say hi." didn't say what #nearby is, that it needs no signal, or what happens to messages sent when nobody's around | Every screen should answer "what is this, and what can I do here?" | Each kind of conversation explains itself: #nearby says it needs no internet, who's in range, and that people arriving in the next 12 hours can catch up; alone, it offers Invite. Private chats say only the two of you can read them and that Letterbox keeps trying for 3 days. Location channels say relays see your IP |
| Failed private message | A red mark with nothing to do about it | Make it easy to recover from errors | It says "Not delivered. Hold to send again" in words, and the long-press menu has **Send again** |
| Send outside Letterbox | The message box was a blank white area; the disabled button below it read "Type a message to send", so it looked like the place to type | Make it obvious what can be tapped and typed in | The box shows "Your message". The button always reads "Send via AirDrop or another app" and is grey until there's text. The three notes became one footer right under the button: brief, timely and hard to miss |
| Settings | Erase everything sat in the middle, above "How it works" | Follow conventions | Moved to the bottom, where iOS puts destructive actions |
| Sheets opened from the "…" menu | On iOS 27 the keyboard stayed up over the sheet and hid half of Settings (found by the accessibility audit) | Don't hide what people came to see | Opening any sheet now closes the keyboard |
| All sheets | Footers of two or three sentences | Cut half the words, then half of what's left | Footers for Alerts, Erase, your code, the safety number, envelopes, connections and invite cut to one or two short sentences, with no information lost |

### What already held up

- **Screen names match what you tapped:** "…" → Send outside Letterbox opens "Send outside Letterbox"; the people count opens "Nearby"; the connection icons open "Connections".
- **Conventions:** system sheets, Done buttons, lists, the share sheet, SF Symbols, and a composer placeholder that says where the message goes ("Message everyone nearby").
- **Accessibility:** Apple's audit runs on every screen in the UI tests, and long screens are now also audited scrolled to the end. It caught two contrast problems and the keyboard bug in this pass. Each audited screen's screenshot is attached when the test fails. The audit also checks Dynamic Type up to the largest size and VoiceOver labels. Krug's own three-second test is making the text bigger, which the screenshot test covers.
- **Honesty:** the Connections panel says satellite can't be checked, rather than guessing. The book's chapter on courtesy calls this telling people what they want to know.

### Still open

- **The connection icons at top left are icons only.** They're labelled for VoiceOver, but a first-time user may not know what they mean. Watch for this in the test below before adding words; the bar is tight.
- **Nobody has used Letterbox in a test yet.** The book's strongest advice is to watch three people try it; everything above is expert review, which it calls a poor substitute.

### Usability test script (three people, one morning)

Krug recommends a small test with three people often over a large one rarely. Use two phones, one with Letterbox and a helper on the other, and someone who hasn't seen the app. Ask them to think aloud. Don't help: note where they hesitate.

1. **Get it test:** show the empty #nearby screen for 10 seconds. "What do you think this app does?"
2. "Send a message to everyone around you."
3. "Send Sam a private message that nobody else can read."
4. "Did Sam get it? How can you tell?"
5. "You're at the hut and don't want people reading over your shoulder. Hide your messages."
6. "Is your phone connected to the internet right now? Can Letterbox reach anyone?"
7. "Your friend doesn't have Letterbox. Send them 'Meet at the car park at 6'."
8. "You're lending your phone to someone. Remove everything Letterbox knows about you."

Afterwards, fix the one or two problems that tripped up most people, then test again. Record what you found here.
