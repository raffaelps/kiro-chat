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

    // MARK: - Perfil do Bot

    /// Como o Bot foi configurado no Kiro Crew: papel, objetivos, briefing e pasta de trabalho.
    ///
    /// `kirocrew chat --agent` carrega as ferramentas, MCPs e permissões do agente, mas não o papel
    /// nem os objetivos do Bot. Por isso o Kiro Chat lê esse perfil a cada gatilho (só leitura) e o
    /// coloca no começo do prompt.
    public struct Profile: Equatable, Sendable {
        public let key: String
        public let displayName: String
        /// Papel (campo "description" do Bot no Kiro Crew).
        public let role: String
        public let goals: [String]
        /// Briefing atual do Bot (`members/<id>/briefing.md`).
        public let briefing: String
        /// Pasta de trabalho do Bot, se existir.
        public let workspace: URL?

        public var isEmpty: Bool { role.isEmpty && goals.isEmpty && briefing.isEmpty }

        /// Bloco de texto com o perfil, para o prompt.
        public var promptSection: String {
            var lines = ["Seu perfil no Kiro Crew (é assim que você foi configurado; responda nesse papel):"]
            if !displayName.isEmpty { lines.append("- Nome no Kiro Crew: \(displayName)") }
            if !role.isEmpty { lines.append("- Papel: \(role)") }
            if !goals.isEmpty {
                lines.append("- Objetivos:")
                lines += goals.map { "  • \($0)" }
            }
            if !briefing.isEmpty {
                lines.append("- Briefing atual:")
                lines += briefing.components(separatedBy: "\n").map { $0.isEmpty ? "" : "  \($0)" }
            }
            return lines.joined(separator: "\n")
        }
    }

    static let maxBriefing = 2_000

    /// Perfil do Bot cuja chave em `agents` é `key`. Nil se o Bot não existir.
    public static func profile(forAgent key: String, home: URL = dataHome) -> Profile? {
        func json(_ path: String) -> [String: Any]? {
            (try? Data(contentsOf: home.appendingPathComponent(path)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard let config = json("config.json"),
              let agent = (config["agents"] as? [String: Any])?[key] as? [String: Any] else { return nil }
        func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        // Só nomes simples viram caminho (evita sair da pasta do Kiro Crew com "../").
        func safe(_ s: String) -> String? {
            !s.isEmpty && !s.contains("/") && !s.hasPrefix(".") ? s : nil
        }
        let member = safe(clean(agent["member_id"] as? String))

        var goals: [String] = []
        if let member, let g = json("member-records/member-goals/\(member).json")?["goals"] as? [[String: Any]] {
            goals = g.compactMap { clean($0["text"] as? String) }.filter { !$0.isEmpty }
        }
        var briefing = ""
        if let member, let text = try? String(contentsOf: home.appendingPathComponent("members/\(member)/briefing.md"), encoding: .utf8) {
            briefing = clean(text)
            if briefing.count > maxBriefing { briefing = String(briefing.prefix(maxBriefing)) + " …(cortado)" }
        }

        var workspace: URL?
        if let ws = safe(clean(agent["workspace"] as? String)) {
            let entry = (config["workspaces"] as? [String: Any])?[ws] as? [String: Any]
            let dir = clean(entry?["dir"] as? String)
            let url: URL
            if dir.hasPrefix("/") { url = URL(fileURLWithPath: dir) }
            else if dir.hasPrefix("~") { url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
            else { url = home.appendingPathComponent(dir.isEmpty ? "workspace-\(ws)" : dir) }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { workspace = url }
        }

        return Profile(key: key, displayName: clean(agent["display_name"] as? String),
                       role: clean(agent["description"] as? String), goals: goals,
                       briefing: briefing, workspace: workspace)
    }

    /// Chave do Bot num comando de gatilho do Kiro Crew (`kirocrew chat --agent <chave> ...`).
    public static func agentKey(inCommand command: String) -> String? {
        let pattern = #"kirocrew'?\s+chat\s+(?:.*?\s)?--agent(?:\s+|=)(?:'([^']*)'|"([^"]*)"|([^\s'";|&)]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for i in 1...3 {
            if let r = Range(m.range(at: i), in: command), !command[r].isEmpty { return String(command[r]) }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./~")
        if !s.isEmpty, s.allSatisfy({ safe.contains($0) }), !s.hasPrefix("~") { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
