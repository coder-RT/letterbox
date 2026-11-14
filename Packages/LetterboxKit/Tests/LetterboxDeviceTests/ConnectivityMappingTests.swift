import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxDevice

@Suite("Connectivity mapping")
struct ConnectivityMappingTests {
    @Test func internetPathPrefersWiFiThenMobileThenCable() {
        func path(_ satisfied: Bool, wifi: Bool = false, cellular: Bool = false, wired: Bool = false) -> InternetPath {
            ConnectivityMapping.internet(satisfied: satisfied, wifi: wifi, cellular: cellular, wired: wired,
                                         constrained: false, expensive: false).path
        }
        #expect(path(false, wifi: true) == .offline)
        #expect(path(true, wifi: true, cellular: true) == .wifi)
        #expect(path(true, cellular: true) == .cellular)
        #expect(path(true, wired: true) == .wired)
        #expect(path(true) == .other)
    }

    @Test func lowDataAndMeteredOnlyCountWhenOnline() {
        let offline = ConnectivityMapping.internet(satisfied: false, wifi: false, cellular: false, wired: false,
                                                   constrained: true, expensive: true)
        #expect(!offline.isConstrained && !offline.isExpensive && !offline.isOnline)
        let mobile = ConnectivityMapping.internet(satisfied: true, wifi: false, cellular: true, wired: false,
                                                  constrained: true, expensive: true)
        #expect(mobile.isConstrained && mobile.isExpensive && mobile.isOnline)
    }

    @Test(arguments: [
        ("CTRadioAccessTechnologyNR", "5G"), ("CTRadioAccessTechnologyNRNSA", "5G"), ("CTRadioAccessTechnologyLTE", "LTE"),
        ("CTRadioAccessTechnologyWCDMA", "3G"), ("CTRadioAccessTechnologyHSDPA", "3G"), ("CTRadioAccessTechnologyeHRPD", "3G"),
        ("CTRadioAccessTechnologyEdge", "2G"), ("CTRadioAccessTechnologyGPRS", "2G"), ("CTRadioAccessTechnologyFuture", "Future"),
        ("", "Unknown"),
    ])
    func radioNames(raw: String, expected: String) {
        #expect(ConnectivityMapping.radioName(raw) == expected)
    }

    @Test func cellularStatus() {
        #expect(ConnectivityMapping.cellular(technologies: nil, hasMobileRadio: false) == .unsupported)
        #expect(ConnectivityMapping.cellular(technologies: nil, hasMobileRadio: true) == .noService)
        #expect(ConnectivityMapping.cellular(technologies: [:], hasMobileRadio: true) == .noService)
        #expect(ConnectivityMapping.cellular(technologies: ["sim1": "CTRadioAccessTechnologyLTE"], hasMobileRadio: true)
                == .connected(radio: "LTE"))
        // Dual SIM: report the better radio.
        #expect(ConnectivityMapping.cellular(technologies: ["a": "CTRadioAccessTechnologyEdge", "b": "CTRadioAccessTechnologyNR"],
                                             hasMobileRadio: true) == .connected(radio: "5G"))
    }

    @Test func locationAuthorization() {
        #expect(ConnectivityMapping.location(authorizationRawValue: 0) == .notDetermined)
        #expect(ConnectivityMapping.location(authorizationRawValue: 1) == .restricted)
        #expect(ConnectivityMapping.location(authorizationRawValue: 2) == .denied)
        #expect(ConnectivityMapping.location(authorizationRawValue: 3) == .allowed)
        #expect(ConnectivityMapping.location(authorizationRawValue: 4) == .allowed)
    }

    @Test func monitorStartsAndReportsSomething() async {
        let monitor = SystemConnectivityMonitor()
        var iterator = monitor.updates.makeAsyncIterator()
        monitor.start()
        monitor.start() // starting twice is harmless
        let first = await iterator.next()
        #expect(first != nil)
        #expect(first?.cellular == .unsupported) // macOS test host has no mobile radio
    }
}
