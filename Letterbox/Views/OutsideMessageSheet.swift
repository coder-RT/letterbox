import LetterboxApplication
import SwiftUI

/// Reaching someone who doesn't have Letterbox: invite them to get it, or send a one-way
/// message through the system share sheet. AirDrop works with no internet to nearby
/// Apple devices; they tap Accept.
struct OutsideMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var addInvite = true
    private let nickname: String

    init(draft: String, nickname: String) {
        _text = State(initialValue: draft)
        self.nickname = nickname
    }

    private var shareable: String? { ShareText.outside(text, addInvite: addInvite) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShareLink(item: ShareText.invite(from: nickname)) {
                        RowLabel("Invite them to get Letterbox", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("outside-invite")
                } header: {
                    SectionHeader("Invite")
                } footer: {
                    SectionFooter("With Letterbox on both phones you can chat with no internet, and they can reply.")
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Message")
                        .accessibilityIdentifier("outside-text")
                    Toggle("Add how to get Letterbox", isOn: $addInvite)
                        .accessibilityIdentifier("outside-add-invite")
                } header: {
                    SectionHeader("Or send a one-way message")
                }

                Section {
                    if let shareable {
                        ShareLink(item: shareable) {
                            RowLabel("Send via AirDrop or another app", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("outside-share")
                    } else {
                        RowLabel("Type a message to send", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Theme.secondaryText)
                    }
                }

                Section {
                    RowLabel("AirDrop works with no internet, to iPhones, iPads and Macs nearby. They tap Accept.",
                             systemImage: "antenna.radiowaves.left.and.right")
                    RowLabel("It's one-way: they can reply in Letterbox only if they install it.", systemImage: "arrow.uturn.left")
                    RowLabel("Messages and Mail send it over the internet, outside Letterbox's encryption.", systemImage: "lock.open")
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            }
            .contentMargins(.top, 24, for: .scrollContent)
            .navigationTitle("Send outside Letterbox")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
