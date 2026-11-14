import Foundation
import LetterboxDomain

/// Turns raw readings into one row per way of communicating, in plain words.
/// All the wording lives here, so the view only renders it and every case is tested.
public enum ConnectionReport {
    public static func rows(
        system: SystemConnectivity,
        radio: RadioState,
        permissions: TransportPermissions,
        nearby: Int,
        relays: (connected: Int, total: Int),
        inLocationChannel: Bool,
        envelopes: EnvelopeSummary
    ) -> [ConnectionRow] {
        [
            ConnectionRow(kind: .bluetooth, title: "Bluetooth",
                          status: bluetooth(radio, allowed: permissions.bluetooth, nearby: nearby),
                          enables: "Chat with people nearby, with no signal or internet"),
            ConnectionRow(kind: .internet, title: "Internet",
                          status: internet(system.internet, allowed: permissions.internet),
                          enables: "Location channels"),
            ConnectionRow(kind: .wifi, title: "Wi-Fi",
                          status: wifi(system.internet),
                          enables: "Internet without using mobile data"),
            ConnectionRow(kind: .mobile, title: "Mobile network",
                          status: mobile(system.cellular, canSendTexts: system.canSendTexts),
                          enables: "SMS and calls from your phone's own apps, and mobile data"),
            ConnectionRow(kind: .satellite, title: "Satellite",
                          status: .notDetectable("Apps can't check this. On iPhone 14 or later, try Messages or Emergency SOS when there's no signal."),
                          enables: "Texts and SOS with no mobile signal, outside Letterbox"),
            ConnectionRow(kind: .location, title: "Location",
                          status: location(system.location),
                          enables: "Joining location channels"),
            ConnectionRow(kind: .relays, title: "Relays",
                          status: relayStatus(relays, internetAllowed: permissions.internet, inChannel: inLocationChannel),
                          enables: "Messages in location channels"),
            ConnectionRow(kind: .envelopes, title: "Envelopes",
                          status: envelopeStatus(envelopes, bluetoothAllowed: permissions.bluetooth),
                          enables: "Messages carried by other hikers to people out of range"),
        ]
    }

    static func bluetooth(_ radio: RadioState, allowed: Bool, nearby: Int) -> ConnectionStatus {
        guard allowed else { return .blockedByYou("Turned off in Letterbox") }
        switch radio {
        case .ready:
            switch nearby {
            case 0: return .working("On. No one in range yet")
            case 1: return .working("On. 1 person nearby")
            default: return .working("On. \(nearby) people nearby")
            }
        case .poweredOff: return .off("Bluetooth is off. Turn it on in Control Center.")
        case .unauthorized: return .notAllowed("Letterbox isn't allowed to use Bluetooth. Allow it in Settings.")
        case .unsupported: return .unavailable("This device can't do Bluetooth chat.")
        case .unknown: return .checking("Starting…")
        }
    }

    static func internet(_ status: InternetStatus, allowed: Bool) -> ConnectionStatus {
        guard allowed else { return .blockedByYou("Turned off in Letterbox") }
        let lowData = status.isConstrained ? " (Low Data Mode)" : ""
        switch status.path {
        case .wifi: return .working("Connected via Wi-Fi" + lowData)
        case .cellular: return .working("Connected via mobile data" + lowData)
        case .wired: return .working("Connected via cable" + lowData)
        case .other: return .working("Connected" + lowData)
        case .offline: return .off("No internet connection")
        case .unknown: return .checking("Checking…")
        }
    }

    static func wifi(_ status: InternetStatus) -> ConnectionStatus {
        switch status.path {
        case .wifi: .working("Connected")
        case .unknown: .checking("Checking…")
        default: .off("Not connected to Wi-Fi")
        }
    }

    static func mobile(_ cellular: CellularStatus, canSendTexts: Bool?) -> ConnectionStatus {
        switch cellular {
        case let .connected(radio):
            let texts = canSendTexts == true ? ". Can send texts" : ""
            return .working("Signal (\(radio))" + texts)
        case .noService: return .off("No mobile signal")
        case .unsupported: return .unavailable("Not available on this device")
        case .unknown: return .checking("Checking…")
        }
    }

    static func location(_ access: LocationAccess) -> ConnectionStatus {
        switch access {
        case .allowed: .working("Allowed")
        case .denied: .notAllowed("Off for Letterbox. Allow it in Settings to join location channels.")
        case .restricted: .notAllowed("Restricted on this device")
        case .notDetermined: .off("Not asked yet. Letterbox asks when you join a location channel.")
        }
    }

    static func relayStatus(_ relays: (connected: Int, total: Int), internetAllowed: Bool, inChannel: Bool) -> ConnectionStatus {
        guard internetAllowed else { return .blockedByYou("Paused while the internet is off in Letterbox") }
        guard inChannel else { return .off("Not in use. Join a location channel to connect.") }
        guard relays.total > 0 else { return .checking("Connecting…") }
        return relays.connected > 0
            ? .working("\(relays.connected) of \(relays.total) connected")
            : .off("0 of \(relays.total) connected. Check your internet connection.")
    }

    static func envelopeStatus(_ envelopes: EnvelopeSummary, bluetoothAllowed: Bool) -> ConnectionStatus {
        guard bluetoothAllowed else { return .blockedByYou("Paused while Bluetooth is off in Letterbox") }
        let mine = envelopes.outgoing.count
        let theirs = envelopes.carryingForOthers
        if mine == 0, theirs == 0 { return .working("None right now") }
        let mineText = mine == 1 ? "1 of yours on its way" : "\(mine) of yours on their way"
        return .working("\(mineText), carrying \(theirs) for others")
    }
}
