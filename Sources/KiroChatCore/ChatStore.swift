import Foundation
import SQLite3

public enum ChatStoreError: Error, CustomStringConvertible {
    case sqlite(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .sqlite(let m): return "Erro SQLite: \(m)"
        case .invalid(let m): return m
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Armazenamento compartilhado do chat. Vários processos (um servidor MCP por bot + o app)
/// abrem o mesmo arquivo SQLite em modo WAL, o que permite leitura/escrita concorrente.
public final class ChatStore: @unchecked Sendable {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    enum Value {
        case text(String), int(Int64), double(Double), null
    }

    public init(url: URL = ChatPaths.defaultDatabaseURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            throw ChatStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS bots (
            name TEXT PRIMARY KEY,
            description TEXT NOT NULL DEFAULT '',
            is_human INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            last_seen REAL
        );
        CREATE TABLE IF NOT EXISTS channels (
            name TEXT PRIMARY KEY,
            topic TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            channel TEXT NOT NULL,
            sender TEXT NOT NULL,
            text TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'message',
            reply_to INTEGER,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel, id);
        CREATE TABLE IF NOT EXISTS mentions (
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            bot TEXT NOT NULL,
            read_at REAL,
            PRIMARY KEY (message_id, bot)
        );
        CREATE INDEX IF NOT EXISTS idx_mentions_bot ON mentions(bot, read_at);
        CREATE TABLE IF NOT EXISTS read_cursors (
            bot TEXT NOT NULL,
            channel TEXT NOT NULL,
            last_id INTEGER NOT NULL,
            PRIMARY KEY (bot, channel)
        );
        """)
        try run("INSERT OR IGNORE INTO channels(name, topic, created_at) VALUES (?, ?, ?)",
                [.text(ChatNames.defaultChannel), .text("Canal aberto para todos os bots"),
                 .double(Date().timeIntervalSince1970)])

        // v2: nome de exibição com a capitalização original ("Jon").
        let botColumns = try query("PRAGMA table_info(bots)", []) { Self.text($0, 1) }
        if !botColumns.contains("display_name") {
            try exec("ALTER TABLE bots ADD COLUMN display_name TEXT NOT NULL DEFAULT '';")
        }
        try exec("UPDATE bots SET display_name = upper(substr(name, 1, 1)) || substr(name, 2) WHERE display_name = '';")

        // v3: gatilhos para acordar bots quando forem mencionados.
        try migrateWake()
        // v4: controle de fluxo (trocas seguidas entre bots, pausa geral).
        try migrateFlow()
    }

    // MARK: - Bots

    /// Registra (ou atualiza) um bot e marca como visto agora.
    @discardableResult
    public func registerBot(_ rawName: String, description: String? = nil, isHuman: Bool = false) throws -> BotInfo {
        let name = ChatNames.normalize(rawName)
        guard !name.isEmpty else { throw ChatStoreError.invalid("Nome de bot inválido: '\(rawName)'") }
        guard !ChatNames.broadcast.contains(name) else {
            throw ChatStoreError.invalid("'\(name)' é reservado para menções em massa.")
        }
        let display = ChatNames.displayName(fromRaw: rawName)
        let now = Date().timeIntervalSince1970
        return try transaction {
            let existed = try bot(named: name) != nil
            try run("""
            INSERT INTO bots(name, display_name, description, is_human, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                last_seen = excluded.last_seen,
                display_name = excluded.display_name,
                description = CASE WHEN ? IS NULL THEN bots.description ELSE excluded.description END
            """, [.text(name), .text(display), .text(description ?? ""), .int(isHuman ? 1 : 0), .double(now),
                  .double(now), description.map { .text($0) } ?? .null])
            let info = try bot(named: name)!
            if !existed && !isHuman {
                try insertMessage(channel: ChatNames.defaultChannel, sender: "sistema",
                                  text: "🤖 \(info.handle) entrou no chat.", kind: .system, replyTo: nil, mentions: [])
            }
            return info
        }
    }

    /// Nome de exibição de um bot ("jon" → "Jon"), mesmo que ele não esteja cadastrado.
    public func displayName(for key: String) -> String {
        let k = ChatNames.normalize(key)
        return (try? bot(named: k))?.map(\.displayName) ?? ChatNames.display(forKey: k)
    }

    /// Handle para mencionar um bot ("@Jon").
    public func handle(for key: String) -> String {
        let k = ChatNames.normalize(key)
        return (try? bot(named: k))?.map(\.handle) ?? "@" + ChatNames.display(forKey: k)
    }

    /// Renomeia um participante levando junto o histórico (mensagens, menções, cursores, gatilho).
    /// Usado para o humano trocar o próprio nome ("Humano" → "Raffael").
    @discardableResult
    public func renameBot(from oldRaw: String, to newRaw: String, description: String? = nil,
                          isHuman: Bool = true) throws -> BotInfo {
        let oldKey = ChatNames.normalize(oldRaw)
        let newKey = ChatNames.normalize(newRaw)
        let display = ChatNames.displayName(fromRaw: newRaw)
        guard !newKey.isEmpty else { throw ChatStoreError.invalid("Nome inválido: '\(newRaw)'") }
        guard !ChatNames.broadcast.contains(newKey), newKey != "sistema" else {
            throw ChatStoreError.invalid("'\(display)' é um nome reservado.")
        }
        return try transaction {
            let oldExists = try bot(named: oldKey) != nil
            if oldKey == newKey || !oldExists {
                return try registerBot(newRaw, description: description, isHuman: isHuman)
            }
            if let existing = try bot(named: newKey) {
                guard existing.isHuman else {
                    throw ChatStoreError.invalid("Já existe um bot chamado \(existing.displayName).")
                }
                // Era um nome antigo do próprio humano: junta os dois.
                try run("DELETE FROM bots WHERE name = ?", [.text(newKey)])
            }
            try run("UPDATE bots SET name = ?, display_name = ? WHERE name = ?", [.text(newKey), .text(display), .text(oldKey)])
            try run("UPDATE messages SET sender = ? WHERE sender = ?", [.text(newKey), .text(oldKey)])
            for table in ["mentions", "read_cursors", "triggers"] {
                try run("UPDATE OR IGNORE \(table) SET bot = ? WHERE bot = ?", [.text(newKey), .text(oldKey)])
                try run("DELETE FROM \(table) WHERE bot = ?", [.text(oldKey)])
            }
            touch(newKey)
            return try bot(named: newKey)!
        }
    }

    public func touch(_ name: String) {
        _ = try? run("UPDATE bots SET last_seen = ? WHERE name = ?",
                 [.double(Date().timeIntervalSince1970), .text(ChatNames.normalize(name))])
    }

    public func bot(named name: String) throws -> BotInfo? {
        try query("SELECT name, description, is_human, created_at, last_seen, display_name FROM bots WHERE name = ?",
                  [.text(ChatNames.normalize(name))], map: Self.mapBot).first
    }

    public func listBots(includeHumans: Bool = true) throws -> [BotInfo] {
        let sql = "SELECT name, description, is_human, created_at, last_seen, display_name FROM bots"
            + (includeHumans ? "" : " WHERE is_human = 0") + " ORDER BY is_human, name"
        return try query(sql, [], map: Self.mapBot)
    }

    // MARK: - Canais

    @discardableResult
    public func createChannel(_ rawName: String, topic: String = "") throws -> String {
        let name = ChatNames.normalize(rawName)
        guard !name.isEmpty else { throw ChatStoreError.invalid("Nome de canal inválido: '\(rawName)'") }
        try run("""
        INSERT INTO channels(name, topic, created_at) VALUES (?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET topic = CASE WHEN excluded.topic = '' THEN channels.topic ELSE excluded.topic END
        """, [.text(name), .text(topic), .double(Date().timeIntervalSince1970)])
        return name
    }

    public func listChannels() throws -> [ChannelInfo] {
        try query("""
        SELECT c.name, c.topic, COUNT(m.id), COALESCE(MAX(m.id), 0), c.open, c.dm_with
        FROM channels c LEFT JOIN messages m ON m.channel = c.name
        GROUP BY c.name ORDER BY (c.name = ?) DESC, c.name
        """, [.text(ChatNames.defaultChannel)]) { s in
            ChannelInfo(name: Self.text(s, 0), topic: Self.text(s, 1),
                        messageCount: Int(sqlite3_column_int64(s, 2)),
                        lastMessageId: sqlite3_column_int64(s, 3),
                        isOpen: sqlite3_column_int(s, 4) != 0,
                        dmWith: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Self.text(s, 5))
        }
    }

    // MARK: - Mensagens

    /// Publica uma mensagem. Menções vêm do texto (@nome) e de `extraMentions`.
    /// `@todos`/`@all` notifica todos os bots (menos quem enviou).
    @discardableResult
    public func post(channel rawChannel: String = ChatNames.defaultChannel, sender rawSender: String,
                     text: String, kind: MessageKind = .message, replyTo: Int64? = nil,
                     extraMentions: [String] = [], hop explicitHop: Int? = nil) throws -> ChatMessage {
        let channel = ChatNames.normalize(rawChannel)
        let sender = ChatNames.normalize(rawSender)
        // [FIM] encerra o fluxo: a mensagem é publicada, mas ninguém é acordado por ela.
        let marker = kind == .system ? (text, false) : FlowMarkers.extractEnd(text)
        let body = marker.0.trimmingCharacters(in: .whitespacesAndNewlines)
        let ends = marker.1
        guard !channel.isEmpty else { throw ChatStoreError.invalid("Canal inválido.") }
        guard !body.isEmpty else { throw ChatStoreError.invalid("A mensagem está vazia.") }

        return try transaction {
            // `dm-<bot>` é reservado: se a conversa direta ainda não existe, nasce como conversa direta
            // (aberta pelo próprio bot ou por um humano), nunca como canal comum que todos veem.
            if channel.hasPrefix("dm-"), try dmBot(of: channel) == nil {
                let bot = String(channel.dropFirst(3))
                guard let b = try self.bot(named: bot), !b.isHuman else {
                    throw ChatStoreError.invalid("Canais dm-… são reservados para conversas diretas com um bot do chat.")
                }
                let senderIsHuman = try self.bot(named: sender)?.isHuman ?? false
                guard sender == bot || senderIsHuman else {
                    throw ChatStoreError.invalid("Você não tem acesso a #\(channel).")
                }
                try openDirectChannel(with: bot, by: sender)
            }
            try createChannel(channel)
            var targets: [String] = []
            var seen = Set<String>()
            // Mensagens de sistema citam bots (@x entrou...) mas não os notificam.
            let candidates = kind == .system ? [] : ChatNames.extractMentions(from: body) + extraMentions.map(ChatNames.normalize)
            for name in candidates {
                if ChatNames.broadcast.contains(name) {
                    for b in try listBots(includeHumans: false) where b.name != sender && seen.insert(b.name).inserted {
                        targets.append(b.name)
                    }
                } else if !name.isEmpty, name != sender, seen.insert(name).inserted {
                    targets.append(name)
                }
            }
            // Conversa direta: só o bot dela é acordado; mensagem de humano vai para ele mesmo sem @.
            if let dm = try dmBot(of: channel) {
                targets = targets.filter { $0 == dm }
                if kind != .system, targets.isEmpty, sender != dm, try bot(named: sender)?.isHuman == true {
                    targets = [dm]
                }
            }
            // Canal aberto: mensagem de humano sem menção é ouvida por todos os bots (menção "implícita").
            // Mensagens de bots sem menção não acordam ninguém, senão cada resposta viraria uma cascata.
            var listeners: [String] = []
            if kind != .system, targets.isEmpty, !ends, try isChannelOpen(channel),
               try bot(named: sender)?.isHuman == true {
                listeners = try listBots(includeHumans: false).map(\.name).filter { $0 != sender }
            }
            let hop = kind == .system ? 0 : try explicitHop ?? nextHop(sender: sender, replyTo: replyTo)
            let msg = try insertMessage(channel: channel, sender: sender, text: body, kind: kind,
                                        replyTo: replyTo, mentions: targets, hop: hop, wakes: !ends,
                                        listeners: listeners)
            // Quem escreve já "leu" o canal até a própria mensagem.
            try setReadCursor(bot: sender, channel: channel, lastId: msg.id)
            touch(sender)
            return msg
        }
    }

    @discardableResult
    private func insertMessage(channel: String, sender: String, text: String, kind: MessageKind,
                               replyTo: Int64?, mentions: [String], hop: Int = 0, wakes: Bool = true,
                               listeners: [String] = []) throws -> ChatMessage {
        let now = Date()
        try run("INSERT INTO messages(channel, sender, text, kind, reply_to, created_at, hop) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(channel), .text(sender), .text(text), .text(kind.rawValue),
                 replyTo.map { .int($0) } ?? .null, .double(now.timeIntervalSince1970), .int(Int64(hop))])
        let id = sqlite3_last_insert_rowid(db)
        for m in mentions {
            // Sem `wakes` (mensagem com [FIM]), a menção já nasce despachada: notifica, mas não acorda.
            try run("INSERT OR IGNORE INTO mentions(message_id, bot, dispatched_at) VALUES (?, ?, ?)",
                    [.int(id), .text(m), wakes ? .null : .double(now.timeIntervalSince1970)])
        }
        for l in listeners {
            try run("INSERT OR IGNORE INTO mentions(message_id, bot, implicit) VALUES (?, ?, 1)", [.int(id), .text(l)])
        }
        return try message(id: id) ?? ChatMessage(id: id, channel: channel, sender: sender, text: text, kind: kind,
                                                  replyTo: replyTo, createdAt: now, mentions: mentions, hop: hop)
    }

    private static let messageColumns = """
    m.id, m.channel, m.sender, m.text, m.kind, m.reply_to, m.created_at,
    (SELECT group_concat(n.bot || char(30) || COALESCE(b.display_name, ''), char(31))
       FROM mentions n LEFT JOIN bots b ON b.name = n.bot WHERE n.message_id = m.id AND n.implicit = 0),
    (SELECT display_name FROM bots WHERE name = m.sender),
    m.hop
    """

    /// Mensagens em ordem crescente de id.
    /// - afterId: apenas mensagens com id maior.
    /// - limit: as `limit` mais recentes dentro do filtro.
    public func messages(channel: String? = nil, afterId: Int64? = nil, beforeId: Int64? = nil,
                         limit: Int = 50) throws -> [ChatMessage] {
        var conds: [String] = []
        var binds: [Value] = []
        if let channel { conds.append("m.channel = ?"); binds.append(.text(ChatNames.normalize(channel))) }
        if let afterId { conds.append("m.id > ?"); binds.append(.int(afterId)) }
        if let beforeId { conds.append("m.id < ?"); binds.append(.int(beforeId)) }
        let whereSQL = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        binds.append(.int(Int64(max(1, limit))))
        let rows = try query("SELECT \(Self.messageColumns) FROM messages m \(whereSQL) ORDER BY m.id DESC LIMIT ?",
                             binds, map: Self.mapMessage)
        return rows.reversed()
    }

    public func message(id: Int64) throws -> ChatMessage? {
        try query("SELECT \(Self.messageColumns) FROM messages m WHERE m.id = ?", [.int(id)], map: Self.mapMessage).first
    }

    public func maxMessageId() throws -> Int64 {
        try query("SELECT COALESCE(MAX(id), 0) FROM messages", []) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    // MARK: - Menções / notificações

    public func unreadMentions(for bot: String, limit: Int = 50) throws -> [ChatMessage] {
        try query("""
        SELECT \(Self.messageColumns) FROM messages m
        JOIN mentions n ON n.message_id = m.id
        WHERE n.bot = ? AND n.read_at IS NULL AND n.implicit = 0
        ORDER BY m.id ASC LIMIT ?
        """, [.text(ChatNames.normalize(bot)), .int(Int64(limit))], map: Self.mapMessage)
    }

    public func unreadMentionCount(for bot: String) throws -> Int {
        try query("SELECT COUNT(*) FROM mentions WHERE bot = ? AND read_at IS NULL AND implicit = 0",
                  [.text(ChatNames.normalize(bot))]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func markMentionsRead(for bot: String, messageIds: [Int64]? = nil) throws {
        let now = Date().timeIntervalSince1970
        let name = ChatNames.normalize(bot)
        if let ids = messageIds {
            guard !ids.isEmpty else { return }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try run("UPDATE mentions SET read_at = ? WHERE bot = ? AND read_at IS NULL AND message_id IN (\(placeholders))",
                    [.double(now), .text(name)] + ids.map { .int($0) })
        } else {
            try run("UPDATE mentions SET read_at = ? WHERE bot = ? AND read_at IS NULL", [.double(now), .text(name)])
        }
    }

    // MARK: - Cursores de leitura

    public func readCursor(bot: String, channel: String) throws -> Int64 {
        try query("SELECT last_id FROM read_cursors WHERE bot = ? AND channel = ?",
                  [.text(ChatNames.normalize(bot)), .text(ChatNames.normalize(channel))]) {
            sqlite3_column_int64($0, 0)
        }.first ?? 0
    }

    public func setReadCursor(bot: String, channel: String, lastId: Int64) throws {
        try run("""
        INSERT INTO read_cursors(bot, channel, last_id) VALUES (?, ?, ?)
        ON CONFLICT(bot, channel) DO UPDATE SET last_id = MAX(read_cursors.last_id, excluded.last_id)
        """, [.text(ChatNames.normalize(bot)), .text(ChatNames.normalize(channel)), .int(lastId)])
    }

    /// Quantidade de mensagens de outros participantes depois do cursor, por canal.
    public func unreadCounts(for bot: String) throws -> [String: Int] {
        let name = ChatNames.normalize(bot)
        let rows: [(String, Int)] = try query("""
        SELECT m.channel, COUNT(*) FROM messages m
        LEFT JOIN read_cursors r ON r.bot = ? AND r.channel = m.channel
        WHERE m.id > COALESCE(r.last_id, 0) AND m.sender != ? AND m.kind != 'system'
        GROUP BY m.channel
        """, [.text(name), .text(name)]) { (Self.text($0, 0), Int(sqlite3_column_int64($0, 1))) }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    // MARK: - Manutenção

    public func clearChannel(_ channel: String) throws {
        try deleteMessages(channel: channel)
    }

    /// Quantas mensagens `deleteMessages` apagaria com os mesmos filtros.
    public func countMessages(channel: String? = nil, olderThan: Date? = nil) throws -> Int {
        var conds: [String] = []
        var binds: [Value] = []
        if let channel { conds.append("channel = ?"); binds.append(.text(ChatNames.normalize(channel))) }
        if let olderThan { conds.append("created_at < ?"); binds.append(.double(olderThan.timeIntervalSince1970)) }
        let whereSQL = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        return try query("SELECT COUNT(*) FROM messages \(whereSQL)", binds) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    /// Apaga mensagens de um canal (ou de todos, com `channel` nil). Com `olderThan`, só as anteriores a essa data.
    /// Menções das mensagens apagadas vão junto. Retorna quantas mensagens foram apagadas.
    @discardableResult
    public func deleteMessages(channel: String? = nil, olderThan: Date? = nil) throws -> Int {
        var conds: [String] = []
        var binds: [Value] = []
        if let channel { conds.append("channel = ?"); binds.append(.text(ChatNames.normalize(channel))) }
        if let olderThan { conds.append("created_at < ?"); binds.append(.double(olderThan.timeIntervalSince1970)) }
        let whereSQL = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        return try transaction {
            _ = try run("DELETE FROM mentions WHERE message_id IN (SELECT id FROM messages \(whereSQL))", binds)
            return try run("DELETE FROM messages \(whereSQL)", binds)
        }
    }

    public func removeBot(_ name: String) throws {
        let n = ChatNames.normalize(name)
        try transaction {
            try run("DELETE FROM bots WHERE name = ?", [.text(n)])
            try run("DELETE FROM mentions WHERE bot = ?", [.text(n)])
            try run("DELETE FROM read_cursors WHERE bot = ?", [.text(n)])
            try run("DELETE FROM triggers WHERE bot = ?", [.text(n)])
        }
    }

    // MARK: - SQLite helpers

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "desconhecido"
            sqlite3_free(err)
            throw ChatStoreError.sqlite(msg)
        }
    }

    private func prepare(_ sql: String, _ binds: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    @discardableResult
    func run(_ sql: String, _ binds: [Value]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw ChatStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    func query<T>(_ sql: String, _ binds: [Value], map: (OpaquePointer) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(stmt!)) }
            else if rc == SQLITE_DONE { break }
            else { throw ChatStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if sqlite3_get_autocommit(db) == 0 { return try body() } // já dentro de uma transação
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }

    private static func mapBot(_ s: OpaquePointer) -> BotInfo {
        BotInfo(name: text(s, 0),
                displayName: text(s, 5).isEmpty ? ChatNames.display(forKey: text(s, 0)) : text(s, 5),
                description: text(s, 1), isHuman: sqlite3_column_int(s, 2) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                lastSeen: sqlite3_column_type(s, 4) == SQLITE_NULL ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(s, 4)))
    }

    private static func mapMessage(_ s: OpaquePointer) -> ChatMessage {
        // Menções vêm como "chave\u{1E}Nome" separadas por \u{1F}.
        let pairs = text(s, 7).split(separator: "\u{1F}").map { pair -> (String, String) in
            let parts = pair.split(separator: "\u{1E}", omittingEmptySubsequences: false).map(String.init)
            let key = parts[0]
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : ChatNames.display(forKey: key)
            return (key, name)
        }
        let sender = text(s, 2)
        let senderName = text(s, 8)
        return ChatMessage(
            id: sqlite3_column_int64(s, 0), channel: text(s, 1), sender: sender,
            senderName: senderName.isEmpty ? ChatNames.display(forKey: sender) : senderName,
            text: text(s, 3),
            kind: MessageKind(rawValue: text(s, 4)) ?? .message,
            replyTo: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
            mentions: pairs.map(\.0), mentionNames: pairs.map(\.1),
            hop: Int(sqlite3_column_int64(s, 9)))
    }
}
