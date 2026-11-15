import LetterboxApplication
import LetterboxDomain
import SwiftUI

/// The Pager theme: an homage to 90s pagers. A backlit LCD-green screen and a
/// decorative top strip with a seven-segment clock (DSEG7) and dot-matrix brand
/// (DotGothic16), both under the SIL Open Font License (licences in Resources/Fonts).
/// Everything people read (messages, names, timestamps) uses the system monospaced font,
/// so it scales with Dynamic Type and keeps full contrast.
///
/// Contrast (WCAG), light / dark:
/// - ink on screen: 9.7:1 / 12.3:1 · ink on panel: 7.8:1 / 10.1:1
/// - own bubble text: 9.7:1 / 12.3:1 · dim text on screen: 5.8:1 / 6.6:1
/// - alert red on screen: 6.7:1 / 8.2:1
enum PagerStyle {
    /// The LCD screen behind the conversation.
    static let screen = Color.dynamicRGB(light: (0xA9, 0xD8, 0x6E), dark: (0x0B, 0x14, 0x07))
    /// The status strip at the top, a shade darker, like the pager's top line.
    static let strip = Color.dynamicRGB(light: (0x96, 0xC9, 0x58), dark: (0x13, 0x22, 0x0C))
    /// Other people's bubbles.
    static let panel = Color.dynamicRGB(light: (0x8F, 0xC4, 0x55), dark: (0x18, 0x29, 0x0F))
    /// LCD "ink": text and icons on the screen.
    static let ink = Color.dynamicRGB(light: (0x13, 0x26, 0x0C), dark: (0x9B, 0xE5, 0x64))
    /// Timestamps and small print.
    static let dim = Color.dynamicRGB(light: (0x2E, 0x4D, 0x1F), dark: (0x6F, 0xA8, 0x4A))
    /// Your own bubbles are inverted, like a highlighted line on the LCD.
    static let ownBubble = Color.dynamicRGB(light: (0x1F, 0x3A, 0x14), dark: (0x9B, 0xE5, 0x64))
    static let ownText = Color.dynamicRGB(light: (0xC8, 0xF0, 0x8F), dark: (0x0B, 0x14, 0x07))
    /// "Not delivered", readable on the green screen (the standard red isn't).
    static let alert = Color.dynamicRGB(light: (0x7A, 0x0F, 0x12), dark: (0xFF, 0x8A, 0x80))

    /// Seven-segment digits, for clocks and counts. Only digits, `-` and `:` look right.
    static func segments(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("DSEG7Classic-Bold", size: size, relativeTo: style)
    }

    /// Dot-matrix lettering, for short headings.
    static func dots(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("DotGothic16-Regular", size: size, relativeTo: style)
    }

    /// Message text: the system monospaced font, readable and Dynamic Type friendly.
    static let message = Font.system(.body, design: .monospaced)

    /// Pager clocks were 24-hour, and seven segments can't draw "AM"/"PM".
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM"
        return formatter
    }()
}

/// The pager's top line: the brand in dot-matrix capitals, then people in range, the date
/// and the time in seven segments. Drawn with `Canvas`, like the LCD it imitates: it's a
/// picture, not text. That's on purpose: LCD glyphs are dots and thin segments, which don't
/// scale or contrast like text should, and everything here is also in the title (channel),
/// the people button (who's in range) and the system clock. So VoiceOver and the
/// accessibility audit have nothing to read twice.
struct PagerStatusBar: View {
    @Environment(ChatStore.self) private var store
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 38

    var body: some View {
        TimelineView(.everyMinute) { context in
            Canvas { canvas, size in
                let middle = size.height / 2
                let right = canvas.resolve(readout(context.date))
                let rightWidth = right.measure(in: size).width
                canvas.draw(right, at: CGPoint(x: size.width - 14, y: middle), anchor: .trailing)
                let brand = canvas.resolve(
                    Text("HELLOLETTER").font(PagerStyle.dots(19, relativeTo: .headline)).foregroundStyle(PagerStyle.ink)
                )
                // The brand only if it fits beside the readout (it's the first thing to go).
                if brand.measure(in: size).width + rightWidth + 40 <= size.width {
                    canvas.draw(brand, at: CGPoint(x: 14, y: middle), anchor: .leading)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(PagerStyle.strip)
            .overlay(alignment: .bottom) { Rectangle().fill(PagerStyle.ink.opacity(0.3)).frame(height: 1) }
            .accessibilityHidden(true)
        }
    }

    /// Radio icon and people count, then date and 24-hour time (seven segments can't draw
    /// "AM/PM").
    private func readout(_ date: Date) -> Text {
        let segments = PagerStyle.segments(14, relativeTo: .footnote)
        let icon = Text(Image(systemName: "dot.radiowaves.left.and.right")).font(.footnote.weight(.bold))
        let digits = Text(" \(store.peers.count)   \(PagerStyle.day(date))   \(PagerStyle.time(date))").font(segments)
        return Text("\(icon)\(digits)").foregroundStyle(PagerStyle.ink)
    }
}
