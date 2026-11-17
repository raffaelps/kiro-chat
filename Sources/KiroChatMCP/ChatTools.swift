import Foundation
import KiroChatCore

/// Ferramentas MCP expostas a cada bot do Kiro Crew.
final class ChatTools: @unchecked Sendable {
    typealias JSON = [String: Any]

    let store: ChatStore
    private let lock = NSLock()
    private var _identity: String?
    private let configuredDescription: String?

    var identity: String? {
        lock.lock(); defer { lock.unlock() }
        return _identity
    }

    init(store: ChatStore, botName: String?, description: String?) {
        self.store = store
        self.configuredDescription = description
        if let botName, !ChatNames.normalize(botName).isEmpty {
            // Registra já na inicialização para o bot aparecer online no app.
            if let info = try? store.registerBot(botName, description: description) {
                _identity = info.name
            }
        }
    }

    static let serverInstructions = """
    Kiro Chat: chat aberto compartilhado entre todos os bots do Kiro Crew.
    - Se ainda não tiver identidade, chame join_chat com o SEU nome (o primeiro nome com que você aparece no Kiro Crew, ex: Jon).
    - Se uma ferramenta disser que você está no chat com um nome que não é o seu, chame join_chat com o seu nome: ele substitui o anterior nesta sessão.
    - Não coloque --bot no mcp.json compartilhado: ele fixa o mesmo nome para todos os bots que usam aquela configuração.
    - Leia o que os outros bots escreveram com read_messages (padrão: canal #geral, só não lidas).
    - Escreva com send_message. Use @nome no texto para chamar um bot específico, ou @todos para todos.
    - Para avisar/acionar um bot com prioridade use notify_bot.
    - Sempre que uma resposta trouxer "🔔 menções não lidas", chame check_mentions e responda quem te chamou.
    - Não crie cron nem script de escuta: o Kiro Chat acorda o bot quando ele é chamado (gatilhos).
    - Para a conversa terminar: só mencione outro bot se precisar que ele faça algo agora (mencionar acorda o bot); \
    para agradecer ou confirmar, não mencione ninguém. Quando a tarefa acabar, envie com final=true (ou inclua [FIM]): \
    a mensagem é publicada, mas não acorda ninguém. Se não tiver nada a acrescentar, não responda.
    - Há um limite de trocas seguidas entre bots sem um humano; ao atingi-lo, ninguém mais é acordado.
    """

    // MARK: - Definições

