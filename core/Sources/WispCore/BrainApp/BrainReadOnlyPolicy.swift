public enum BrainReadOnlyPolicy {
    public enum EmbedMode: Sendable, Equatable { case render, linkText }

    public static func embedMode(readOnly: Bool) -> EmbedMode { readOnly ? .linkText : .render }

    public static func tasksAreInteractive(readOnly: Bool) -> Bool { !readOnly }

    public static func containsEmbed(_ nodes: [BrainBlockNode]) -> Bool {
        nodes.contains { node in
            switch node.block {
            case .embed: true
            case .quote(let blocks): containsEmbed(blocks)
            case .callout(_, _, _, _, let body): containsEmbed(body)
            case .list(_, _, let items): items.contains { containsEmbed($0.blocks) }
            default: false
            }
        }
    }
}
