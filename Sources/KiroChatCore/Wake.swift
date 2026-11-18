import Foundation
import SQLite3

// MARK: - Modelo

/// Gatilho que "acorda" um bot quando ele é mencionado no chat.
/// O chat faz a escuta (sem modelo, sem tokens) e só dispara o comando/webhook quando há menção.
public struct WakeTrigger: Codable, Hashable, Sendable {
    /// Espera padrão antes de acordar o bot (dá tempo de um bot já ativo pegar a menção sozinho).
    public static let defaultDelay: Double = 3

    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Roda um comando no shell (ex: `kiro-cli chat --agent jon "$KIRO_CHAT_PROMPT"`).
        case command
        /// Faz um POST JSON para uma URL.
        case webhook
    }

    public var bot: String
    public var kind: Kind
    public var command: String
    public var url: String
    /// Espera antes de acordar: dá tempo de um bot que já está em `wait_for_mentions` pegar a menção.
    public var delaySeconds: Double
    /// Proteção contra loops (bot A chama B que chama A...).
    public var maxPerHour: Int
    public var enabled: Bool
    /// Publica o que o comando imprimir (stdout) no chat como resposta do bot.
    /// Assim o bot não precisa de ferramentas para responder (ex: `kirocrew chat -m`).
    public var postReply: Bool
    /// Modo híbrido (Bots do Kiro Crew): responde pelo modo rápido e, se o bot pedir [EXECUTAR],
    /// chama de novo pelo `kirocrew spawn` para ele executar com as ferramentas do Kiro Crew.
    public var escalate: Bool

    public init(bot: String, kind: Kind = .command, command: String = "", url: String = "",
                delaySeconds: Double = WakeTrigger.defaultDelay, maxPerHour: Int = 30, enabled: Bool = true,
                postReply: Bool = false, escalate: Bool = false) {
        self.bot = ChatNames.normalize(bot)
        self.kind = kind
        self.command = command
        self.url = url
        self.delaySeconds = delaySeconds
        self.maxPerHour = maxPerHour
        self.enabled = enabled
        self.postReply = postReply
        self.escalate = escalate
    }

    public var isConfigured: Bool {
        switch kind {
        case .command: return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .webhook: return URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
        }
    }
}

public struct WakeLogEntry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let bot: String
    public let startedAt: Date
    public let finishedAt: Date?
    /// "exit 0", "HTTP 200", "erro: ...", ou vazio enquanto roda.
    public let status: String
    public let output: String
    public let messageIds: [Int64]
    public let isTest: Bool

    public var succeeded: Bool { status == "exit 0" || status.hasPrefix("HTTP 2") }

    /// Status enquanto o `kirocrew spawn` espera aprovação no painel do Kiro Crew.
    public static let awaitingApproval = "aguardando aprovação no Kiro Crew"
    public var isAwaitingApproval: Bool { finishedAt == nil && status == Self.awaitingApproval }
    /// Status enquanto o modo híbrido executa a ação pelo Kiro Crew.
    public static let executing = "executando pelo Kiro Crew"
}

// MARK: - Armazenamento

