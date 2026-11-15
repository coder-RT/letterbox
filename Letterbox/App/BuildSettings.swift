import Foundation
import LetterboxApplication

/// Per-build settings from Info.plist (see project.yml). Nothing personal is committed:
/// the support address comes from Makefile.local when the project is generated.
enum BuildSettings {
    /// Location channels are in Debug builds and left out of Release (the App Store build).
    static var offersLocationChannels: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "LetterboxLocationChannels") as? String)?.uppercased() != "NO"
    }

    /// Where reports and questions go; nil until the publisher sets one.
    static var supportEmail: String? {
        SupportContact.address(from: Bundle.main.object(forInfoDictionaryKey: "LetterboxSupportEmail") as? String)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
