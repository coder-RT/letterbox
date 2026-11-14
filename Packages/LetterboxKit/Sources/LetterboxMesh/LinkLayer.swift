import Foundation
import LetterboxDomain

/// Identifies one point-to-point radio link (one connected neighbour).
public typealias LinkID = String

public enum LinkEvent: Sendable {
    case up(LinkID)
    case down(LinkID)
    case frame(Data, from: LinkID)
    case radio(RadioState)
}

/// Driven port of the mesh engine: "something that moves frames to direct neighbours".
///
/// Sends are synchronous enqueues so the engine's packet order is preserved per link
/// and the engine never suspends (and re-enters) mid-update while handing off a frame.
/// CoreBluetooth implements this in `LetterboxBLE`; tests use an in-memory radio.
public protocol LinkLayer: Sendable {
    var events: AsyncStream<LinkEvent> { get }
    func start()
    func stop()
    func send(_ frame: Data, to link: LinkID)
    func broadcast(_ frame: Data, excluding link: LinkID?)
}