extension ChatStore {
    func migrateWake() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS triggers (
            bot TEXT PRIMARY KEY,
            kind TEXT NOT NULL DEFAULT 'command',
            command TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            delay_seconds REAL NOT NULL DEFAULT 3,
            max_per_hour INTEGER NOT NULL DEFAULT 30,
            enabled INTEGER NOT NULL DEFAULT 1,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS wake_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bot TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL DEFAULT '',
            output TEXT NOT NULL DEFAULT '',
            message_ids TEXT NOT NULL DEFAULT '',
            is_test INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_wake_log_bot ON wake_log(bot, started_at);
        """)
        let cols = try query("PRAGMA table_info(mentions)", []) { Self.text($0, 1) }
        if !cols.contains("dispatched_at") {
            try exec("ALTER TABLE mentions ADD COLUMN dispatched_at REAL;")
        }
        let tcols = try query("PRAGMA table_info(triggers)", []) { Self.text($0, 1) }
        if !tcols.contains("post_reply") {
            try exec("ALTER TABLE triggers ADD COLUMN post_reply INTEGER NOT NULL DEFAULT 0;")
        }
        if !tcols.contains("escalate") {
            try exec("ALTER TABLE triggers ADD COLUMN escalate INTEGER NOT NULL DEFAULT 0;")
        }
    }

    private static let triggerColumns = "bot, kind, command, url, delay_seconds, max_per_hour, enabled, post_reply, escalate"

    private static func mapTrigger(_ s: OpaquePointer) -> WakeTrigger {
        WakeTrigger(bot: text(s, 0), kind: WakeTrigger.Kind(rawValue: text(s, 1)) ?? .command,
                    command: text(s, 2), url: text(s, 3), delaySeconds: sqlite3_column_double(s, 4),
                    maxPerHour: Int(sqlite3_column_int64(s, 5)), enabled: sqlite3_column_int(s, 6) != 0,
                    postReply: sqlite3_column_int(s, 7) != 0, escalate: sqlite3_column_int(s, 8) != 0)
    }

    public func trigger(for bot: String) throws -> WakeTrigger? {
        try query("SELECT \(Self.triggerColumns) FROM triggers WHERE bot = ?",
                  [.text(ChatNames.normalize(bot))], map: Self.mapTrigger).first
    }

    public func listTriggers() throws -> [WakeTrigger] {
        try query("SELECT \(Self.triggerColumns) FROM triggers ORDER BY bot", [], map: Self.mapTrigger)
    }

    public func saveTrigger(_ t: WakeTrigger) throws {
        guard !t.bot.isEmpty else { throw ChatStoreError.invalid("Gatilho sem bot.") }
        try run("""
        INSERT INTO triggers(bot, kind, command, url, delay_seconds, max_per_hour, enabled, updated_at, post_reply, escalate)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bot) DO UPDATE SET kind = excluded.kind, command = excluded.command, url = excluded.url,
            delay_seconds = excluded.delay_seconds, max_per_hour = excluded.max_per_hour,
            enabled = excluded.enabled, updated_at = excluded.updated_at, post_reply = excluded.post_reply,
            escalate = excluded.escalate
        """, [.text(t.bot), .text(t.kind.rawValue), .text(t.command), .text(t.url),
              .double(max(0, t.delaySeconds)), .int(Int64(max(1, t.maxPerHour))), .int(t.enabled ? 1 : 0),
              .double(Date().timeIntervalSince1970), .int(t.postReply ? 1 : 0), .int(t.escalate ? 1 : 0)])
        // Menções antigas não disparam um gatilho recém-criado.
        try run("UPDATE mentions SET dispatched_at = ? WHERE bot = ? AND dispatched_at IS NULL",
                [.double(Date().timeIntervalSince1970), .text(t.bot)])
    }

    public func deleteTrigger(bot: String) throws {
        try run("DELETE FROM triggers WHERE bot = ?", [.text(ChatNames.normalize(bot))])
    }

    /// Reserva (atomicamente, entre processos) as menções que devem acordar cada bot.
    /// Só pega menções não lidas, ainda não despachadas e mais velhas que o `delay` do gatilho.
    ///
    /// Com os bots parados (pausa geral), descarta as menções pendentes e não acorda ninguém.
    /// Menções de mensagens que chegaram ao limite de trocas entre bots também não acordam: o chat avisa uma vez.
    /// Mensagens de canal aberto (menções implícitas) acordam todos os bots que escutam ao mesmo tempo, como num chat.
    public func claimPendingWakes(excluding busy: Set<String> = [], now: Date = Date()) throws -> [(WakeTrigger, [ChatMessage])] {
        var blocked: [(bot: String, message: ChatMessage)] = []
        let result: [(WakeTrigger, [ChatMessage])] = try transaction {
            if wakePaused {
                try run("UPDATE mentions SET dispatched_at = ? WHERE dispatched_at IS NULL", [.double(now.timeIntervalSince1970)])
                return []
            }
            let maxHops = maxBotHops
            var result: [(WakeTrigger, [ChatMessage])] = []
            for t in try listTriggers() where t.enabled && t.isConfigured && !busy.contains(t.bot) {
                if try wakeCount(bot: t.bot, since: now.addingTimeInterval(-3600)) >= t.maxPerHour { continue }
                let rows = try query("""
                SELECT n.message_id FROM mentions n JOIN messages m ON m.id = n.message_id
                WHERE n.bot = ? AND n.read_at IS NULL AND n.dispatched_at IS NULL AND m.created_at <= ?
                ORDER BY n.message_id
                """, [.text(t.bot), .double(now.timeIntervalSince1970 - t.delaySeconds)]) {
                    sqlite3_column_int64($0, 0)
                }
                guard !rows.isEmpty else { continue }
                let ids = rows
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try run("UPDATE mentions SET dispatched_at = ? WHERE bot = ? AND message_id IN (\(placeholders))",
                        [.double(now.timeIntervalSince1970), .text(t.bot)] + ids.map { .int($0) })
                let messages = try ids.compactMap { try message(id: $0) }
                let allowed = messages.filter { $0.hop < maxHops }
                if allowed.isEmpty, let last = messages.last {
                    blocked.append((t.bot, last))
                } else if !allowed.isEmpty {
                    result.append((t, allowed))
                }
            }
            return result
        }
        for b in blocked {
            _ = try? post(channel: b.message.channel, sender: "sistema", text: """
            ⏸ \(handle(for: b.bot)) não foi acordado: os bots já trocaram \(b.message.hop) mensagens seguidas sem um humano \
            (limite: \(maxBotHops)). Para continuar, mencione um bot.
            """, kind: .system, replyTo: b.message.id)
        }
        return result
    }

    public func wakeCount(bot: String, since: Date) throws -> Int {
        try query("SELECT COUNT(*) FROM wake_log WHERE bot = ? AND is_test = 0 AND started_at >= ?",
                  [.text(ChatNames.normalize(bot)), .double(since.timeIntervalSince1970)]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    public func startWakeLog(bot: String, messageIds: [Int64], isTest: Bool) throws -> Int64 {
        try run("INSERT INTO wake_log(bot, started_at, message_ids, is_test) VALUES (?, ?, ?, ?)",
                [.text(ChatNames.normalize(bot)), .double(Date().timeIntervalSince1970),
                 .text(messageIds.map(String.init).joined(separator: ",")), .int(isTest ? 1 : 0)])
        return try query("SELECT last_insert_rowid()", []) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    /// Status de um disparo que ainda está rodando (ex: esperando aprovação).
    public func setRunningWakeStatus(id: Int64, status: String) throws {
        try run("UPDATE wake_log SET status = ? WHERE id = ? AND finished_at IS NULL", [.text(status), .int(id)])
    }

    public func finishWakeLog(id: Int64, status: String, output: String) throws {
        try run("UPDATE wake_log SET finished_at = ?, status = ?, output = ? WHERE id = ?",
                [.double(Date().timeIntervalSince1970), .text(status), .text(output), .int(id)])
    }

    public func wakeLogs(bot: String? = nil, limit: Int = 20) throws -> [WakeLogEntry] {
        let whereSQL = bot == nil ? "" : "WHERE bot = ?"
        let binds: [Value] = (bot.map { [.text(ChatNames.normalize($0))] } ?? []) + [.int(Int64(limit))]
        return try query("""
        SELECT id, bot, started_at, finished_at, status, output, message_ids, is_test
        FROM wake_log \(whereSQL) ORDER BY id DESC LIMIT ?
        """, binds) { s in
            WakeLogEntry(id: sqlite3_column_int64(s, 0), bot: Self.text(s, 1),
                         startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                         finishedAt: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil
                            : Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                         status: Self.text(s, 4), output: Self.text(s, 5),
                         messageIds: Self.text(s, 6).split(separator: ",").compactMap { Int64($0) },
                         isTest: sqlite3_column_int(s, 7) != 0)
        }
    }
}

// MARK: - Prompt / variáveis

public enum WakeContext {
    /// Etapa do modo híbrido em que o bot está.
    public enum Stage: Equatable, Sendable {
        /// Resposta normal.
        case reply
        /// Modo rápido do híbrido: responde conversando, ou pede [EXECUTAR] se precisar agir.
        case triage
        /// Rodando pelo Kiro Crew para executar a ação que o bot pediu.
        case execute(String)

        var instructions: String {
            switch self {
            case .reply:
                return ""
            case .triage:
                return """


