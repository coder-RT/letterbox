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
                    SectionFooter("Then you can both chat with no internet.")
                }

                Section {
                    // The box says what goes in it; an empty white area with no hint
                    // left people tapping the button below instead.
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Your message")
                                    .foregroundStyle(Theme.secondaryText)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("Message")
                        .accessibilityIdentifier("outside-text")
                    Toggle("Add how to get Letterbox", isOn: $addInvite)
                        .accessibilityIdentifier("outside-add-invite")
                } header: {
                    SectionHeader("Or send a one-way message")
                }

                Section {
                    // Always the same words, so it reads as the send button. Until there's a
                    // message it's grey (the system's disabled dimming fails contrast).
                    if let shareable {
                        ShareLink(item: shareable) {
                            RowLabel("Send via AirDrop or another app", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("outside-share")
                    } else {
                        // Identifier on a wrapper, so the label keeps its own ("row-label").
                        HStack {
                            RowLabel("Send via AirDrop or another app", systemImage: "square.and.arrow.up")
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityHint("Type a message first")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("outside-share-waiting")
                    }
                } footer: {
                    SectionFooter("AirDrop works with no internet to Apple devices nearby; they tap Accept. They can only reply if they get Letterbox. Messages and Mail send it over the internet, outside Letterbox's encryption.")
                }
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
