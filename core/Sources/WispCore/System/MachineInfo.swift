import Foundation

public struct MachineInfo: Equatable, Sendable {
    public var name: String
    public var modelIdentifier: String
    public var chip: String
    public var osVersion: String
    public var osBuild: String
    public var hostName: String
    public var bootTime: Date

    public init(name: String, modelIdentifier: String, chip: String, osVersion: String, osBuild: String, hostName: String, bootTime: Date) {
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.hostName = hostName
        self.bootTime = bootTime
    }

    public static func deviceTreeString(_ data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        guard let text = String(data: Data(bytes), encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    public static func build(fromVersionString text: String) -> String? {
        guard let range = text.range(of: "Build ") else { return nil }
        let build = text[range.upperBound...].prefix { $0 != ")" }
        return build.isEmpty ? nil : String(build)
    }

    public static func version(_ version: OperatingSystemVersion) -> String {
        version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