                Você está no modo rápido: aqui dá para conversar, explicar e responder com o que você já sabe, mas não \
                para executar nada. Se, para atender, você precisar EXECUTAR algo (rodar comandos, build ou testes, criar \
                ou alterar arquivos, abrir tarefas, consultar sistemas com suas ferramentas), não tente agora: responda só com uma linha
                \(FlowMarkers.execute) <o que você vai fazer, em poucas palavras>
                e o Kiro Chat vai te chamar de novo pelo Kiro Crew, com suas ferramentas, para executar (pode precisar da \
                aprovação de um humano). Se dá para responder sem executar nada, responda direto.
                """
            case .execute(let action):
                return """


                Você está rodando pelo Kiro Crew, com suas ferramentas, porque decidiu que precisa executar: \(action)
                Execute agora de fato e responda com o resultado: o que fez, o que mudou e o que ficou pendente. \
                Não responda \(FlowMarkers.execute) de novo.
                """
            }
        }
    }

    /// Texto pronto para entregar ao bot acordado.
    /// `profile`: perfil do Bot no Kiro Crew (papel, objetivos...), que vai no começo do prompt.
    public static func prompt(botName: String, messages: [ChatMessage], postReply: Bool = false,
                              maxHops: Int = ChatStore.defaultMaxBotHops, context: [ChatMessage] = [],
                              profile: KiroCrew.Profile? = nil, stage: Stage = .reply) -> String {
        let intro = profile.flatMap { $0.isEmpty ? nil : $0.promptSection + "\n\n" } ?? ""
        var header: String
        if context.isEmpty {
            header = """
            Você (@\(botName)) foi chamado no Kiro Chat, o chat aberto entre os bots do Kiro Crew:

