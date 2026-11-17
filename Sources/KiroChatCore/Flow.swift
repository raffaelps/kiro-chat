import Foundation
import SQLite3

/// Controle de fluxo entre bots, para eles não conversarem sem parar:
///
/// - **Trocas seguidas** (`hop`): cada mensagem de bot conta uma troca a mais que a mensagem que ela responde.
///   Mensagem de humano zera a contagem. Menções em mensagens que chegaram ao limite não acordam ninguém.
/// - **[FIM]**: o bot (ou o humano) encerra o fluxo. A mensagem é publicada, mas não acorda ninguém.
/// - **[SEM RESPOSTA]**: o bot acordado não tem nada a acrescentar; nada é publicado.
/// - **Parar bots**: pausa geral. Ninguém é acordado e os bots que estão rodando são interrompidos.
public enum FlowMarkers {
    public static let end = "[FIM]"
    public static let noReply = "[SEM RESPOSTA]"

    /// Tira o marcador [FIM] do texto. Retorna o texto (com "✅" no lugar) e se o marcador estava lá.
    public static func extractEnd(_ text: String) -> (String, Bool) {
        guard text.range(of: end, options: .caseInsensitive) != nil else { return (text, false) }
        let stripped = text.replacingOccurrences(of: end, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped.isEmpty ? "✅ Concluído." : "✅ " + stripped, true)
    }

    /// A resposta inteira é "[SEM RESPOSTA]" (aceita variações de caixa e pontuação ao redor).
    public static func isNoReply(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.caseInsensitiveCompare("sem resposta") == .orderedSame
    }
}

extension ChatStore {
    public static let defaultMaxBotHops = 6

    func migrateFlow() throws {
        let cols = try query("PRAGMA table_info(messages)", []) { Self.text($0, 1) }
        if !cols.contains("hop") {
            try exec("ALTER TABLE messages ADD COLUMN hop INTEGER NOT NULL DEFAULT 0;")
        }
        try exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        // v5: canais abertos (#geral já nasce aberto) e menções implícitas (quem só "escuta").
        let ccols = try query("PRAGMA table_info(channels)", []) { Self.text($0, 1) }
        if !ccols.contains("open") {
            try exec("ALTER TABLE channels ADD COLUMN open INTEGER NOT NULL DEFAULT 0;")
            try run("UPDATE channels SET open = 1 WHERE name = ?", [.text(ChatNames.defaultChannel)])
        }
        // v6: conversas diretas (canal de um humano com um único bot).
        if !ccols.contains("dm_with") {
            try exec("ALTER TABLE channels ADD COLUMN dm_with TEXT;")
        }
        // Um bot que escreveu em `dm-<bot>` antes da conversa existir criava um canal comum, visível a todos.
        // Esses canais viram a conversa direta que deviam ser.
        try exec("""
        UPDATE channels SET dm_with = substr(name, 4), open = 0
        WHERE dm_with IS NULL AND name LIKE 'dm-%'
          AND substr(name, 4) IN (SELECT name FROM bots WHERE is_human = 0);
        """)
        // v7: espera padrão do gatilho passou de 5 s para 3 s. Gatilhos que estavam no padrão antigo acompanham
        // (uma vez só; quem escolheu outro valor não muda).
        if setting("default_delay_v2") == nil {
            try run("UPDATE triggers SET delay_seconds = ? WHERE delay_seconds = 5", [.double(WakeTrigger.defaultDelay)])
            try setSetting("default_delay_v2", "1")
        }
        let ncols = try query("PRAGMA table_info(mentions)", []) { Self.text($0, 1) }
        if !ncols.contains("implicit") {
            try exec("ALTER TABLE mentions ADD COLUMN implicit INTEGER NOT NULL DEFAULT 0;")
        }
    }

    // MARK: - Conversas diretas

    public static func directChannelName(for bot: String) -> String { "dm-" + ChatNames.normalize(bot) }

    /// O bot de uma conversa direta (nil se o canal não for uma).
    public func dmBot(of channel: String) throws -> String? {
        try query("SELECT dm_with FROM channels WHERE name = ? AND dm_with IS NOT NULL",
                  [.text(ChatNames.normalize(channel))]) { Self.text($0, 0) }.first
    }

