import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public final class AXMacDriver: MacDriver {
    private static let messagingTimeout: Float = 2
    private static let activationDelay: useconds_t = 350_000
    private static let typingPause: useconds_t = 8_000

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    public var trusted: Bool { AXIsProcessTrusted() }

    public func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    private func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, "AXPosition"), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &origin)
        }
        if let value = attribute(element, "AXSize"), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    private func pressable(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return false }
        return list.contains("AXPress")
    }

    private func editable(_ element: AXUIElement) -> Bool {
        if let flag = attribute(element, "AXEditable") as? Bool, flag { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable) == .success && settable.boolValue
    }

    private func describe(_ element: AXUIElement, depth: Int) -> MacElement {
        let box = frame(element)
        let role = string(element, "AXRole"), subrole = string(element, "AXSubrole")
        let secure = MacSafety.isSecure(role: role, subrole: subrole)
        return MacElement(role: role, subrole: subrole, title: string(element, "AXTitle"), detail: string(element, "AXDescription"),
                          value: secure ? "" : string(element, "AXValue"),
                          help: string(element, "AXHelp"), identifier: string(element, "AXIdentifier"),
                          pressable: pressable(element), editable: editable(element), x: Int(box.origin.x), y: Int(box.origin.y),
                          width: Int(box.size.width), height: Int(box.size.height), depth: depth)
    }

    private func application(_ name: String?) throws -> NSRunningApplication {
        guard let name, !name.isEmpty else {
            guard let front = NSWorkspace.shared.frontmostApplication else { throw MacError("não achei o app da frente") }
            return front
        }
        let wanted = MacMatch.fold(name)
        let running = NSWorkspace.shared.runningApplications
        let found = running.first { $0.bundleIdentifier.map(MacMatch.fold) == wanted }
            ?? running.first { $0.localizedName.map(MacMatch.fold) == wanted }
            ?? running.first { $0.activationPolicy == .regular && ($0.localizedName.map(MacMatch.fold)?.contains(wanted) ?? false) }
        guard let found else { throw MacError("o app \(name) não está aberto") }
        return found
    }

    private func root(_ app: String?) throws -> AXUIElement {
        let target = try application(app)
        let element = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        for name in ["AXFocusedWindow", "AXMainWindow"] {
            if let window = attribute(element, name) { return unsafeBitCast(window, to: AXUIElement.self) }
        }
        if let first = (attribute(element, "AXWindows") as? [AXUIElement])?.first { return first }
        throw MacError("o app \(target.localizedName ?? "") não tem janela aberta")
    }

    private func walk(_ app: String?, max: Int, depth: Int) throws -> [(MacElement, AXUIElement)] {
        var out: [(MacElement, AXUIElement)] = []
        func visit(_ element: AXUIElement, _ level: Int) {
            guard out.count < max else { return }
            out.append((describe(element, depth: level), element))
            guard level < depth else { return }
            for child in children(element) { visit(child, level + 1) }
        }
        visit(try root(app), 0)
        return out
    }

    public func tree(app: String?, max: Int, depth: Int) throws -> [MacElement] {
        try walk(app, max: max, depth: depth).map(\.0)
    }

    public func pressElement(app: String?, max: Int, depth: Int, at index: Int, expect: MacElement, block: String?) throws {
        let nodes = try walk(app, max: max, depth: depth)
        guard index < nodes.count else { throw MacError("o elemento mudou de lugar; leia a árvore de novo") }
        let current = nodes[index].0
        guard current.role == expect.role, current.title == expect.title, current.detail == expect.detail else {
            throw MacError("o elemento mudou de lugar; leia a árvore de novo")
        }
        let chain = MacSafety.ancestors(of: index, in: nodes.map(\.0))
        if MacSafety.blocks(current, ancestors: chain, pattern: block) { throw MacError(MacRefusal.sendButton(current.label), exitCode: MacError.blocked) }
        if AXUIElementPerformAction(nodes[index].1, "AXPress" as CFString) == .success { return }
        guard current.width > 0 else { throw MacError("não consegui clicar nesse elemento") }
        try clickPoint(x: current.centerX, y: current.centerY)
    }

    public func hit(x: Int, y: Int) -> MacHit? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &found) == .success, let found else { return nil }
        var ancestors: [MacElement] = []
        var cursor = found
        while ancestors.count < MacSafety.ancestorLimit, let parent = attribute(cursor, "AXParent") {
            let element = unsafeBitCast(parent, to: AXUIElement.self)
            ancestors.append(describe(element, depth: 0))
            cursor = element
        }
        var pid: pid_t = 0
        AXUIElementGetPid(found, &pid)
        let name = NSRunningApplication(processIdentifier: pid).flatMap { $0.localizedName ?? $0.bundleIdentifier } ?? ""
        return MacHit(element: describe(found, depth: 0), ancestors: ancestors, app: name)
    }

    public func clickPoint(x: Int, y: Int) throws {
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .hidSystemState)
        for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: point, mouseButton: .left) else {
                throw MacError("não consegui criar o clique")
            }
            event.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    public func focus(app: String?) throws -> MacFocus {
        let target = try application(app)
        let element = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let name = target.localizedName ?? target.bundleIdentifier ?? ""
        var document = "", title = ""
        if let window = attribute(element, "AXFocusedWindow") ?? attribute(element, "AXMainWindow") {
            let windowElement = unsafeBitCast(window, to: AXUIElement.self)
            document = string(windowElement, "AXDocument")
            title = string(windowElement, "AXTitle")
        }
        guard let focused = attribute(element, "AXFocusedUIElement") else {
            return MacFocus(app: name, element: nil, document: document, window: title, bundle: target.bundleIdentifier ?? "")
        }
        return MacFocus(app: name, element: describe(unsafeBitCast(focused, to: AXUIElement.self), depth: 0), document: document, window: title,
                        bundle: target.bundleIdentifier ?? "")
    }

    private func bringToFront(_ app: String?) throws {
        guard let app, !app.isEmpty else { return }
        let target = try application(app)
        if target.isHidden { target.unhide() }
        target.activate()
        usleep(Self.activationDelay)
    }

    private func guardFocus(pid: pid_t) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw MacError(MacRefusal.focusChanged, exitCode: MacError.refused) }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        guard let focused = attribute(element, "AXFocusedUIElement") else { throw MacError(MacRefusal.unreadableFocus, exitCode: MacError.refused) }
        let described = describe(unsafeBitCast(focused, to: AXUIElement.self), depth: 0)
        if described.isSecure { throw MacError(MacRefusal.secureField, exitCode: MacError.refused) }
    }

    private func frontPid() throws -> pid_t {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw MacError(MacRefusal.focusChanged, exitCode: MacError.refused) }
        return pid
    }

    private func post(code: CGKeyCode, flags: CGEventFlags = []) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw MacError("não consegui criar a tecla")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(Self.typingPause)
        }
    }

    public func type(_ text: String, app: String?) throws {
        try bringToFront(app)
        let pid = try frontPid()
        var pending: [UniChar] = []
        func flush() throws {
            guard !pending.isEmpty else { return }
            try guardFocus(pid: pid)
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                    throw MacError("não consegui criar o texto")
                }
                pending.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: pending.count, unicodeString: $0.baseAddress) }
                event.post(tap: .cghidEventTap)
                usleep(Self.typingPause)
            }
            pending.removeAll()
        }
        for character in text {
            if character == "\n" || character == "\r\n" {
                try flush()
                try guardFocus(pid: pid)
                try post(code: 36)
            } else if character == "\t" {
                try flush()
                try guardFocus(pid: pid)
                try post(code: 48)
            } else {
                pending.append(contentsOf: Array(String(character).utf16))
                if pending.count >= 16 { try flush() }
            }
        }
        try flush()
    }

    public func key(_ combo: MacKeyCombo, app: String?) throws {
        try bringToFront(app)
        try guardFocus(pid: try frontPid())
        var flags: CGEventFlags = []
        if combo.command { flags.insert(.maskCommand) }
        if combo.shift { flags.insert(.maskShift) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.control { flags.insert(.maskControl) }
        if combo.function { flags.insert(.maskSecondaryFn) }
        try post(code: CGKeyCode(combo.keyCode), flags: flags)
    }

    public func scroll(dx: Int, dy: Int, app: String?) throws {
        try bringToFront(app)
        let window = try root(app)
        let box = frame(window)
        if box.width > 0 { CGWarpMouseCursorPosition(CGPoint(x: box.midX, y: box.midY)) }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw MacError("não consegui criar a rolagem")
        }
        event.post(tap: .cghidEventTap)
    }

    public func menuItem(path: [String], app: String?, press: Bool, exact: Bool, block: String?, expect: String?) throws -> MacElement {
        let target = try application(app)
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        guard let bar = attribute(appElement, "AXMenuBar") else { throw MacError("o app não tem barra de menus legível") }
        var current = unsafeBitCast(bar, to: AXUIElement.self)
        for name in path {
            var items = children(current)
            if let menu = items.first(where: { string($0, "AXRole") == "AXMenu" }) { items = children(menu) }
            let wanted = MacMatch.fold(name)
            let titled = items.map { ($0, MacMatch.fold(string($0, "AXTitle"))) }
            let exactMatch = titled.first(where: { $0.1 == wanted })?.0
            let partial = exact ? nil : titled.first(where: { !wanted.isEmpty && $0.1.contains(wanted) })?.0
            guard let match = exactMatch ?? partial else { throw MacError("não achei o item de menu \"\(name)\"") }
            current = match
        }
        let resolved = describe(current, depth: 0)
        if press {
            if let expect, resolved.title != expect { throw MacError("o item de menu mudou; tente de novo") }
            if MacSafety.blocks(resolved, pattern: block) { throw MacError(MacRefusal.sendButton(resolved.label), exitCode: MacError.blocked) }
            if AXUIElementPerformAction(current, "AXPress" as CFString) != .success {
                throw MacError("não consegui acionar esse item de menu (talvez esteja desabilitado)")
            }
        }
        return resolved
    }

    public func apps() -> [MacApp] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            MacApp(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "", pid: Int($0.processIdentifier),
                   active: $0.processIdentifier == front, hidden: $0.isHidden)
        }
    }

    public func windows(app: String?) throws -> [MacWindow] {
        let wanted = app.map(MacMatch.fold)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { info in
            guard (info["kCGWindowLayer"] as? Int) == 0, let id = info["kCGWindowNumber"] as? Int,
                  let owner = info["kCGWindowOwnerName"] as? String else { return nil }
            if let wanted, !MacMatch.fold(owner).contains(wanted) { return nil }
            let bounds = info["kCGWindowBounds"] as? [String: Double] ?? [:]
            return MacWindow(id: id, app: owner, title: info["kCGWindowName"] as? String ?? "", x: Int(bounds["X"] ?? 0),
                             y: Int(bounds["Y"] ?? 0), width: Int(bounds["Width"] ?? 0), height: Int(bounds["Height"] ?? 0))
        }
    }

    public func activate(app: String) throws {
        let target = try application(app)
        if target.isHidden { target.unhide() }
        target.activate()
    }

    public func hide(app: String) throws {
        guard try application(app).hide() else { throw MacError("não consegui esconder \(app)") }
    }

    public func quit(app: String) throws {
        guard try application(app).terminate() else { throw MacError("\(app) não aceitou fechar") }
    }
}