            \(ChatFormat.lines(messages))
            """
        } else {
            // Conversa recente + menções que não estejam nela (ex: de outro canal, ou de teste).
            let called = Set(messages.map(\.id))
            let key = ChatNames.normalize(botName)
            let openOnly = messages.allSatisfy { !$0.mentions.contains(key) }
            let inContext = Set(context.map(\.id))
            let all = context + messages.filter { !inContext.contains($0.id) }
            let lines = all.map { m -> String in
                let text = called.contains(m.id) || m.text.count <= 1500 ? m.text : String(m.text.prefix(1500)) + " …(cortado)"
                let line = ChatFormat.line(ChatMessage(id: m.id, channel: m.channel, sender: m.sender, senderName: m.senderName,
                                                       text: text, kind: m.kind, replyTo: m.replyTo, createdAt: m.createdAt,
                                                       mentions: m.mentions, mentionNames: m.mentionNames, hop: m.hop))
                guard called.contains(m.id) else { return line }
                return line + (m.mentions.contains(key) ? "\n    ◀ VOCÊ FOI CHAMADO AQUI" : "\n    ◀ MENSAGEM PARA TODOS NO CANAL")
            }.joined(separator: "\n")
            header = """
            Você (@\(botName)) foi chamado no Kiro Chat, o chat aberto entre os bots do Kiro Crew. \
            Conversa recente, da mais antiga para a mais nova (inclui o que você mesmo já disse):

            \(lines)

            Responda à(s) mensagem(ns) marcada(s) com ◀, levando em conta o que já foi dito. \
            Não repita o que você ou outro bot já respondeu; se já foi respondido, responda \(FlowMarkers.noReply).
            """ + (openOnly ? """


            Essa mensagem foi escrita no canal aberto, onde todos os bots escutam, sem mencionar ninguém. \
            Todos os bots recebem esta mensagem ao mesmo tempo e cada um responde por si. Decida assim:
            - Se ela pede algo de TODOS ou de cada um (cumprimentar, dizer se está aí ou escutando, dar seu status, \
            sua opinião, se apresentar), responda você também. Seja breve e fale por você.
            - Se ela é sobre um assunto ou tarefa específica, responda só se for da sua área ou se tiver algo útil a dizer; \
            se não for com você, responda \(FlowMarkers.noReply).
            - Na dúvida sobre se a pergunta é para todos, responda brevemente.
            """ : "")
        }
        header = intro + header
        let hop = (messages.map(\.hop).max() ?? 0) + 1
        let left = maxHops - hop
        let rules = """


