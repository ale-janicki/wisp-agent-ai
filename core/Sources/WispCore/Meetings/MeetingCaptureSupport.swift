import Foundation

public enum MeetingCaptureSupport {
    public static let minimum = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

    public static func isSupported(_ version: OperatingSystemVersion) -> Bool {
        (version.majorVersion, version.minorVersion) >= (minimum.majorVersion, minimum.minorVersion)
    }

    public static func unsupportedMessage(for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String? {
        guard !isSupported(version) else { return nil }
        return "Gravar reuniões precisa do macOS 14.2 ou mais novo. Este Mac está no macOS \(version.majorVersion).\(version.minorVersion)."
    }
}
