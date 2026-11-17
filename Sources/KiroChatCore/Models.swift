import Foundation

public enum MessageKind: String, Codable, Sendable {
    /// Mensagem normal no canal.
    case message
    /// Alerta direcionado: um bot chamando/avisando outro bot.
    case alert
    /// Evento do sistema (entrada de bot, canal criado...).
    case system
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let channel: String
    /// Chave do remetente (minúsculas), usada para comparações.
    public let sender: String
    /// Nome de exibição do remetente (ex: "Jon").
    public let senderName: String
    public let text: String
    public let kind: MessageKind
    public let replyTo: Int64?
    public let createdAt: Date
    /// Chaves dos bots mencionados (minúsculas).
    public let mentions: [String]
    /// Nomes de exibição dos bots mencionados, na mesma ordem de `mentions`.
    public let mentionNames: [String]
    /// Trocas seguidas entre bots até esta mensagem (0 = escrita por um humano ou sem conversa anterior).
    public let hop: Int

    public init(id: Int64, channel: String, sender: String, senderName: String? = nil, text: String,
                kind: MessageKind, replyTo: Int64?, createdAt: Date, mentions: [String],
                mentionNames: [String]? = nil, hop: Int = 0) {
        self.hop = hop
        self.id = id
        self.channel = channel
        self.sender = sender
        self.senderName = senderName ?? ChatNames.display(forKey: sender)
        self.text = text
        self.kind = kind
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.mentions = mentions
        self.mentionNames = mentionNames ?? mentions.map(ChatNames.display(forKey:))
    }
}

public struct BotInfo: Codable, Identifiable, Hashable, Sendable {
    /// Chave (minúsculas), usada em menções e comparações.
    public let name: String
    /// Nome de exibição, com a primeira letra maiúscula (ex: "Jon").
    public let displayName: String
    public let description: String
    public let isHuman: Bool
    public let createdAt: Date
    public let lastSeen: Date?

    public var id: String { name }

    /// Como mencionar o bot: "@Jon" (ou "@code-reviewer" se o nome de exibição tiver espaços).
    public var handle: String {
        "@" + (displayName.lowercased() == name ? displayName : name)
    }

    /// Um bot é considerado online se usou o chat nos últimos `window` segundos.
    public func isOnline(now: Date = Date(), window: TimeInterval = 120) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < window
    }
}

public struct ChannelInfo: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let topic: String
    public let messageCount: Int
    public let lastMessageId: Int64
    /// Canal aberto: toda mensagem de humano sem menção é ouvida por todos os bots.
    public var isOpen: Bool = false
    /// Conversa direta: chave do único bot deste canal (nil em canais comuns).
    public var dmWith: String? = nil
    public var isDirect: Bool { dmWith != nil }

    public var id: String { name }
}

public enum ChatNames {
    /// Nomes especiais que notificam todos os bots.
    public static let broadcast: Set<String> = ["all", "todos", "everyone", "crew"]
    public static let defaultChannel = "geral"

    /// Normaliza nome de bot/canal: minúsculas, sem @/#, apenas [a-z0-9_.-].
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let first = s.first, first == "@" || first == "#" { s.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")
        s = String(s.map { allowed.contains($0) ? $0 : "-" })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    /// Nome de exibição a partir do que o bot informou: mantém a capitalização original,
    /// mas garante a primeira letra maiúscula ("jon" → "Jon", "JonSnow" → "JonSnow").
    public static func displayName(fromRaw raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, first == "@" || first == "#" { s.removeFirst() }
        s = s.components(separatedBy: .controlCharacters).joined()
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Nome de exibição padrão para uma chave sem cadastro ("sistema" → "Sistema").
    public static func display(forKey key: String) -> String {
        guard let first = key.first else { return key }
        return first.uppercased() + key.dropFirst()
    }

    /// Extrai @menções do texto (já normalizadas, sem duplicatas, na ordem em que aparecem).
    public static func extractMentions(from text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_.-])@([A-Za-z0-9_][A-Za-z0-9_.-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = normalize(ns.substring(with: match.range(at: 1)))
            if !name.isEmpty, seen.insert(name).inserted { result.append(name) }
        }
        return result
    }
}

public enum ChatPaths {
    /// Caminho do banco. Pode ser sobrescrito pela variável KIRO_CHAT_DB.
    public static var defaultDatabaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["KIRO_CHAT_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KiroChat", isDirectory: true)
            .appendingPathComponent("chat.sqlite")
    }
}
