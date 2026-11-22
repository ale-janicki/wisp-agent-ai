import Foundation

public struct DrawingEditSession: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case requestSave
        case setViewMode(Bool)
        case scheduleAutosave
        case cancelAutosave
        case writeNow
    }

    public private(set) var editing = false
    public private(set) var pageDirty = false
    public private(set) var awaitingSave = false
    public private(set) var pendingScene: String?

    public init() {}

    public var hasUnsavedWork: Bool { pageDirty || pendingScene != nil }
    private var accepting: Bool { editing || pageDirty || awaitingSave || pendingScene != nil }

    public mutating func setEditing(_ value: Bool, pageReady: Bool) -> [Action] {
        guard value != editing else { return [] }
        editing = value
        guard pageReady else { return [] }
        if value { return [.setViewMode(false)] }
        var actions: [Action] = []
        if hasUnsavedWork {
            awaitingSave = true
            actions.append(.requestSave)
        }
        actions.append(.setViewMode(true))
        return actions
    }

    public mutating func handle(_ event: DrawingBridgeEvent) -> [Action] {
        switch event {
        case .dirty:
            if accepting { pageDirty = true }
            return []
        case .clean:
            if pendingScene == nil { pageDirty = false }
            awaitingSave = false
            return []
        case .changed(let scene):
            guard accepting else { return [] }
            pageDirty = true
            pendingScene = scene
            return [.scheduleAutosave]
        case .save(let scene):
            guard accepting else { return [] }
            pendingScene = scene
            awaitingSave = false
            return [.cancelAutosave, .writeNow]
        default:
            return []
        }
    }

    public mutating func didWrite() {
        pendingScene = nil
        pageDirty = false
        awaitingSave = false
    }

    public mutating func didReload() {
        pendingScene = nil
        pageDirty = false
        awaitingSave = false
    }

    public mutating func discardPending() {
        pendingScene = nil
    }
}
