import Foundation

/// How large a location channel is. Precision is the geohash length.
public enum GeohashLevel: Int, CaseIterable, Sendable, Hashable {
    case region = 2
    case province = 4
    case city = 5
    case neighborhood = 6
    case block = 7

    public var precision: Int { rawValue }

    public var title: String {
        switch self {
        case .region: "Region"
        case .province: "Province"
        case .city: "City"
        case .neighborhood: "Neighborhood"
        case .block: "Block"
        }
    }
}

public enum Geohash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    public static func encode(_ coordinate: Coordinate, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var value = 0
        var useLongitude = true

        while hash.count < precision {
            if useLongitude {
                let mid = (lonRange.0 + lonRange.1) / 2
                if coordinate.longitude >= mid {
                    value = value << 1 | 1
                    lonRange.0 = mid
                } else {
                    value <<= 1
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if coordinate.latitude >= mid {
                    value = value << 1 | 1
                    latRange.0 = mid
                } else {
                    value <<= 1
                    latRange.1 = mid
                }
            }
            useLongitude.toggle()
            bit += 1
            if bit == 5 {
                hash.append(alphabet[value])
                bit = 0
                value = 0
            }
        }
        return hash
    }

    public static func isValid(_ hash: String) -> Bool {
        !hash.isEmpty && hash.count <= 12 && hash.allSatisfy { alphabet.contains($0) }
    }
}
