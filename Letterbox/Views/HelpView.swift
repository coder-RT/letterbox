import LetterboxApplication
import SwiftUI

/// Staying safe and getting in touch. App Review asks chat apps for a way to filter,
/// report and block, and for published contact details; this is where they live.
struct HelpView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { store.filtersOffensiveWords }, set: { store.setFiltersOffensiveWords($0) })) {
                    RowLabel("Hide offensive words", systemImage: "eye.slash")
                }
                .accessibilityIdentifier("filter-toggle")
                RowLabel("To block or report someone, touch and hold one of their messages.", systemImage: "hand.tap")
                RowLabel("Nobody at HelloLetter sees your messages: there's no server. A report is sent only if you email it.",
                         systemImage: "lock")
            } header: {
                SectionHeader("Staying safe")
            } footer: {
                SectionFooter("Offensive words are masked on your phone only.")
            }

            Section {
                if let email = BuildSettings.supportEmail, let url = URL(string: "mailto:\(email)?subject=HelloLetter") {
                    Link(destination: url) {
                        RowLabel("Email the HelloLetter team", systemImage: "envelope")
                    }
                    .accessibilityIdentifier("contact-email")
                }
                Link(destination: SupportContact.questions) {
                    RowLabel("Questions and answers", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("contact-questions")
                Link(destination: SupportContact.privacyPolicy) {
                    RowLabel("Privacy policy", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("contact-privacy")
                Link(destination: SupportContact.website) {
                    RowLabel("Website and source code", systemImage: "safari")
                }
                .accessibilityIdentifier("contact-website")
            } header: {
                SectionHeader("Contact")
            } footer: {
                SectionFooter("HelloLetter \(BuildSettings.appVersion)")
            }
        }
        .contentMargins(.top, 24, for: .scrollContent)
        .navigationTitle("Help and safety")
        .inlineTitle()
    }
}