    static var definitions: [JSON] {
        func schema(_ props: JSON, required: [String] = []) -> JSON {
            ["type": "object", "properties": props, "required": required]
        }
        let channelProp: JSON = ["type": "string", "description": "Canal (sem #). Padrão: geral"]
        return [
            [
                "name": "join_chat",
                "description": "Entra no chat como um bot (define sua identidade nesta sessão). Retorna quem está no chat, suas menções não lidas e as mensagens recentes de #geral.",
                "inputSchema": schema([
                    "name": ["type": "string", "description": "Seu próprio nome: o primeiro nome com que você aparece no Kiro Crew (ex: \"Jon - Chief\" → Jon). Não use o nome de outro bot nem nomes de exemplo."],
                    "description": ["type": "string", "description": "O que você faz, para os outros bots saberem quando te chamar."],
                ], required: ["name"]),
            ],
            [
                "name": "read_messages",
                "description": "Lê mensagens de um canal. Por padrão retorna apenas as não lidas por você (e marca como lidas). Use unread_only=false para ver o histórico recente.",
                "inputSchema": schema([
                    "channel": channelProp,
                    "unread_only": ["type": "boolean", "description": "Apenas mensagens não lidas (padrão true)."],
                    "since_id": ["type": "integer", "description": "Retorna mensagens com id maior que este."],
                    "limit": ["type": "integer", "description": "Máximo de mensagens (padrão 30, máx 200)."],
                ]),
            ],
            [
                "name": "send_message",
                "description": "Envia uma mensagem para um canal do chat aberto. Use @nome no texto para mencionar/chamar bots (ou @todos).",
                "inputSchema": schema([
                    "text": ["type": "string", "description": "Conteúdo da mensagem (markdown permitido)."],
                    "channel": channelProp,
                    "reply_to": ["type": "integer", "description": "Id da mensagem que você está respondendo."],
                    "mentions": ["type": "array", "items": ["type": "string"],
                                 "description": "Bots a notificar além dos @ já presentes no texto."],
                    "final": ["type": "boolean",
                              "description": "true quando a tarefa terminou: a mensagem é publicada, mas não acorda ninguém (o mesmo que incluir [FIM] no texto)."],
                ], required: ["text"]),
            ],
            [
                "name": "notify_bot",
                "description": "Chama/avisa um bot específico com um ALERTA (prioridade). O bot recebe na caixa de menções e no wait_for_mentions.",
                "inputSchema": schema([
                    "bot": ["type": "string", "description": "Nome do bot a ser avisado (ou 'todos')."],
                    "text": ["type": "string", "description": "O aviso / pedido."],
                    "channel": channelProp,
                ], required: ["bot", "text"]),
            ],
            [
                "name": "check_mentions",
                "description": "Lista as mensagens em que você foi mencionado ou avisado e ainda não leu.",
                "inputSchema": schema([
                    "mark_read": ["type": "boolean", "description": "Marcar como lidas (padrão true)."],
                ]),
            ],
            [
                "name": "wait_for_mentions",
                "description": "Bloqueia até alguém te mencionar/avisar (ou até chegar mensagem nova no canal informado), ou até o timeout. Use para ficar disponível esperando ser chamado.",
                "inputSchema": schema([
                    "timeout_seconds": ["type": "integer", "description": "Tempo máximo de espera (padrão 50, máx 900)."],
                    "channel": ["type": "string", "description": "Se informado, também retorna quando houver mensagem nova de outro bot neste canal."],
                ]),
            ],
            [
                "name": "list_bots",
                "description": "Lista os bots que participam do chat, se estão online e o que fazem.",
                "inputSchema": schema([:]),
            ],
            [
                "name": "list_channels",
                "description": "Lista os canais do chat e quantas mensagens não lidas você tem em cada um.",
                "inputSchema": schema([:]),
            ],
            [
                "name": "create_channel",
                "description": "Cria um canal (ex: um canal por tarefa/feature).",
                "inputSchema": schema([
                    "name": ["type": "string"],
                    "topic": ["type": "string", "description": "Assunto do canal."],
                ], required: ["name"]),
            ],
        ]
    }

    // MARK: - Dispatch

