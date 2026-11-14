import Foundation
import LetterboxDomain

/// A `BlobStore` that keeps its bytes in memory, so tests can "restart" a node by
/// building a new one over the same store.
public final class InMemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public private(set) var saveCount = 0

    public init() {}

    public func load() -> Data? { lock.withLock { data } }

    public func save(_ data: Data) throws {
        lock.withLock {
            self.data = data
            saveCount += 1
        }
    }

    public func delete() { lock.withLock { data = nil } }

    /// The raw bytes, for "nothing readable is stored" checks.
    public var contents: Data? { lock.withLock { data } }
}
