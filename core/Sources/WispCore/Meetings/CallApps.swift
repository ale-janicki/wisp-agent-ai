import Foundation

public struct CallApp: Equatable, Sendable {
    public enum Kind: Sendable { case native, browser }

    public let bundleID: String
    public let name: String
    public let kind: Kind

    public init(bundleID: String, name: String, kind: Kind) {
        self.bundleID = bundleID
        self.name = name
        self.kind = kind
    }
}

public enum CallAppCatalog {
    public static let native: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .native),
        CallApp(bundleID: "com.microsoft.teams2", name: "Teams", kind: .native),
        CallApp(bundleID: "com.microsoft.teams", name: "Teams", kind: .native),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", kind: .native),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", kind: .native),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord", kind: .native),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", kind: .native),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", kind: .native),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex", kind: .native),
        CallApp(bundleID: "com.skype.skype", name: "Skype", kind: .native),
    ]

    public static let browsers: [CallApp] = [
        CallApp(bundleID: "com.google.Chrome", name: "Chrome", kind: .browser),
        CallApp(bundleID: "com.apple.Safari", name: "Safari", kind: .browser),
        CallApp(bundleID: "org.mozilla.firefox", name: "Firefox", kind: .browser),
        CallApp(bundleID: "company.thebrowser.Browser", name: "Arc", kind: .browser),
        CallApp(bundleID: "com.microsoft.edgemac", name: "Edge", kind: .browser),
        CallApp(bundleID: "com.brave.Browser", name: "Brave", kind: .browser),
        CallApp(bundleID: "com.operasoftware.Opera", name: "Opera", kind: .browser),
        CallApp(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", kind: .browser),
    ]

    public static var all: [CallApp] { native + browsers }

    public static func app(forBundleID bundleID: String) -> CallApp? {
        let candidates = all
        if let exact = candidates.first(where: { $0.bundleID == bundleID }) { return exact }
        return candidates
            .filter { bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
}