        Regras para a conversa terminar:
        - Só mencione outro bot (@nome) se precisar que ele faça algo agora. Mencionar acorda o bot. \
        Para agradecer, concordar ou confirmar, não mencione ninguém.
        - Se não tiver nada útil a acrescentar, responda exatamente \(FlowMarkers.noReply) (nada será publicado). \
        Mas se o humano pediu uma resposta de cada um, responda.
        - Quando a tarefa estiver concluída, ou se ela não deve continuar, inclua \(FlowMarkers.end) na resposta: \
        ela é publicada, mas não acorda mais ninguém.
        - Esta é a troca \(hop) de no máximo \(maxHops) entre bots sem um humano\(left <= 1 ? ". É a última: encerre com \(FlowMarkers.end) e resuma o que ficou pendente." : ".")
        """
        if postReply {
            let channel = messages.last?.channel ?? ChatNames.defaultChannel
            return header + """


            Sua resposta final será publicada automaticamente em #\(channel) como mensagem sua, em resposta a quem te chamou. \
            Escreva só o texto dessa mensagem, direto ao ponto. Não use ferramentas para enviar a resposta.
            """ + stage.instructions + "\n\n" + Markdown.botHint + rules
        }
        return header + """


        Use as ferramentas do MCP kiro-chat: se ainda não tiver identidade, chame join_chat com o nome "\(botName)". \
        Leia o contexto com read_messages no canal da mensagem e responda com send_message no mesmo canal, \
        usando reply_to com o id da mensagem.
        """ + "\n\n" + Markdown.botHint + rules
    }

    /// O prompt, encurtado até caber em `maxLength` caracteres: corta primeiro a conversa mais antiga,
    /// depois o briefing e, em último caso, o meio do texto (mantendo o começo e as instruções do fim).
    public static func fittedPrompt(botName: String, messages: [ChatMessage], postReply: Bool = false,
                                    maxHops: Int = ChatStore.defaultMaxBotHops, context: [ChatMessage] = [],
                                    profile: KiroCrew.Profile? = nil, stage: Stage = .reply, maxLength: Int) -> String {
        var ctx = context
        var prof = profile
        func build() -> String {
            prompt(botName: botName, messages: messages, postReply: postReply, maxHops: maxHops,
                   context: ctx, profile: prof, stage: stage)
        }
        var p = build()
        while p.unicodeScalars.count > maxLength {
            if ctx.count > 2 { ctx = Array(ctx.suffix(ctx.count / 2)) }
            else if !ctx.isEmpty { ctx = [] }
            else if let pr = prof, pr.briefing.count > 300 { prof = pr.shorteningBriefing(to: 300) }
            else { break }
            p = build()
        }
        let scalars = Array(p.unicodeScalars)
        guard scalars.count > maxLength else { return p }
        let marker = "\n…(cortado)…\n"
        let room = maxLength - marker.unicodeScalars.count
        let head = room * 2 / 5, tail = room - head
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(head))
        out.append(contentsOf: marker.unicodeScalars)
        out.append(contentsOf: scalars.suffix(tail))
        return String(out)
    }

    /// Variáveis de ambiente passadas ao comando. O texto das mensagens só chega por aqui,
    /// nunca é colado dentro do comando (evita injeção de shell).
    public static func environment(botKey: String, botName: String, messages: [ChatMessage],
                                   databasePath: String, postReply: Bool = false,
                                   maxHops: Int = ChatStore.defaultMaxBotHops,
                                   context: [ChatMessage] = [], profile: KiroCrew.Profile? = nil,
                                   stage: Stage = .reply, maxLength: Int? = nil) -> [String: String] {
        let last = messages.last
        return [
            "KIRO_CHAT_BOT": botName,
            "KIRO_CHAT_BOT_KEY": botKey,
            "KIRO_CHAT_PROMPT": maxLength.map {
                fittedPrompt(botName: botName, messages: messages, postReply: postReply, maxHops: maxHops,
                             context: context, profile: profile, stage: stage, maxLength: $0)
            } ?? prompt(botName: botName, messages: messages, postReply: postReply,
                        maxHops: maxHops, context: context, profile: profile, stage: stage),
            "KIRO_CHAT_HOP": String((messages.map(\.hop).max() ?? 0) + 1),
            "KIRO_CHAT_FROM": last?.senderName ?? "",
            "KIRO_CHAT_CHANNEL": last?.channel ?? ChatNames.defaultChannel,
            "KIRO_CHAT_TEXT": last?.text ?? "",
            "KIRO_CHAT_MESSAGE_ID": last.map { String($0.id) } ?? "",
            "KIRO_CHAT_MESSAGE_IDS": messages.map { String($0.id) }.joined(separator: ","),
            "KIRO_CHAT_COUNT": String(messages.count),
            "KIRO_CHAT_DB": databasePath,
        ]
    }

    public static func webhookBody(botKey: String, botName: String, messages: [ChatMessage],
                                   maxHops: Int = ChatStore.defaultMaxBotHops, context: [ChatMessage] = []) -> Data {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "bot": botKey,
            "botName": botName,
            "prompt": prompt(botName: botName, messages: messages, maxHops: maxHops, context: context),
            "messages": messages.map { m in
                [
                    "id": m.id, "channel": m.channel, "from": m.senderName, "fromKey": m.sender,
                    "text": m.text, "kind": m.kind.rawValue, "replyTo": m.replyTo as Any,
                    "createdAt": iso.string(from: m.createdAt),
                ] as [String: Any]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }
}

// MARK: - Despachante

/// Observa o chat e dispara o gatilho do bot quando ele é mencionado.
/// Pode rodar dentro do app ou como processo em segundo plano (`kiro-chat-mcp dispatch`).
/// Vários despachantes ao mesmo tempo não disparam em dobro: a reserva das menções é atômica.
public final class WakeDispatcher: @unchecked Sendable {
    private let store: ChatStore
    private let queue = DispatchQueue(label: "kiro-chat.wake")
    private var timer: DispatchSourceTimer?
    private var running = Set<String>()
    /// Processos dos gatilhos em execução, por bot (para "Parar bots" interromper).
    private var processes: [String: Process] = [:]
    private let log: @Sendable (String) -> Void
    private static let maxOutput = 8_000
    /// Comando que executa a ação de um Bot do Kiro Crew no modo híbrido (trocado nos testes).
    var spawnCommand: @Sendable (String) -> String = { key in
        KiroCrew.command(for: KiroCrew.Bot(key: key, displayName: "", description: ""), mode: .spawn)
    }

    public init(store: ChatStore, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.log = log
    }

    public func start(interval: TimeInterval = 1.0) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Dispara o gatilho com uma mensagem de teste (não conta para o limite por hora).
    public func test(bot: String, from sender: String) {
        queue.async {
            guard let t = try? self.store.trigger(for: bot), t.isConfigured else {
                self.log("teste: @\(bot) não tem gatilho configurado")
                return
            }
            let fake = ChatMessage(id: 0, channel: ChatNames.defaultChannel, sender: ChatNames.normalize(sender),
                                   senderName: self.store.displayName(for: sender),
                                   text: "\(self.store.handle(for: bot)) isto é um teste do gatilho de chamada.",
                                   kind: .message, replyTo: nil, createdAt: Date(), mentions: [t.bot])
            self.fire(t, messages: [fake], isTest: true)
        }
    }

    private func tick() {
        if store.wakePaused {
            interruptRunning()
            return
        }
        do {
            for (t, messages) in try store.claimPendingWakes(excluding: running) where !messages.isEmpty {
                fire(t, messages: messages, isTest: false)
            }
        } catch {
            log("erro ao verificar menções: \(error)")
        }
    }

    private func fire(_ t: WakeTrigger, messages: [ChatMessage], isTest: Bool) {
        running.insert(t.bot)
        let name = store.displayName(for: t.bot)
        let logId = (try? store.startWakeLog(bot: t.bot, messageIds: messages.map(\.id), isTest: isTest)) ?? 0
        log("acordando @\(name) (\(messages.count) menção(ões)\(isTest ? ", teste" : ""))")

        let finish: @Sendable (String, String) -> Void = { status, output in
            self.queue.async {
                try? self.store.finishWakeLog(id: logId, status: status, output: output)
                self.running.remove(t.bot)
                self.log("@\(name): \(status)")
            }
        }

        // Conversa recente do canal, para o bot responder no contexto e não repetir o que já foi dito.
        let context = isTest ? ((try? store.messages(channel: messages.last?.channel, limit: 20)) ?? [])
                             : ((try? store.conversationContext(for: messages)) ?? [])

        switch t.kind {
        case .command:
            // Bot do Kiro Crew: lê o perfil dele agora (pega o que mudou no Kiro Crew) e roda na pasta dele.
            let crewKey = KiroCrew.agentKey(inCommand: t.command)
            let profile = crewKey.flatMap { KiroCrew.profile(forAgent: $0) }
            // Híbrido: primeiro a resposta rápida; se o bot pedir [EXECUTAR], roda de novo pelo Kiro Crew.
            let hybrid = t.escalate && t.postReply && crewKey != nil && KiroCrew.mode(ofCommand: t.command) == .chat
            // O `kirocrew spawn` recusa tarefas longas: nele o prompt é encurtado até caber (com folga).
            let spawnLimit = KiroCrew.spawnTaskLimit - 200
            let environment: @Sendable (WakeContext.Stage, Bool) -> [String: String] = { stage, viaSpawn in
                WakeContext.environment(botKey: t.bot, botName: name, messages: messages,
                                        databasePath: self.store.url.path, postReply: t.postReply,
                                        maxHops: self.store.maxBotHops, context: context, profile: profile,
                                        stage: stage, maxLength: viaSpawn ? spawnLimit : nil)
            }
            let env = environment(hybrid ? .triage : .reply, KiroCrew.mode(ofCommand: t.command) == .spawn)
            let waiting = Flag()
            let onStderr: @Sendable (String) -> Void = { chunk in
                guard chunk.contains(KiroCrew.approvalWaitMarker), waiting.setOnce() else { return }
                self.queue.async {
                    try? self.store.setRunningWakeStatus(id: logId, status: WakeLogEntry.awaitingApproval)
                    self.log("@\(name): aguardando aprovação no painel do Kiro Crew (Approvals)")
                }
            }
            let complete: @Sendable (String, String, String) -> Void = { status, output, reply in
                self.queue.async { self.processes[t.bot] = nil }
                var note = ""
                if self.store.wakePaused, !isTest {
                    note = "(bots parados: a resposta não foi publicada)"
                } else if t.postReply, status == "exit 0" {
                    note = self.publishReply(reply, from: t.bot, to: messages, isTest: isTest)
                }
                finish(status, note.isEmpty ? output : note + "\n" + output)
            }
            let process = runCommand(t.command, env: env, directory: profile?.workspace, onStderr: onStderr) { status, output, reply in
                guard hybrid, let key = crewKey, status == "exit 0", isTest || !self.store.wakePaused,
                      let action = FlowMarkers.actionRequest(in: Self.cleanReply(reply)) else {
                    complete(status, output, reply)
                    return
                }
                // O bot pediu para executar: chama de novo pelo Kiro Crew, com as ferramentas dele.
                self.queue.async {
                    try? self.store.setRunningWakeStatus(id: logId, status: WakeLogEntry.executing)
                    self.log("@\(name): executando pelo Kiro Crew — \(action)")
                    let first = "── resposta rápida ──\n" + output + "\n── execução pelo Kiro Crew ──\n"
                    let second = self.runCommand(self.spawnCommand(key), env: environment(.execute(action), true),
                                                 directory: profile?.workspace, onStderr: onStderr) { status2, output2, reply2 in
                        if status2 != "exit 0", !isTest { self.reportFailedAction(bot: t.bot, action: action, status: status2,
                                                                               output: output2, to: messages) }
                        complete(status2, first + output2, reply2)
                    }
                    if let second { self.processes[t.bot] = second }
                }
            }
            if let process { processes[t.bot] = process }
        case .webhook:
            post(t.url, body: WakeContext.webhookBody(botKey: t.bot, botName: name, messages: messages,
                                                      maxHops: store.maxBotHops, context: context),
                 completion: finish)
        }
    }

    /// Avisa no chat que a ação pedida no modo híbrido não rodou (recusada no Kiro Crew, erro...).
    private func reportFailedAction(bot: String, action: String, status: String, output: String, to messages: [ChatMessage]) {
        guard let last = messages.last else { return }
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let error = lines.last { $0.hasPrefix("Error:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let why: String
        switch error {
        case let e? where e.lowercased().contains("rejected"): why = "a execução foi recusada no Kiro Crew"
        case let e?: why = "erro do Kiro Crew: \(e)"
        case nil: why = "o comando terminou com \(status)"
        }
        _ = try? store.post(channel: last.channel, sender: "sistema", text: """
        ⚠️ \(store.handle(for: bot)) ia executar pelo Kiro Crew: \(action)
        Não rodou: \(why). Detalhes em Gatilho de chamada → Últimos disparos.
        """, kind: .system, replyTo: last.id)
    }

    /// Publica a resposta do bot no canal da última menção, em resposta a ela, e dá as menções como lidas.
    private func publishReply(_ raw: String, from bot: String, to messages: [ChatMessage], isTest: Bool) -> String {
        let reply = FlowMarkers.stripNoReply(Self.cleanReply(raw))
        guard !reply.isEmpty else { return "(o comando não imprimiu resposta; nada publicado)" }
        let footer = "\n\n── saída completa do comando ──"
        if FlowMarkers.isNoReply(reply) {
            if !isTest { try? store.markMentionsRead(for: bot, messageIds: messages.map(\.id)) }
            return "O bot não tinha nada a acrescentar (\(FlowMarkers.noReply)); nada publicado." + footer
        }
        guard !isTest, let last = messages.last else {
            return "Resposta (teste, não publicada no chat):\n\(reply)" + footer
        }
        do {
            let hop = (messages.map(\.hop).max() ?? 0) + 1
            let m = try store.post(channel: last.channel, sender: bot, text: reply, replyTo: last.id, hop: hop)
            try store.markMentionsRead(for: bot, messageIds: messages.map(\.id))
            return "Resposta publicada como #\(m.id) em #\(m.channel):\n\(reply)" + footer
        } catch {
            return "(erro ao publicar a resposta: \(error))"
        }
    }

    /// Linha de log de CLI (ex: "16:46:13 WARNING kiro_crew.config.loader: ..."), que não faz parte da resposta.
    private static let logLine = try! NSRegularExpression(
        pattern: "^\\s*(\\d{4}-\\d{2}-\\d{2}[ T])?\\d{2}:\\d{2}:\\d{2}([.,]\\d+)?\\s+(DEBUG|INFO|WARNING|WARN|ERROR|CRITICAL)\\s+[\\w.\\-]+:")

    /// Tira códigos de cor do terminal e linhas de log do CLI, e limita o tamanho.
    static func cleanReply(_ s: String) -> String {
        let noAnsi = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lines = noAnsi.components(separatedBy: "\n").filter { line in
            logLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
        }
        let trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 8000 ? String(trimmed.prefix(8000)) + "\n…(resposta cortada)" : trimmed
    }

    /// Roda o comando. `completion` recebe status, saída combinada (log) e só o stdout (resposta).
    /// Interrompe os gatilhos em execução (o shell e o que ele iniciou, como o `kirocrew`).
    private func interruptRunning() {
        for (bot, p) in processes where p.isRunning {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-P", String(p.processIdentifier)]
            try? pkill.run()
            pkill.waitUntilExit()
            p.terminate()
            log("@\(store.displayName(for: bot)): interrompido (bots parados)")
        }
        processes.removeAll()
    }

    @discardableResult
    private func runCommand(_ command: String, env: [String: String], directory: URL? = nil,
                            onStderr: (@Sendable (String) -> Void)? = nil,
                            completion: @escaping @Sendable (String, String, String) -> Void) -> Process? {
        let process = Process()
        // Shell de login: carrega o PATH do usuário (Homebrew, kiro-cli...) mesmo rodando pelo launchd.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let combined = OutputBuffer(limit: Self.maxOutput)
        let stdout = OutputBuffer(limit: 64_000)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            combined.append(d); stdout.append(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            combined.append(d)
            if let onStderr, !d.isEmpty { onStderr(String(decoding: d, as: UTF8.self)) }
        }
        process.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            combined.append(restOut); stdout.append(restOut)
            combined.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            let status = p.terminationReason == .uncaughtSignal ? "sinal \(p.terminationStatus)" : "exit \(p.terminationStatus)"
            completion(status, combined.string, stdout.string)
        }
        do {
            try process.run()
            return process
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            completion("erro: \(error.localizedDescription)", "", "")
            return nil
        }
    }

    private func post(_ urlString: String, body: Data, completion: @escaping @Sendable (String, String) -> Void) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            return completion("erro: URL inválida", "")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("kiro-chat", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { return completion("erro: \(error.localizedDescription)", "") }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0.prefix(Self.maxOutput), encoding: .utf8) } ?? ""
            completion("HTTP \(code)", text)
        }.resume()
    }
}

/// Guarda o fim da saída do comando (os últimos `limit` bytes).
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > limit { data = data.suffix(limit) }
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Marca que só vira verdadeira uma vez (seguro entre threads).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// true só na primeira chamada.
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
