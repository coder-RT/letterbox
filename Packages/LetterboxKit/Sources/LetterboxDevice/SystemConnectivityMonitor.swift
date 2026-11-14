import CoreLocation
import Foundation
import LetterboxDomain
import Network
#if os(iOS)
import CoreTelephony
import MessageUI
#endif

/// Device adapter for the `ConnectivityMonitor` port: the network path (NWPathMonitor),
/// the mobile radio (CoreTelephony, iPhone only) and location permission (CoreLocation).
///
/// Satellite and mobile signal strength have no public API, so they're not reported.
public final class SystemConnectivityMonitor: NSObject, ConnectivityMonitor, CLLocationManagerDelegate, @unchecked Sendable {
    public let updates: AsyncStream<SystemConnectivity>
    private let continuation: AsyncStream<SystemConnectivity>.Continuation
    private let queue = DispatchQueue(label: "app.letterbox.connectivity")
    private let pathMonitor = NWPathMonitor()
    private var current = SystemConnectivity.unknown // touched only on `queue`
    private var started = false
    private var locationManager: CLLocationManager? // main thread only
    #if os(iOS)
    private let telephony = CTTelephonyNetworkInfo()
    private var radioObserver: NSObjectProtocol?
    #endif

    public override init() {
        (updates, continuation) = AsyncStream.makeStream(of: SystemConnectivity.self, bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let internet = ConnectivityMapping.internet(
                    satisfied: path.status == .satisfied,
                    wifi: path.usesInterfaceType(.wifi),
                    cellular: path.usesInterfaceType(.cellular),
                    wired: path.usesInterfaceType(.wiredEthernet),
                    constrained: path.isConstrained,
                    expensive: path.isExpensive
                )
                self.update { $0.internet = internet }
                self.refreshCellular() // a path change often means the radio changed too
            }
            pathMonitor.start(queue: queue)
            refreshCellular()
            #if os(iOS)
            radioObserver = NotificationCenter.default.addObserver(
                forName: .CTServiceRadioAccessTechnologyDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.refreshCellular() }
            }
            #endif
        }
        DispatchQueue.main.async { [self] in
            let manager = CLLocationManager()
            manager.delegate = self
            locationManager = manager
            report(manager.authorizationStatus)
            #if os(iOS)
            let canSend = MFMessageComposeViewController.canSendText()
            update { $0.canSendTexts = canSend }
            #endif
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        report(manager.authorizationStatus)
    }

    private func report(_ status: CLAuthorizationStatus) {
        let access = ConnectivityMapping.location(authorizationRawValue: status.rawValue)
        update { $0.location = access }
    }

    /// Must run on `queue`.
    private func refreshCellular() {
        #if os(iOS)
        let cellular = ConnectivityMapping.cellular(technologies: telephony.serviceCurrentRadioAccessTechnology, hasMobileRadio: true)
        #else
        let cellular = ConnectivityMapping.cellular(technologies: nil, hasMobileRadio: false)
        #endif
        current.cellular = cellular
        continuation.yield(current)
    }

    private func update(_ change: @escaping @Sendable (inout SystemConnectivity) -> Void) {
        queue.async { [self] in
            change(&current)
            continuation.yield(current)
        }
    }
}
