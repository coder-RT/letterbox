import CoreImage
import CoreImage.CIFilterBuiltins
import LetterboxApplication
import LetterboxCrypto
import LetterboxDomain
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// One person's details, and the in-person check that they are who they say.
struct PersonView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State private var scanning = false
    @State private var scanResult: ScanResult?

    enum ScanResult: Equatable { case matched, otherPerson, notACode }

    private var isVerified: Bool { store.isVerified(peer.fingerprint) }
    private var number: [String] { SafetyNumber.make(store.myFingerprint, peer.fingerprint) }

    var body: some View {
        List {
            Section {
                PersonRow(peer: peer, isVerified: isVerified)
                Button {
                    store.openDirect(with: peer)
                    dismiss()
                } label: {
                    RowLabel("Send a private message", systemImage: "lock")
                }
            }

            Section {
                SafetyNumberGrid(groups: number)
                    .accessibilityIdentifier("safety-number")
                if isVerified {
                    RowLabel("Verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.good)
                        .accessibilityIdentifier("verified-badge")
                    Button("Clear verification", role: .destructive) { store.clearVerification(peer.fingerprint) }
                } else {
                    Button {
                        store.markVerified(peer.fingerprint, nickname: peer.nickname)
                    } label: {
                        RowLabel("Numbers match: mark as verified", systemImage: "checkmark.seal")
                    }
                    .accessibilityIdentifier("mark-verified")
                }
                #if os(iOS)
                if DataScannerViewController.isSupported {
                    Button { scanning = true } label: {
                        RowLabel("Scan \(peer.nickname)'s code", systemImage: "qrcode.viewfinder")
                    }
                }
                #endif
                NavigationLink { MyCodeView() } label: {
                    RowLabel("Show my code", systemImage: "qrcode")
                }
            } header: {
                SectionHeader("Safety number")
            } footer: {
                SectionFooter("Meet \(peer.nickname) in person and check this number matches the one on their screen, or scan their code. Then you'll know messages really come from them.")
            }

            if let scanResult {
                Section {
                    switch scanResult {
                    case .matched:
                        RowLabel("It's a match. \(peer.nickname) is verified.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
                    case .otherPerson:
                        RowLabel("That code belongs to someone else, not \(peer.nickname). Don't mark them as verified.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    case .notACode:
                        RowLabel("That isn't a Letterbox code.", systemImage: "questionmark.circle").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        // Keep the first header clear of the bar's scroll-edge fade.
        .contentMargins(.top, 24, for: .scrollContent)
        .navigationTitle(peer.nickname)
        .inlineTitle()
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                handleScan(text)
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func handleScan(_ text: String) {
        guard let scanned = VerifyCode.parse(text) else { scanResult = .notACode; return }
        if scanned == peer.fingerprint {
            store.markVerified(peer.fingerprint, nickname: peer.nickname)
            scanResult = .matched
        } else {
            scanResult = .otherPerson
        }
    }
}

/// The safety number in two rows of four groups, large and easy to read aloud.
struct SafetyNumberGrid: View {
    let groups: [String]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Two columns at accessibility sizes so the digits can grow instead of shrinking.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Safety number: " + groups.joined(separator: ", "))
    }
}

/// Your own code for friends to scan.
struct MyCodeView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                QRCodeImage(text: VerifyCode.payload(for: store.myFingerprint))
                    .frame(maxWidth: 280)
                    .accessibilityLabel("Your QR code")
                Text(store.nickname).font(.title2.weight(.semibold))
                Text("On their phone, your friend opens Nearby, taps ⓘ next to your name, and scans this code. It works with no internet.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondaryText)
                VStack(spacing: 4) {
                    Text("Your fingerprint").font(.caption).foregroundStyle(Theme.secondaryText)
                    Text(store.myFingerprint.short).font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Your fingerprint: " + store.myFingerprint.short.split(separator: " ").joined(separator: ", "))
                }
            }
            .padding(24)
        }
        // Keep the first header clear of the bar's scroll-edge fade.
        .contentMargins(.top, 24, for: .scrollContent)
        .navigationTitle("Your safety code")
        .inlineTitle()
    }
}

/// A QR code drawn with Core Image. Always dark on white, so it scans in dark mode too.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        } else {
            Text(text).font(.footnote.monospaced())
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

#if os(iOS)
/// Camera QR scanner (VisionKit). Calls back once with the first code it reads.
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var done = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case let .barcode(code) = item, let text = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    onScan(text)
                    return
                }
            }
        }
    }
}
#endif