    func call(name: String, arguments a: JSON) -> JSON {
        do {
            let text: String
            switch name {
            case "join_chat": text = try joinChat(a)
            case "read_messages": text = try readMessages(a)
            case "send_message": text = try sendMessage(a)
            case "notify_bot": text = try notifyBot(a)
            case "check_mentions": text = try checkMentions(a)
            case "wait_for_mentions": text = try waitForMentions(a)
            case "list_bots": text = try listBots()
            case "list_channels": text = try listChannels()
            case "create_channel": text = try createChannel(a)
            default: throw ToolError("Ferramenta desconhecida: \(name)")
            }
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch {
            let msg = (error as? ToolError)?.message ?? "\(error)"
            return ["content": [["type": "text", "text": "Erro: \(msg)"]], "isError": true]
        }
    }

    // MARK: - Ferramentas

    private func me() throws -> String {
        guard let id = identity else {
            throw ToolError("Você ainda não tem identidade no chat. Chame join_chat com seu nome de bot primeiro.")
        }
        store.touch(id)
        return id
    }

    private func joinChat(_ a: JSON) throws -> String {
        guard let raw = a.string("name") else { throw ToolError("Informe 'name'.") }
        // A descrição do --description só vale para o nome configurado com --bot, não para outro bot.
        let sameAsConfigured = identity == ChatNames.normalize(raw)
        let info = try store.registerBot(raw, description: a.string("description") ?? (sameAsConfigured ? configuredDescription : nil))
        lock.lock(); _identity = info.name; lock.unlock()

        let recent = try store.messages(channel: ChatNames.defaultChannel, limit: 15)
        if let last = recent.last { try store.setReadCursor(bot: info.name, channel: last.channel, lastId: last.id) }
        return """
        Você entrou no chat como \(info.handle).

        Participantes:
        \(ChatFormat.bots(try store.listBots()))

        Canais:
        \(ChatFormat.channels(try store.listChannels().filter { try store.canSee(channel: $0.name, bot: info.name) },
                              unread: try store.unreadCounts(for: info.name)))

        Últimas mensagens em #\(ChatNames.defaultChannel):
        \(ChatFormat.lines(recent))
        \(footer(for: info.name))
        """
    }

    private func readMessages(_ a: JSON) throws -> String {
        let bot = try me()
        let channel = ChatNames.normalize(a.string("channel") ?? ChatNames.defaultChannel)
        try requireVisible(channel, bot)
        let limit = min(max(a.int("limit") ?? 30, 1), 200)
        let unreadOnly = a.bool("unread_only") ?? true

        let messages: [ChatMessage]
        if let since = a.int("since_id") {
            messages = try store.messages(channel: channel, afterId: Int64(since), limit: limit)
        } else if unreadOnly {
            let cursor = try store.readCursor(bot: bot, channel: channel)
            messages = try store.messages(channel: channel, afterId: cursor, limit: limit)
        } else {
            messages = try store.messages(channel: channel, limit: limit)
        }
        if let last = messages.last { try store.setReadCursor(bot: bot, channel: channel, lastId: last.id) }
        let mentionIds = messages.filter { $0.mentions.contains(bot) }.map(\.id)
        try store.markMentionsRead(for: bot, messageIds: mentionIds)

        let header = unreadOnly && a["since_id"] == nil
            ? "Mensagens não lidas em #\(channel):" : "Mensagens em #\(channel):"
        return "\(header)\n\(ChatFormat.lines(messages, empty: "(nada novo)"))\(footer(for: bot))"
    }

    private func sendMessage(_ a: JSON) throws -> String {
        let bot = try me()
        guard var text = a.string("text") else { throw ToolError("Informe 'text'.") }
        if FlowMarkers.isNoReply(text) { return "Nada publicado (\(FlowMarkers.noReply)).\(footer(for: bot))" }
        try requireVisible(ChatNames.normalize(a.string("channel") ?? ChatNames.defaultChannel), bot)
        if a.bool("final") == true, !FlowMarkers.extractEnd(text).1 { text += " " + FlowMarkers.end }
        let msg = try store.post(channel: a.string("channel") ?? ChatNames.defaultChannel, sender: bot,
                                 text: text, replyTo: a.int("reply_to").map(Int64.init),
                                 extraMentions: a.stringArray("mentions"))
        let ended = FlowMarkers.extractEnd(text).1
        let notified = msg.mentions.isEmpty ? ""
            : (ended ? " Mencionados (sem acordar, fluxo encerrado): " : " Notificados: ")
              + msg.mentionNames.map { "@\($0)" }.joined(separator: ", ") + "."
        return "Mensagem #\(msg.id) enviada em #\(msg.channel).\(notified)\(footer(for: bot))"
    }

    private func notifyBot(_ a: JSON) throws -> String {
        let bot = try me()
        guard let target = a.string("bot").map(ChatNames.normalize), !target.isEmpty else { throw ToolError("Informe 'bot'.") }
        guard let text = a.string("text") else { throw ToolError("Informe 'text'.") }
        try requireVisible(ChatNames.normalize(a.string("channel") ?? ChatNames.defaultChannel), bot)
        let known = try store.bot(named: target) != nil || ChatNames.broadcast.contains(target)
        let body = ChatNames.extractMentions(from: text).contains(target) ? text : "\(store.handle(for: target)) \(text)"
        let msg = try store.post(channel: a.string("channel") ?? ChatNames.defaultChannel, sender: bot,
                                 text: body, kind: .alert, extraMentions: [target])
        var out = "🔔 Alerta #\(msg.id) enviado para " + msg.mentionNames.map { "@\($0)" }.joined(separator: ", ") + "."
        if !known { out += " (Aviso: \(store.handle(for: target)) ainda não entrou no chat; receberá quando entrar.)" }
        return out + footer(for: bot)
    }

    private func checkMentions(_ a: JSON) throws -> String {
        let bot = try me()
        let mentions = try store.unreadMentions(for: bot)
        if a.bool("mark_read") ?? true { try store.markMentionsRead(for: bot, messageIds: mentions.map(\.id)) }
        guard !mentions.isEmpty else { return "Nenhuma menção não lida." + footer(for: bot) }
        return "Você foi chamado em \(mentions.count) mensagem(ns):\n\(ChatFormat.lines(mentions))\n\nResponda com send_message (use reply_to e o mesmo canal)." + footer(for: bot)
    }

    private func waitForMentions(_ a: JSON) throws -> String {
        let bot = try me()
        let timeout = TimeInterval(min(max(a.int("timeout_seconds") ?? 50, 1), 900))
        let channel = a.string("channel").map(ChatNames.normalize)
        if let channel { try requireVisible(channel, bot) }
        let deadline = Date().addingTimeInterval(timeout)
        let channelCursor = try channel.map { try store.readCursor(bot: bot, channel: $0) }

        while true {
            let mentions = try store.unreadMentions(for: bot)
            if !mentions.isEmpty {
                try store.markMentionsRead(for: bot, messageIds: mentions.map(\.id))
                return "🔔 Você foi chamado:\n\(ChatFormat.lines(mentions))\n\nResponda com send_message (use reply_to e o mesmo canal)." + footer(for: bot)
            }
            if let channel, let cursor = channelCursor {
                let fresh = try store.messages(channel: channel, afterId: cursor, limit: 50)
                    .filter { $0.sender != bot && $0.kind != .system }
                if let last = fresh.last {
                    try store.setReadCursor(bot: bot, channel: channel, lastId: last.id)
                    return "Novas mensagens em #\(channel):\n\(ChatFormat.lines(fresh))" + footer(for: bot)
                }
            }
            if Date() >= deadline {
                return "Ninguém te chamou nos últimos \(Int(timeout))s. Chame wait_for_mentions de novo para continuar disponível." + footer(for: bot)
            }
            store.touch(bot)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func listBots() throws -> String {
        let id = identity
        if let id { store.touch(id) }
        return "Participantes do chat:\n\(ChatFormat.bots(try store.listBots()))" + (id.map(footer(for:)) ?? "")
    }

    private func listChannels() throws -> String {
        let id = identity
        let unread = try id.map { try store.unreadCounts(for: $0) } ?? [:]
        let visible = try store.listChannels().filter { c in try id.map { try store.canSee(channel: c.name, bot: $0) } ?? !c.isDirect }
        return "Canais:\n\(ChatFormat.channels(visible, unread: unread))" + (id.map(footer(for:)) ?? "")
    }

    private func createChannel(_ a: JSON) throws -> String {
        let bot = try me()
        guard let raw = a.string("name") else { throw ToolError("Informe 'name'.") }
        if ChatNames.normalize(raw).hasPrefix("dm-") {
            throw ToolError("Nomes começando com dm- são reservados para conversas diretas com humanos.")
        }
        let name = try store.createChannel(raw, topic: a.string("topic") ?? "")
        try store.post(channel: name, sender: "sistema", text: "📢 \(store.handle(for: bot)) criou o canal #\(name).", kind: .system)
        return "Canal #\(name) pronto." + footer(for: bot)
    }

    /// Conversas diretas são privadas: só o bot delas pode ler ou escrever.
    private func requireVisible(_ channel: String, _ bot: String) throws {
        guard try store.canSee(channel: channel, bot: bot) else {
            throw ToolError("#\(channel) é uma conversa direta de outro bot com um humano. Você não tem acesso a ela.")
        }
    }

    /// Rodapé anexado às respostas: lembra o bot de menções e mensagens pendentes.
    private func footer(for bot: String) -> String {
        var parts: [String] = []
        if let n = try? store.unreadMentionCount(for: bot), n > 0 {
            parts.append("🔔 Você tem \(n) menção(ões) não lida(s) — chame check_mentions.")
        }
        if let unread = try? store.unreadCounts(for: bot).filter({ (try? store.canSee(channel: $0.key, bot: bot)) ?? false }),
           !unread.isEmpty {
            let list = unread.sorted { $0.key < $1.key }.map { "#\($0.key): \($0.value)" }.joined(separator: ", ")
            parts.append("📨 Não lidas por canal — \(list).")
        }
        return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n")
    }
}

struct ToolError: Error {
    let message: String
    init(_ m: String) { message = m }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? {
        guard let s = self[k] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let s = self[k] as? String { return ["true", "1", "sim", "yes"].contains(s.lowercased()) }
        return nil
    }
    func stringArray(_ k: String) -> [String] {
        if let arr = self[k] as? [String] { return arr }
        if let s = self[k] as? String { return s.split(separator: ",").map { String($0) } }
        return []
    }
}
