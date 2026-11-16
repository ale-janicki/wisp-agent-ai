import Foundation

public enum ProfileError: Error, LocalizedError {
    case invalid(path: String, underlying: Error)
    case missingTarget(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let path, let underlying):
            return "Invalid profile at \(path): \(underlying.localizedDescription)"
        case .missingTarget(let path):
            return "Profile at \(path) is a symlink whose target is missing"
        }
    }
}

public enum ProfileLoader {
    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/wisp/profile.json")

    public static func load(from url: URL) throws -> Profile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw ProfileError.missingTarget(path: url.path)
            }
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            throw ProfileError.invalid(path: url.path, underlying: error)
        }
    }
}
