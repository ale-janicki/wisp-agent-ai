import CryptoKit
import Foundation

public struct DrawingFileState: Equatable, Sendable {
    public enum ExternalChange: Equatable, Sendable {
        case none
        case reload
        case prompt
    }

    public private(set) var knownDiskHash: String?
    public var dirty = false

    public init(knownDiskHash: String? = nil) {
        self.knownDiskHash = knownDiskHash
    }

    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public mutating func didLoad(_ data: Data) {
        knownDiskHash = Self.hash(of: data)
        dirty = false
    }

    public mutating func didWrite(_ data: Data) {
        knownDiskHash = Self.hash(of: data)
        dirty = false
    }

    public func externalChange(diskData: Data?) -> ExternalChange {
        guard let diskData else { return dirty ? .prompt : .none }
        if Self.hash(of: diskData) == knownDiskHash { return .none }
        return dirty ? .prompt : .reload
    }
}
