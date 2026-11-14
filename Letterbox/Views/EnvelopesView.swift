import LetterboxApplication
import LetterboxDomain
import SwiftUI

/// Messages sealed in envelopes: yours on their way, and how many you carry for others.
struct EnvelopesView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        List {
            Section {
                if store.envelopes.outgoing.isEmpty {
                    Text("None right now. If a private message can't reach someone you've met, Letterbox seals it in an envelope and hands it to hikers you pass.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(store.envelopes.outgoing, id: \.messageID) { envelope in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("To " + store.title(for: .direct(envelope.recipient)).dropFirst())
                            .font(.body.weight(.medium))
                        if let text = preview(envelope) {
                            Text(text)
                                .font(.callout)
                                .lineLimit(2)
                                .blur(radius: store.hidesMessages ? 6 : 0)
                                .accessibilityLabel(store.hidesMessages ? "Hidden message" : text)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            RowLabel(envelope.carriers == 1 ? "Carried by 1 hiker" : "Carried by \(envelope.carriers) hikers",
                                     systemImage: "figure.walk")
                            RowLabel("Expires \(envelope.expires.formatted(.relative(presentation: .named)))", systemImage: "hourglass")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SectionHeader("Yours, on their way")
            }

            Section {
                RowLabel(
                    store.envelopes.carryingForOthers == 1 ? "1 envelope" : "\(store.envelopes.carryingForOthers) envelopes",
                    systemImage: "envelope"
                )
            } header: {
                SectionHeader("Carrying for others")
            } footer: {
                SectionFooter("These are sealed: you can't read them. Letterbox hands each one over automatically if you meet the person it's for, and drops it after 3 days.")
            }
        }
        // Keep the first header clear of the bar's scroll-edge fade.
        .contentMargins(.top, 24, for: .scrollContent)
        .navigationTitle("Envelopes")
        .inlineTitle()
    }

    private func preview(_ envelope: OutgoingEnvelope) -> String? {
        store.messages(in: .direct(envelope.recipient)).first { $0.id == envelope.messageID }?.text
    }
}
