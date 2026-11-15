import LetterboxDomain
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct MessageList: View {
    let messages: [ChatMessage]
    /// Privacy mode: blur message text until tapped.
    var hidesText = false
    /// How many hikers carry each of our messages that's in an envelope.
    var envelopes = EnvelopeSummary.empty

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if messages.isEmpty {
                        Text("No messages yet. Say hi.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message, hidesText: hidesText, carriers: envelopes.carriers(for: message.id))
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            // Room under the last message, so it sits clear of the bottom scroll edge.
            .contentMargins(.bottom, 12, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively) // swipe down on the messages to put the keyboard away
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var hidesText = false
    var carriers: Int?
    /// A blurred message the user tapped to peek at. Hides itself again after a few seconds.
    @State private var revealed = false

    private static let peekDuration: Duration = .seconds(5)
    private var isBlurred: Bool { hidesText && !revealed }

    var body: some View {
        if message.senderKey == "system" {
            Text(message.text)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if message.isOwn { Spacer(minLength: 48) }
            VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 3) {
                if !message.isOwn {
                    HStack(spacing: 4) {
                        Text(message.senderName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.color(for: message.senderKey))
                        if !message.isVerified {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityLabel("Sender not verified")
                        }
                    }
                }
                messageText
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(message.isOwn ? Color.white : Color.primary)
                    .background(
                        message.isOwn ? AnyShapeStyle(Theme.ownBubble) : AnyShapeStyle(.quaternary.opacity(0.7)),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                HStack(spacing: 4) {
                    Text(Theme.time(message.timestamp))
                    if let delivery = message.delivery {
                        DeliveryIcon(state: delivery, carriers: carriers)
                    }
                }
                .font(.caption.weight(.medium)) // thin small text reads lighter than its colour
                .foregroundStyle(Theme.secondaryText)
            }
            if !message.isOwn { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { infoMenu }
        .onChange(of: hidesText) { revealed = false }
        .task(id: revealed) {
            guard revealed else { return }
            try? await Task.sleep(for: Self.peekDuration)
            revealed = false
        }
    }

    @ViewBuilder
    private var messageText: some View {
        if hidesText {
            Text(message.text)
                .blur(radius: isBlurred ? 7 : 0)
                .animation(.easeOut(duration: 0.15), value: isBlurred)
                .contentShape(Rectangle())
                .onTapGesture { revealed.toggle() }
                .accessibilityLabel(isBlurred ? Text("Hidden message") : Text(message.text))
                .accessibilityHint(isBlurred ? "Double-tap to show it for a few seconds" : "Double-tap to hide it")
                .accessibilityAddTraits(.isButton)
        } else {
            Text(message.text)
        }
    }

    /// Long-press: the message's status in words, and Copy while it's visible.
    @ViewBuilder
    private var infoMenu: some View {
        Section {
            Text(statusDescription)
            Text("\(message.isOwn ? "Sent" : "Received") \(message.timestamp.formatted(date: .abbreviated, time: .shortened))")
        }
        if !isBlurred {
            Button {
                Clipboard.copy(message.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            // Your own words only: passing on other people's messages is their call.
            if message.isOwn, message.senderKey != "system" {
                ShareLink(item: message.text) {
                    Label("Send via AirDrop…", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var statusDescription: String {
        guard message.isOwn else {
            return message.isVerified ? "From \(message.senderName)" : "From \(message.senderName). Sender not verified"
        }
        switch message.delivery {
        case .queued: return "Waiting for them to come within reach"
        case .inEnvelope:
            guard let carriers else { return "In an envelope" }
            return carriers == 1 ? "In an envelope, carried by 1 hiker" : "In an envelope, carried by \(carriers) hikers"
        case .sent: return "Sent"
        case .delivered: return "Delivered to their phone"
        case .read: return "Read"
        case .failed: return "Not delivered. Letterbox gave up after 3 days"
        case nil: return "Sent to everyone nearby"
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        // SEC-09: stays on this phone (no Universal Clipboard) and clears itself after 2 minutes.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

private struct DeliveryIcon: View {
    let state: DeliveryState
    var carriers: Int?

    var body: some View {
        switch state {
        case .queued: Label("Waiting for recipient", systemImage: "clock").labelStyle(.iconOnly)
        case .inEnvelope:
            HStack(spacing: 2) {
                Image(systemName: "envelope")
                if let carriers, carriers > 0 { Text("\(carriers)") }
            }
            .foregroundStyle(Theme.accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(carriers.map { $0 == 1 ? "In an envelope, carried by 1 hiker" : "In an envelope, carried by \($0) hikers" }
                                ?? "In an envelope")
        case .sent: Label("Sent", systemImage: "checkmark").labelStyle(.iconOnly)
        case .delivered: Label("Delivered", systemImage: "checkmark.circle").labelStyle(.iconOnly)
        case .read: Label("Read", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(Theme.accent)
        case .failed: Label("Not delivered", systemImage: "exclamationmark.circle").labelStyle(.iconOnly).foregroundStyle(Theme.bad)
        }
    }
}
