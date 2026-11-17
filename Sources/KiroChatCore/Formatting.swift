import Foundation

public enum ChatFormat {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// Uma linha legível por LLM: `[#42 2026-11-17 15:30:01] #geral @planner → @coder: texto`
    public static func line(_ m: ChatMessage) -> String {
        var head = "[#\(m.id) \(time(m.createdAt))] #\(m.channel) @\(m.senderName)"
        if m.kind == .alert { head += " 🔔ALERTA" }
        if let r = m.replyTo { head += " (resposta a #\(r))" }
        if !m.mentions.isEmpty { head += " → " + m.mentionNames.map { "@\($0)" }.joined(separator: " ") }
        let body = m.text.replacingOccurrences(of: "\n", with: "\n    ")
        return "\(head): \(body)"
    }

    public static func lines(_ messages: [ChatMessage], empty: String = "(nenhuma mensagem)") -> String {
        messages.isEmpty ? empty : messages.map(line).joined(separator: "\n")
    }

    public static func bots(_ bots: [BotInfo], now: Date = Date()) -> String {
        guard !bots.isEmpty else { return "(nenhum bot registrado ainda)" }
        return bots.map { b in
            let status = b.isOnline(now: now) ? "🟢 online" : "⚪️ offline"
            let seen = b.lastSeen.map { "visto \(time($0))" } ?? "nunca visto"
            let kind = b.isHuman ? " [humano]" : ""
            let desc = b.description.isEmpty ? "" : " — \(b.description)"
            return "\(b.handle)\(kind) \(status) (\(seen))\(desc)"
        }.joined(separator: "\n")
    }

    public static func channels(_ channels: [ChannelInfo], unread: [String: Int] = [:]) -> String {
        channels.map { c in
            let u = unread[c.name].map { $0 > 0 ? " — \($0) não lida(s)" : "" } ?? ""
            let topic = c.topic.isEmpty ? "" : " — \(c.topic)"
            return "#\(c.name) (\(c.messageCount) msgs)\(topic)\(u)"
        }.joined(separator: "\n")
    }
}
