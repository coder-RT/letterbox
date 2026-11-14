import Foundation
import LetterboxDomain

/// Pure translations from what Apple's frameworks report to domain values, kept apart
/// from the frameworks themselves so they can be tested.
public enum ConnectivityMapping {
    public static func internet(
        satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool, constrained: Bool, expensive: Bool
    ) -> InternetStatus {
        let path: InternetPath
        if !satisfied {
            path = .offline
        } else if wifi {
            path = .wifi
        } else if cellular {
            path = .cellular
        } else if wired {
            path = .wired
        } else {
            path = .other
        }
        return InternetStatus(path: path, isConstrained: satisfied && constrained, isExpensive: satisfied && expensive)
    }

    /// `technologies` is `CTTelephonyNetworkInfo.serviceCurrentRadioAccessTechnology`:
    /// one radio access technology per SIM, or nil/empty when there's no service.
    public static func cellular(technologies: [String: String]?, hasMobileRadio: Bool) -> CellularStatus {
        guard hasMobileRadio else { return .unsupported }
        let names = (technologies ?? [:]).values.map(radioName)
        guard let best = names.max(by: { rank($0) < rank($1) }) else { return .noService }
        return .connected(radio: best)
    }

    /// "CTRadioAccessTechnologyNR" → "5G", and so on. Unknown values pass through readably.
    public static func radioName(_ technology: String) -> String {
        let name = technology.replacingOccurrences(of: "CTRadioAccessTechnology", with: "")
        switch name {
        case "NR", "NRNSA": return "5G"
        case "LTE": return "LTE"
        case "WCDMA", "HSDPA", "HSUPA", "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB", "eHRPD": return "3G"
        case "Edge", "GPRS", "CDMA1x": return "2G"
        default: return name.isEmpty ? "Unknown" : name
        }
    }

    private static func rank(_ name: String) -> Int {
        switch name {
        case "5G": 4
        case "LTE": 3
        case "3G": 2
        case "2G": 1
        default: 0
        }
    }

    /// Mirrors `CLAuthorizationStatus` raw values, so this file needs no CoreLocation.
    public static func location(authorizationRawValue: Int32) -> LocationAccess {
        switch authorizationRawValue {
        case 0: .notDetermined
        case 1: .restricted
        case 2: .denied
        default: .allowed // 3 always, 4 when in use
        }
    }
}
