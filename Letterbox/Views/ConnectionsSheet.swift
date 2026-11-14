import LetterboxApplication
import LetterboxDomain
import SwiftUI

/// What works right now, what each way of communicating lets you do, and the two
/// switches for which ones Letterbox may use.
struct ConnectionsSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: binding(\.bluetooth, set: store.setBluetoothAllowed)) {
                        RowLabel("Use Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("toggle-bluetooth")
                    Toggle(isOn: binding(\.internet, set: store.setInternetAllowed)) {
                        RowLabel("Use the internet", systemImage: "globe")
                    }
                    .accessibilityIdentifier("toggle-internet")
                } header: {
                    SectionHeader("Letterbox may use")
                } footer: {
                    SectionFooter("Letterbox picks the best allowed way for each message: Bluetooth for people nearby, otherwise an envelope carried by other hikers. Turning the internet off pauses location channels, so relays never see your IP address.")
                }

                Section(header: SectionHeader("Right now")) {
                    ForEach(store.connectionRows) { row in
                        if row.kind == .envelopes {
                            NavigationLink { EnvelopesView() } label: { ConnectionRowView(row: row) }
                        } else {
                            ConnectionRowView(row: row)
                        }
                    }
                }
            }
            // Keep the first header clear of the bar's scroll-edge fade.
            .contentMargins(.top, 24, for: .scrollContent)
            .navigationTitle("Connections")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func binding(
        _ keyPath: KeyPath<TransportPermissions, Bool>,
        set: @escaping (Bool) async -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { store.permissions[keyPath: keyPath] },
            set: { newValue in Task { await set(newValue) } }
        )
    }
}

private struct ConnectionRowView: View {
    let row: ConnectionRow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.icon(row.kind))
                .frame(width: 24)
                .foregroundStyle(Self.color(row.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // At accessibility text sizes the badge goes under the title instead of
                // squeezing it.
                if typeSize.isAccessibilitySize {
                    Text(row.title).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                    badge
                } else {
                    HStack {
                        Text(row.title).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                        Spacer()
                        badge
                    }
                }
                Text(row.status.detail).font(.callout).foregroundStyle(Color.primary)
                Text(row.enables).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-\(row.kind.rawValue)")
    }

    private var badge: some View {
        Text(Self.badge(row.status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Self.color(row.status))
    }

    static func icon(_ kind: ConnectionKind) -> String {
        switch kind {
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .internet: "globe"
        case .wifi: "wifi"
        case .mobile: "cellularbars"
        case .satellite: "dot.radiowaves.up.forward"
        case .location: "location"
        case .relays: "server.rack"
        case .envelopes: "envelope"
        }
    }

    static func badge(_ status: ConnectionStatus) -> String {
        switch status {
        case .working: "Working"
        case .off: "Off"
        case .blockedByYou: "Off in Letterbox"
        case .notAllowed: "Not allowed"
        case .unavailable: "Unavailable"
        case .notDetectable: "Unknown"
        case .checking: "Checking"
        }
    }

    static func color(_ status: ConnectionStatus) -> Color {
        switch status {
        case .working: Theme.good
        case .off, .checking, .notDetectable: Theme.secondaryText
        case .blockedByYou: Theme.warning
        case .notAllowed, .unavailable: Theme.bad
        }
    }
}

/// Toolbar summary: one icon per way Letterbox itself sends messages.
struct ConnectionsChip: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let rows = Dictionary(uniqueKeysWithValues: store.connectionRows.map { ($0.kind, $0.status) })
        HStack(spacing: 6) {
            icon("antenna.radiowaves.left.and.right", rows[.bluetooth])
            icon("globe", rows[.internet])
            if store.envelopes.outgoing.count + store.envelopes.carryingForOthers > 0 {
                Image(systemName: "envelope.fill").foregroundStyle(Theme.accent)
            }
        }
        .font(.footnote.weight(.semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connections. Bluetooth \(rows[.bluetooth]?.detail ?? ""). Internet \(rows[.internet]?.detail ?? "")")
    }

    private func icon(_ name: String, _ status: ConnectionStatus?) -> some View {
        Image(systemName: name)
            .foregroundStyle(status.map(ConnectionRowView.color) ?? Theme.secondaryText)
            .overlay {
                if case .blockedByYou = status {
                    Rectangle().frame(height: 1.5).rotationEffect(.degrees(-45)).foregroundStyle(Theme.warning)
                }
            }
    }
}