    /// Um bot pode ver o canal? Conversas diretas só são visíveis para o bot delas (e para humanos).
    public func canSee(channel: String, bot: String) throws -> Bool {
        guard let dm = try dmBot(of: channel) else { return true }
        if dm == ChatNames.normalize(bot) { return true }
        return try self.bot(named: bot)?.isHuman ?? false
    }

    /// Abre (ou reabre) a conversa direta com um bot. Retorna o nome do canal.
    @discardableResult
    public func openDirectChannel(with rawBot: String, by who: String) throws -> String {
        let bot = ChatNames.normalize(rawBot)
        guard try self.bot(named: bot) != nil else { throw ChatStoreError.invalid("\(handle(for: bot)) não está no chat.") }
        let channel = Self.directChannelName(for: bot)
        return try transaction {
            let existed = try dmBot(of: channel) != nil
            try createChannel(channel, topic: "Conversa direta com \(handle(for: bot))")
            try run("UPDATE channels SET dm_with = ?, open = 0 WHERE name = ?", [.text(bot), .text(channel)])
            if !existed {
                try post(channel: channel, sender: "sistema", text: """
                💬 Conversa direta entre \(ChatNames.normalize(who) == bot ? "os humanos" : displayName(for: who)) e \(handle(for: bot)). Toda mensagem aqui vai para \
                \(displayName(for: bot)), sem precisar de @. Nenhum outro bot é acordado nem lê esta conversa.
                """, kind: .system)
            }
            return channel
        }
    }

    // MARK: - Canais abertos

    public func isChannelOpen(_ channel: String) throws -> Bool {
        try query("SELECT open FROM channels WHERE name = ?", [.text(ChatNames.normalize(channel))]) {
            sqlite3_column_int($0, 0) != 0
        }.first ?? false
    }

    /// Abre/fecha um canal. Num canal aberto, toda mensagem de humano sem menção acorda todos os bots com gatilho,
    /// todos ao mesmo tempo; cada um responde por si, ou [SEM RESPOSTA] se o assunto não for com ele.
    public func setChannelOpen(_ rawChannel: String, _ open: Bool, by who: String) throws {
        let channel = ChatNames.normalize(rawChannel)
        guard try isChannelOpen(channel) != open else { return }
        if open, try dmBot(of: channel) != nil { throw ChatStoreError.invalid("Uma conversa direta não pode ser aberta.") }
        try transaction {
            try createChannel(channel)
            try run("UPDATE channels SET open = ? WHERE name = ?", [.int(open ? 1 : 0), .text(channel)])
            let name = displayName(for: who)
            try post(channel: channel, sender: "sistema", text: open
                     ? "📣 \(name) abriu #\(channel): todos os bots escutam as mensagens dos humanos e respondem se tiverem algo a dizer."
                     : "🔒 \(name) fechou #\(channel): só quem for mencionado com @ é acordado.",
                     kind: .system)
        }
    }

    // MARK: - Configurações compartilhadas (valem para o app, o CLI e o despachante em segundo plano)

    func setting(_ key: String) -> String? {
        (try? query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { Self.text($0, 0) })?.first
    }

