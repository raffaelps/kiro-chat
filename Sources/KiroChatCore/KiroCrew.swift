import Foundation

/// Integração com o app Kiro Crew: lista os Bots dele e monta o comando que acorda um Bot.
///
/// Um Bot do Kiro Crew não é um agente do `kiro-cli`: `kiro-cli chat --agent Jon` falha com
/// "agent not found". O certo é `kirocrew chat --agent <chave> -m "..."`, onde a chave é a entrada
/// do Bot em `agents` no config do Kiro Crew (não o nome exibido, como "Jon - Chief").
/// Nesse modo o `kirocrew` imprime só o texto da resposta, que o Kiro Chat publica no chat.
public enum KiroCrew {
    public struct Bot: Hashable, Identifiable, Sendable {
        /// Chave usada em `--agent` (ex: "jon-chief").
        public let key: String
        /// Nome mostrado no Kiro Crew (ex: "Jon - Chief"); vazio se não houver.
        public let displayName: String
        public let description: String
        public var id: String { key }
        public var label: String { displayName.isEmpty ? key : displayName }
    }

    /// Pasta de dados do Kiro Crew (KIROCREW_HOME ou ~/.kiro/crew).
    public static var dataHome: URL {
        if let h = ProcessInfo.processInfo.environment["KIROCREW_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: (h as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/crew")
    }

    /// Caminho do CLI `kirocrew`, se o Kiro Crew estiver instalado.
    public static var binaryPath: String? {
        let candidates = [
            dataHome.appendingPathComponent("kirocrew-bin/kirocrew").path,
            "/Applications/KiroCrew.app/Contents/Resources/backend-dist/kirocrew-backend-arm64/bin/kirocrew",
            "/Applications/KiroCrew.app/Contents/Resources/backend-dist/kirocrew-backend-x86_64/bin/kirocrew",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool { binaryPath != nil }

    /// Bots do Kiro Crew (leitura apenas do config; nada é alterado).
    /// Agentes internos do Kiro Crew (`default`, `kirocrew-conductor`, `kirocrew-heartbeat`...) ficam de fora:
    /// não são Bots do roster.
    public static func isInternal(_ key: String) -> Bool {
        key == "default" || key.lowercased().hasPrefix("kirocrew-")
    }

    public static func bots() -> [Bot] {
        let url = dataHome.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = json["agents"] as? [String: Any] else { return [] }
        return agents.compactMap { key, value -> Bot? in
            guard !isInternal(key) else { return nil }
            let v = value as? [String: Any] ?? [:]
            return Bot(key: key, displayName: v["display_name"] as? String ?? "",
                       description: v["description"] as? String ?? "")
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Nome do Bot no chat: o primeiro nome do Kiro Crew ("Jon - Chief" → "Jon").
    public static func chatName(for bot: Bot) -> String {
        let first = bot.label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? bot.key
        return ChatNames.displayName(fromRaw: first)
    }

    /// O Bot do Kiro Crew que corresponde a um bot do chat ("jon" ↔ "Jon - Chief").
    public static func match(for chatBot: String, in bots: [Bot] = bots()) -> Bot? {
        let key = ChatNames.normalize(chatBot)
        guard !key.isEmpty else { return nil }
        if let exact = bots.first(where: { ChatNames.normalize($0.key) == key }) { return exact }
        func firstWord(_ s: String) -> String {
            ChatNames.normalize(String(s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first ?? ""))
        }
        return bots.first { firstWord($0.label) == key || firstWord($0.key) == key }
    }

    /// Comando de gatilho que acorda o Bot e imprime a resposta dele.
    public static func command(for bot: Bot, binary: String? = binaryPath) -> String {
        "\(shellQuote(binary ?? "kirocrew")) chat --agent \(shellQuote(bot.key)) -m \"$KIRO_CHAT_PROMPT\""
    }

    static func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./~")
        if !s.isEmpty, s.allSatisfy({ safe.contains($0) }), !s.hasPrefix("~") { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
