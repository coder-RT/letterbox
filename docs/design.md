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

### Licensing

- **SF Symbols:** free to use in apps on Apple platforms under the Xcode and SF Symbols licence. They **may not be used in app icons, logos or trademarks**, so the app icon must be original artwork.
- **Lucide** (lucide.dev) is ISC-licensed. It can be bundled and redistributed in an app if the licence notice is included; some icons come from Feather (MIT). It's a fine choice for the website or docs. In the app it would look foreign next to system controls, wouldn't scale with Dynamic Type for free, and adds assets to maintain. **Decision: not used in the app.**

## Colour

| Token | Light | Dark | Increase Contrast | Use |
|---|---|---|---|---|
| Accent (ink blue) | `#1D4ED8` (≈6.7:1 on white) | `#7AA2F7` (≈8:1 on black) | `#1E3A8A` / `#A5C0FF` | Buttons, links, icons |
| Own bubble | `#1D4ED8` | `#3B63D9` (white text ≈5.3:1) | `#1E3A8A` / `#1E40AF` | Your messages |
| Secondary text | `#505055` (≈8:1) | `#ADADB2` (≈9:1) | — | Captions, timestamps, footers |
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
