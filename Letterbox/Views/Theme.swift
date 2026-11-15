import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Colours and small view helpers. See docs/design.md for the reasoning and contrast ratios.
enum Theme {
    /// Ink blue: the colour of letters and airmail. Defined in the asset catalog with
    /// dark-mode and Increase Contrast variants, all at least 4.5:1 against the background.
    static let accent = Color("AccentColor")
    /// Background of your own message bubbles: white text on it stays at least 5:1 in
    /// light and dark mode (the dark-mode accent is too light for white text).
    static let ownBubble = Color("OwnBubble")
    /// Small secondary text (captions, timestamps, explanations). Darker than the system
    /// `.secondary` so small text keeps at least 4.5:1 contrast, in light and dark mode.
    /// Status colours, darker than the system ones in light mode so text and icons in
    /// them keep 4.5:1 on white (system green is about 2.2:1).
    static let good = Color.dynamicRGB(light: (0x1A, 0x7F, 0x37), dark: (0x4C, 0xD9, 0x64))
    static let warning = Color.dynamicRGB(light: (0xB4, 0x53, 0x09), dark: (0xFF, 0xB3, 0x40))
    static let bad = Color.dynamicRGB(light: (0xC0, 0x26, 0x2D), dark: (0xFF, 0x69, 0x61))

    static let secondaryText = Color.dynamic(
        light: (hue: 240.0 / 360, saturation: 0.05, brightness: 0.29),  // ≈ #45454A, 9.5:1 on white
        dark: (hue: 240.0 / 360, saturation: 0.03, brightness: 0.70)    // ≈ #ADADB2, 9:1 on black
    )

    /// A stable colour per sender key, so two people with the same nickname still look
    /// different. Darker in light mode and lighter in dark mode, so names stay readable.
    static func color(for key: String) -> Color {
        var hash: UInt64 = 1469598103934665603 // FNV-1a
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = Double(hash % 360) / 360
        return .dynamic(
            light: (hue: hue, saturation: 0.80, brightness: 0.42),
            dark: (hue: hue, saturation: 0.45, brightness: 0.92)
        )
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension Color {
    typealias HSB = (hue: Double, saturation: Double, brightness: Double)
    typealias RGB = (UInt8, UInt8, UInt8)

    /// A colour from 0–255 RGB values that follows light and dark mode.
    static func dynamicRGB(light: RGB, dark: RGB) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(v.0) / 255, green: CGFloat(v.1) / 255, blue: CGFloat(v.2) / 255, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat(v.0) / 255, green: CGFloat(v.1) / 255, blue: CGFloat(v.2) / 255, alpha: 1)
        })
        #endif
    }

    /// A colour that follows light and dark mode.
    static func dynamic(light: HSB, dark: HSB) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(hue: value.hue, saturation: value.saturation, brightness: value.brightness, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(hue: value.hue, saturation: value.saturation, brightness: value.brightness, alpha: 1)
        })
        #endif
    }
}

/// A list section header in the readable secondary colour. The system's default grey
/// header falls below 4.5:1 on the grouped background.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .foregroundStyle(Color.primary)
            .accessibilityIdentifier("section-header")
    }
}

/// Explanation under a list section, in the readable secondary colour.
struct SectionFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .accessibilityIdentifier("section-footer")
    }
}

/// An icon and text for list rows. Unlike `Label` in a list, the text always wraps and
/// grows to the largest accessibility sizes.
struct RowLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("row-label")
        }
    }
}

extension View {
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