    func setSetting(_ key: String, _ value: String) throws {
        try run("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)])
    }

    /// Pausa geral: enquanto ligada, nenhum gatilho dispara.
    public var wakePaused: Bool { setting("wake_paused") == "1" }

    /// Liga/desliga a pausa geral e avisa no chat. Ao pausar, menções pendentes são descartadas
    /// (não disparam quando os bots forem retomados).
    public func setWakePaused(_ paused: Bool, by who: String, channel: String = ChatNames.defaultChannel) throws {
        guard paused != wakePaused else { return }
        try transaction {
            try setSetting("wake_paused", paused ? "1" : "0")
            if paused {
                try run("UPDATE mentions SET dispatched_at = ? WHERE dispatched_at IS NULL",
                        [.double(Date().timeIntervalSince1970)])
            }
            let name = displayName(for: who)
            try post(channel: channel, sender: "sistema", text: paused
                     ? "⏹ \(name) parou os bots. Ninguém será acordado até \(name) retomar."
                     : "▶️ \(name) retomou os bots. Menções voltam a acordar quem tem gatilho.",
                     kind: .system)
        }
    }

    /// Máximo de trocas seguidas entre bots sem participação humana.
    public var maxBotHops: Int {
        setting("max_bot_hops").flatMap(Int.init).map { max(1, $0) } ?? Self.defaultMaxBotHops
    }

    public func setMaxBotHops(_ n: Int) throws {
        try setSetting("max_bot_hops", String(max(1, n)))
    }

    /// Trocas da próxima mensagem de `sender`: 0 se for humano; senão, 1 a mais que a mensagem respondida
    /// (`replyTo`) ou, sem ela, que a menção mais recente a esse bot nos últimos 30 minutos.
    func nextHop(sender: String, replyTo: Int64?) throws -> Int {
        if try bot(named: sender)?.isHuman ?? false { return 0 }
        if let replyTo, let parent = try message(id: replyTo) { return parent.hop + 1 }
        let recent = try query("""
        SELECT m.hop FROM mentions n JOIN messages m ON m.id = n.message_id
        WHERE n.bot = ? AND m.created_at >= ? ORDER BY m.id DESC LIMIT 1
        """, [.text(sender), .double(Date().timeIntervalSince1970 - 1800)]) { Int(sqlite3_column_int64($0, 0)) }
        return recent.first.map { $0 + 1 } ?? 0
    }

    /// Conversa recente do canal até a última menção (inclusive), para o bot acordado saber o que já foi dito.
    public func conversationContext(for messages: [ChatMessage], limit: Int = 20) throws -> [ChatMessage] {
        // Até a mensagem mais recente do canal: inclui o que outros bots já responderam depois da menção.
        guard let last = messages.last(where: { $0.id > 0 }) else { return [] }
        return try self.messages(channel: last.channel, limit: limit)
    }

    /// Quem escutou mensagens de canal aberto: quem ouviu e não respondeu, e quem ainda não foi acordado.
    /// (Quem respondeu aparece na própria conversa.)
    public struct Listeners: Equatable, Sendable {
        /// Acordados, decidiram não responder ([SEM RESPOSTA]).
        public var heard: [String] = []
        /// Respondendo agora.
        public var answering: [String] = []
        /// Ainda não acordados: espera do gatilho, limite por hora ou o bot ainda está respondendo outra coisa.
        public var queued: [String] = []
        /// O gatilho falhou.
        public var failed: [String] = []
        public var isEmpty: Bool { heard.isEmpty && answering.isEmpty && queued.isEmpty && failed.isEmpty }
    }

    public func listeners(for messageIds: [Int64]) throws -> [Int64: Listeners] {
        guard !messageIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIds.count).joined(separator: ",")
        // Para cada bot que escutou: respondeu? qual foi o disparo dele para esta mensagem? ainda esperando?
        let rows = try query("""
        SELECT n.message_id, COALESCE(NULLIF(b.display_name, ''), n.bot),
               EXISTS(SELECT 1 FROM messages r WHERE r.reply_to = n.message_id AND r.sender = n.bot),
               w.id IS NOT NULL, w.finished_at IS NOT NULL, COALESCE(w.status, ''),
               n.dispatched_at IS NULL AND COALESCE(t.enabled, 0) = 1
        FROM mentions n
        LEFT JOIN bots b ON b.name = n.bot
        LEFT JOIN triggers t ON t.bot = n.bot
        LEFT JOIN wake_log w ON w.id = (
            SELECT MAX(id) FROM wake_log x WHERE x.bot = n.bot AND x.is_test = 0
              AND (',' || x.message_ids || ',') LIKE '%,' || n.message_id || ',%')
        WHERE n.implicit = 1 AND n.message_id IN (\(placeholders))
        ORDER BY n.bot
        """, messageIds.map { .int($0) }) { s in
            (id: sqlite3_column_int64(s, 0), name: Self.text(s, 1), replied: sqlite3_column_int(s, 2) != 0,
             woke: sqlite3_column_int(s, 3) != 0, finished: sqlite3_column_int(s, 4) != 0,
             status: Self.text(s, 5), queued: sqlite3_column_int(s, 6) != 0)
        }
        var result: [Int64: Listeners] = [:]
        for r in rows where !r.replied {
            if r.woke && !r.finished { result[r.id, default: Listeners()].answering.append(r.name) }
            else if r.woke && (r.status == "exit 0" || r.status.hasPrefix("HTTP 2")) { result[r.id, default: Listeners()].heard.append(r.name) }
            else if r.woke { result[r.id, default: Listeners()].failed.append(r.name) }
            else if r.queued { result[r.id, default: Listeners()].queued.append(r.name) }
            // Sem disparo e sem espera: bots parados, limite de trocas ou sem gatilho. Não mostra.
        }
        return result
    }
}
