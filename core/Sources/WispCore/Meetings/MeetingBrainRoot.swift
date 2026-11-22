import Foundation

/// The one brain root for the meeting sync: the same folder the Brain tab opens
/// (the profile's memory root, symlinks resolved in-process), falling back to the
/// configured brain folder when the profile has none.
public enum MeetingBrainRoot {
    public static func resolve(profileRoot: String?, configured: String) -> String {
        let chosen = profileRoot.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? configured
        return MemorySearch.resolvedRoot(chosen)
    }
}
