import Foundation

public enum PhoneHandoff {
    public static let replyLimit = 800
    public static let opening = "📱 Continuando aqui."
    public static let stillAnswering = "Ainda estou respondendo; mando aqui quando terminar."

    public static func lastReply(in messages: [ConversationMessage], turnRunning: Bool) -> String? {
        var end = messages.endIndex
        if turnRunning, let user = messages.lastIndex(where: { $0.role == .user }) { end = user }
        let text = messages[..<end].last { $0.role == .assistant }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func message(lastReply: String?, turnRunning: Bool, approval: PermissionRequest?) -> String {
        var parts = [opening]
        if let reply = lastReply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            parts.append("Minha última resposta:\n\n" + trimmed(reply))
        }
        if let approval {
            parts.append("⏸ Estou esperando tua aprovação: o Claude quer \(approval.summary). Isso só dá para responder no Mac.")
        } else if turnRunning {
            parts.append(stillAnswering)
        }
        return parts.joined(separator: "\n\n")
    }

    static func trimmed(_ text: String, limit: Int = replyLimit) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(where: { $0.isWhitespace }), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        cut = cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        if cut.components(separatedBy: "```").count % 2 == 0 { cut += "\n```" }
        return cut
    }
}
