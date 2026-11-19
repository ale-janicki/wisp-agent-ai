import Foundation
import UniformTypeIdentifiers

public enum FileOpenPolicy {
    public enum Action: Equatable, Sendable { case open, reveal }

    private static let revealExtensions: Set<String> = [
        "app", "terminal", "command", "tool", "workflow", "action", "pkg", "mpkg", "dmg", "iso", "jar", "webloc", "inetloc",
        "fileloc", "url", "scpt", "scptd", "osa", "saver", "prefpane", "plugin", "bundle", "kext", "appex", "xpc",
        "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "rb", "pl", "js", "mjs", "lua", "php", "exe", "bat", "cmd", "msi",
        "ps1", "vbs", "docm", "xlsm", "pptm", "dotm", "xltm", "potm", "xlam", "ppam", "wsf", "lnk", "desktop", "scr",
        "mobileconfig", "jnlp", "ics", "webarchive", "html", "htm", "xhtml", "svg", "svgz",
    ]
    private static let revealTypes: [UTType] = [
        .executable, .unixExecutable, .application, .applicationBundle, .script, .shellScript, .archive, .diskImage,
        .package, .bundle, .url, .internetLocation, .aliasFile, .symbolicLink,
    ]
    private static let openTypes: [UTType] = [.text, .image, .movie, .audio, .pdf, .rtf, .spreadsheet, .presentation]
    private static let openIdentifierPrefixes = ["org.openxmlformats.", "com.apple.iwork.", "org.oasis-open.opendocument.",
                                                 "com.microsoft.word.", "com.microsoft.excel.", "com.microsoft.powerpoint.",
                                                 "com.apple.keynote.", "com.apple.numbers.", "com.apple.pages."]

    public static func action(pathExtension: String, isExecutable: Bool, isDirectory: Bool) -> Action {
        let ext = pathExtension.lowercased()
        if isDirectory || isExecutable || ext.isEmpty || revealExtensions.contains(ext) { return .reveal }
        guard let type = UTType(filenameExtension: ext), !type.identifier.hasPrefix("dyn.") else { return .reveal }
        if revealTypes.contains(where: { type.conforms(to: $0) }) { return .reveal }
        if openTypes.contains(where: { type.conforms(to: $0) }) { return .open }
        if openIdentifierPrefixes.contains(where: { type.identifier.hasPrefix($0) }) { return .open }
        return .reveal
    }
}
