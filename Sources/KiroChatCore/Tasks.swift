import Foundation
import SQLite3

/// Quadro de tarefas (Kanban) do chat: humanos e bots criam tarefas e movem entre as colunas.
/// Os bots do Kiro Crew mexem no quadro escrevendo linhas `[TAREFA ...]` na resposta (veja `TaskMarkers`);
/// bots com o MCP usam as ferramentas create_task/update_task/list_tasks.
public enum TaskStatus: String, CaseIterable, Codable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case waiting
    case done

    public var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "Em andamento"
        case .waiting: return "Aguardando"
        case .done: return "Feito"
        }
    }

    /// Palavra curta usada com os bots ("[TAREFA #3] status: andamento").
    public var word: String {
        switch self {
        case .backlog: return "backlog"
        case .inProgress: return "andamento"
        case .waiting: return "aguardando"
        case .done: return "feito"
        }
    }

    /// Aceita o nome em português ou inglês, com ou sem acento ("em andamento", "in progress", "concluído"...).
    public static func parse(_ raw: String) -> TaskStatus? {
        let s = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        switch s {
        case "backlog", "a fazer", "afazer", "todo", "to do", "pendente", "nova", "novo": return .backlog
        case "andamento", "em andamento", "in progress", "inprogress", "progress", "fazendo", "doing", "iniciada", "iniciado":
            return .inProgress
        case "aguardando", "waiting", "esperando", "bloqueada", "bloqueado", "blocked", "em espera": return .waiting
        case "feito", "feita", "done", "concluido", "concluida", "pronto", "pronta", "finalizado", "finalizada": return .done
        default: return nil
        }
    }
}

public struct ChatTask: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public var title: String
    public var notes: String
    public var status: TaskStatus
    /// Chave do responsável (bot ou humano), se houver.
    public var assignee: String?
    /// Data da tarefa no formato AAAA-MM-DD (dia local), se houver.
    public var due: String?
    public let createdBy: String
    public let createdAt: Date
    public var updatedBy: String
    public var updatedAt: Date

    public init(id: Int64, title: String, notes: String = "", status: TaskStatus = .backlog, assignee: String? = nil,
                due: String? = nil, createdBy: String, createdAt: Date = Date(), updatedBy: String? = nil,
                updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.assignee = assignee
        self.due = due
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedBy = updatedBy ?? createdBy
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Em que dia a tarefa cai, em relação a hoje.
    public func day(now: Date = Date(), calendar: Calendar = .current) -> TaskDay {
        TaskDay.of(due, now: now, calendar: calendar)
    }
}

/// Agrupamento por data: o que é de hoje, de amanhã ou para depois.
public enum TaskDay: String, CaseIterable, Sendable {
    case overdue, today, tomorrow, future, none

    public static func of(_ due: String?, now: Date = Date(), calendar: Calendar = .current) -> TaskDay {
        guard let due, let date = TaskDates.date(from: due, calendar: calendar) else { return .none }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return .overdue
        case 0: return .today
        case 1: return .tomorrow
        default: return .future
        }
    }
}

/// Datas das tarefas: guardadas como "AAAA-MM-DD" (dia local, sem hora).
public enum TaskDates {
    static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        formatter(calendar).string(from: date)
    }

    public static func date(from s: String, calendar: Calendar = .current) -> Date? {
        formatter(calendar).date(from: s)
    }

    /// Lê uma data escrita por humano ou bot: "hoje", "amanhã", "depois de amanhã", "ontem", "2026-11-20", "20/11", "20/11/2026".
    /// "" (string vazia) significa tirar a data ("sem data", "nenhuma", "-"). nil = não entendi.
    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let s = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;")))
        let today = calendar.startOfDay(for: now)
        func plus(_ d: Int) -> String { string(from: calendar.date(byAdding: .day, value: d, to: today)!, calendar: calendar) }
        switch s {
        case "", "-", "sem data", "nenhuma", "nenhum", "none", "nao", "limpar": return ""
        case "hoje", "today": return plus(0)
        case "amanha", "tomorrow": return plus(1)
        case "depois de amanha": return plus(2)
        case "ontem", "yesterday": return plus(-1)
        default: break
        }
        if let d = date(from: s, calendar: calendar), s.count == 10 { return string(from: d, calendar: calendar) }
        // dd/mm ou dd/mm/aaaa (também com "-" ou ".").
        let parts = s.split(whereSeparator: { "/.-".contains($0) }).compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]) else { return nil }
        var year = parts.count == 3 ? parts[2] : calendar.component(.year, from: today)
        if year < 100 { year += 2000 }
        var c = DateComponents(year: year, month: parts[1], day: parts[0])
        guard var d = calendar.date(from: c), calendar.component(.day, from: d) == parts[0] else { return nil }
        // "05/01" escrito em dezembro é janeiro do ano que vem.
        if parts.count == 2, d < calendar.date(byAdding: .month, value: -2, to: today)! {
            c.year = year + 1
            d = calendar.date(from: c) ?? d
        }
        return string(from: d, calendar: calendar)
    }

    /// "hoje", "amanhã", "ontem" ou "20/11" (com o ano se não for o atual).
    public static func label(_ due: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let d = date(from: due, calendar: calendar) else { return due }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: d).day ?? 0
        switch days {
        case 0: return "hoje"
        case 1: return "amanhã"
        case -1: return "ontem"
        default:
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = calendar.component(.year, from: d) == calendar.component(.year, from: now) ? "dd/MM" : "dd/MM/yyyy"
            return f.string(from: d)
        }
    }
}

/// Mudanças numa tarefa. Campos nil ficam como estão; para tirar o responsável ou a data, use "".
public struct TaskPatch: Sendable {
    public var title: String?
    public var notes: String?
    public var status: TaskStatus?
    public var assignee: String?
    public var due: String?

    public init(title: String? = nil, notes: String? = nil, status: TaskStatus? = nil,
                assignee: String? = nil, due: String? = nil) {
        self.title = title
        self.notes = notes
        self.status = status
        self.assignee = assignee
        self.due = due
    }

    public var isEmpty: Bool { title == nil && notes == nil && status == nil && assignee == nil && due == nil }
}

extension ChatStore {
    func migrateTasks() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'backlog',
            assignee TEXT,
            due TEXT,
            created_by TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_by TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status, due);
        """)
    }

    private static let taskColumns = "id, title, notes, status, assignee, due, created_by, created_at, updated_by, updated_at"

    private static func mapTask(_ s: OpaquePointer) -> ChatTask {
        func optional(_ i: Int32) -> String? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : (text(s, i).isEmpty ? nil : text(s, i))
        }
        return ChatTask(id: sqlite3_column_int64(s, 0), title: text(s, 1), notes: text(s, 2),
                        status: TaskStatus(rawValue: text(s, 3)) ?? .backlog,
                        assignee: optional(4), due: optional(5), createdBy: text(s, 6),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                        updatedBy: text(s, 8), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 9)))
    }

    /// Valida e normaliza: data em AAAA-MM-DD (aceita "hoje", "20/11"...), responsável sem "@".
    private func normalizedDue(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard let d = TaskDates.parse(raw) else {
            throw ChatStoreError.invalid("Data inválida: '\(raw)'. Use AAAA-MM-DD, DD/MM, hoje ou amanhã.")
        }
        return d
    }

    private func normalizedAssignee(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespaces)
        let lowered = t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if t.isEmpty || t == "-" || ["ninguem", "nenhum", "none"].contains(lowered) { return "" }
        return ChatNames.normalize(t)
    }

    @discardableResult
    public func createTask(title rawTitle: String, notes: String = "", status: TaskStatus = .backlog,
                           assignee: String? = nil, due: String? = nil, by rawBy: String) throws -> ChatTask {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ChatStoreError.invalid("A tarefa precisa de um título.") }
        let by = ChatNames.normalize(rawBy)
        let d = try normalizedDue(due)
        let who = normalizedAssignee(assignee)
        let now = Date().timeIntervalSince1970
        return try transaction {
            try run("""
            INSERT INTO tasks(title, notes, status, assignee, due, created_by, created_at, updated_by, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(String(title.prefix(300))), .text(notes), .text(status.rawValue),
                  who.flatMap { $0.isEmpty ? nil : .text($0) } ?? .null,
                  d.flatMap { $0.isEmpty ? nil : .text($0) } ?? .null,
                  .text(by), .double(now), .text(by), .double(now)])
            let id = try query("SELECT last_insert_rowid()", []) { sqlite3_column_int64($0, 0) }.first ?? 0
            return try task(id: id)!
        }
    }

    @discardableResult
    public func updateTask(id: Int64, _ patch: TaskPatch, by rawBy: String) throws -> ChatTask {
        guard var t = try task(id: id) else { throw ChatStoreError.invalid("A tarefa #\(id) não existe.") }
        if let title = patch.title?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !title.isEmpty else { throw ChatStoreError.invalid("A tarefa precisa de um título.") }
            t.title = String(title.prefix(300))
        }
        if let notes = patch.notes { t.notes = notes }
        if let status = patch.status { t.status = status }
        if let who = normalizedAssignee(patch.assignee) { t.assignee = who.isEmpty ? nil : who }
        if let d = try normalizedDue(patch.due) { t.due = d.isEmpty ? nil : d }
        let by = ChatNames.normalize(rawBy)
        try run("""
        UPDATE tasks SET title = ?, notes = ?, status = ?, assignee = ?, due = ?, updated_by = ?, updated_at = ?
        WHERE id = ?
        """, [.text(t.title), .text(t.notes), .text(t.status.rawValue),
              t.assignee.map { .text($0) } ?? .null, t.due.map { .text($0) } ?? .null,
              .text(by), .double(Date().timeIntervalSince1970), .int(id)])
        return try task(id: id)!
    }

    public func deleteTask(id: Int64) throws {
        try run("DELETE FROM tasks WHERE id = ?", [.int(id)])
    }

    public func task(id: Int64) throws -> ChatTask? {
        try query("SELECT \(Self.taskColumns) FROM tasks WHERE id = ?", [.int(id)], map: Self.mapTask).first
    }

    /// Tarefas, das com data mais próxima para as sem data. `includeDone: false` esconde as feitas.
    public func tasks(status: TaskStatus? = nil, assignee: String? = nil, includeDone: Bool = true,
                      limit: Int = 500) throws -> [ChatTask] {
        var whereParts: [String] = []
        var binds: [Value] = []
        if let status { whereParts.append("status = ?"); binds.append(.text(status.rawValue)) }
        if !includeDone && status == nil { whereParts.append("status <> 'done'") }
        if let assignee { whereParts.append("assignee = ?"); binds.append(.text(ChatNames.normalize(assignee))) }
        let w = whereParts.isEmpty ? "" : "WHERE " + whereParts.joined(separator: " AND ")
        binds.append(.int(Int64(limit)))
        return try query("""
        SELECT \(Self.taskColumns) FROM tasks \(w)
        ORDER BY due IS NULL, due, id LIMIT ?
        """, binds, map: Self.mapTask)
    }

    /// Muda sempre que alguma tarefa é criada, alterada ou apagada (o app usa para saber quando recarregar).
    public func tasksSignature() throws -> String {
        try query("SELECT count(*), coalesce(max(id), 0), coalesce(max(updated_at), 0) FROM tasks", []) {
            "\(sqlite3_column_int64($0, 0))|\(sqlite3_column_int64($0, 1))|\(sqlite3_column_double($0, 2))"
        }.first ?? ""
    }
}

/// Linhas `[TAREFA ...]` na resposta de um bot sem ferramentas (bots do Kiro Crew):
///
///     [TAREFA nova] Corrigir o crash do login | data: amanhã | para: @robb | status: backlog
///     [TAREFA #12] status: andamento
///     [TAREFA #12] feito
///
/// O chat aplica cada linha no quadro e troca a linha por um aviso legível ("📋 Nova tarefa #12: ...").
public enum TaskMarkers {
    private static let line = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s*)?`?\[\s*TAREFA\s*(nova|novo|new|#?\s*(\d+))\s*\]`?\s*(.*)$"#,
        options: [.caseInsensitive])

    public struct Result: Sendable {
        public let text: String
        public let changed: [ChatTask]
    }

    /// Há alguma linha de tarefa no texto?
    public static func contains(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { match($0) != nil }
    }

    private static func match(_ s: String) -> (new: Bool, id: Int64?, rest: String)? {
        guard let m = line.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        let id = group(2).flatMap { Int64($0) }
        return (id == nil, id, group(3)?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    /// Lê "Título | data: amanhã | para: @jon" (criar) ou "status: feito | data: hoje" / "feito" (alterar).
    static func fields(_ rest: String, new: Bool) -> (TaskPatch, [String]) {
        var patch = TaskPatch()
        var unknown: [String] = []
        for (i, rawPart) in rest.split(separator: "|").enumerated() {
            let part = rawPart.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`*"))
            guard !part.isEmpty else { continue }
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let key = kv.count == 2 ? kv[0].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) : ""
            let value = kv.count == 2 ? kv[1] : part
            switch key {
            case "titulo", "title", "nome": patch.title = value
            case "status", "coluna", "estado": if let s = TaskStatus.parse(value) { patch.status = s } else { unknown.append(part) }
            case "data", "dia", "prazo", "date", "due", "quando": patch.due = value
            case "para", "responsavel", "dono", "quem", "assignee", "to": patch.assignee = value
            case "nota", "notas", "obs", "detalhes", "descricao", "notes": patch.notes = value
            default:
                if new && i == 0 { patch.title = part }                         // primeiro campo de uma nova = título
                else if let s = TaskStatus.parse(part) { patch.status = s }     // "[TAREFA #3] feito"
                else { unknown.append(part) }
            }
        }
        return (patch, unknown)
    }

    /// Aplica as linhas de tarefa e devolve o texto com cada linha trocada por um aviso.
    public static func apply(in text: String, by bot: String, store: ChatStore) -> Result {
        var changed: [ChatTask] = []
        var inCode = false
        let lines = text.components(separatedBy: "\n").map { s -> String in
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return s }
            guard !inCode, let m = match(s) else { return s }
            let (patch, unknown) = fields(m.rest, new: m.new)
            do {
                let t: ChatTask
                if m.new {
                    t = try store.createTask(title: patch.title ?? "", notes: patch.notes ?? "",
                                             status: patch.status ?? .backlog, assignee: patch.assignee,
                                             due: patch.due, by: bot)
                } else {
                    guard !patch.isEmpty else { return "⚠️ Tarefa #\(m.id!): não entendi a mudança (\(m.rest))." }
                    t = try store.updateTask(id: m.id!, patch, by: bot)
                }
                changed.append(t)
                let extra = unknown.isEmpty ? "" : " (ignorado: \(unknown.joined(separator: ", ")))"
                return summary(t, new: m.new, patch: patch, store: store) + extra
            } catch {
                return "⚠️ " + (m.new ? "Não criei a tarefa" : "Não mudei a tarefa #\(m.id!)") + ": \(error)"
            }
        }
        return Result(text: lines.joined(separator: "\n"), changed: changed)
    }

    /// "📋 Nova tarefa #12: **Título** · Backlog · amanhã · para Robb" ou "📋 Tarefa #12 **Título** → Em andamento".
    static func summary(_ t: ChatTask, new: Bool, patch: TaskPatch, store: ChatStore) -> String {
        var details: [String] = []
        if new || patch.status != nil { details.append(t.status.label) }
        if let due = t.due, new || patch.due != nil { details.append(TaskDates.label(due)) }
        else if patch.due != nil { details.append("sem data") }
        // Nome sem "@": o aviso não deve acordar o responsável (mencionar acorda o bot).
        if let who = t.assignee, new || patch.assignee != nil { details.append("para " + store.displayName(for: who)) }
        if !new, patch.title != nil { details.append("título novo") }
        if !new, patch.notes != nil { details.append("notas atualizadas") }
        let title = t.title.replacingOccurrences(of: "*", with: "")
        return new ? "📋 Nova tarefa #\(t.id): **\(title)** · " + details.joined(separator: " · ")
                   : "📋 Tarefa #\(t.id) **\(title)** → " + details.joined(separator: " · ")
    }

    /// "#12 [andamento] Título · amanhã · @Robb" (para listas no terminal e nas ferramentas).
    public static func describe(_ t: ChatTask, store: ChatStore? = nil, now: Date = Date()) -> String {
        var parts = ["#\(t.id) [\(t.status.word)] \(t.title)"]
        if let due = t.due { parts.append(TaskDates.label(due, now: now)) }
        if let who = t.assignee { parts.append(store?.handle(for: who) ?? "@" + ChatNames.display(forKey: who)) }
        if !t.notes.isEmpty { parts.append("notas: " + t.notes.replacingOccurrences(of: "\n", with: " ").prefix(200)) }
        return parts.joined(separator: " · ")
    }

    /// Instruções para o bot, com as tarefas abertas (as dele primeiro). Vai no prompt dos bots sem ferramentas.
    public static func botHint(botKey: String, tasks: [ChatTask], store: ChatStore? = nil, now: Date = Date(),
                               limit: Int = 12) -> String {
        let key = ChatNames.normalize(botKey)
        let open = tasks.filter { $0.status != .done }
            .sorted { ($0.assignee == key ? 0 : 1, $0.due ?? "9999") < ($1.assignee == key ? 0 : 1, $1.due ?? "9999") }
        let list = open.prefix(limit).map { t -> String in
            var parts = ["#\(t.id) [\(t.status.word)] \(t.title.prefix(80))"]
            if let due = t.due { parts.append(TaskDates.label(due, now: now)) }
            if let who = t.assignee { parts.append(store?.handle(for: who) ?? "@" + ChatNames.display(forKey: who)) }
            return parts.joined(separator: " · ")
        }
        let more = open.count > limit ? "\n(+\(open.count - limit) tarefas abertas)" : ""
        return """
        Quadro de tarefas do chat (colunas: backlog, andamento, aguardando, feito). Para criar ou mover, \
        escreva na resposta uma linha por tarefa (cada linha vira um aviso no chat):
        [TAREFA nova] Título curto | data: AAAA-MM-DD, hoje ou amanhã | para: @nome | status: backlog
        [TAREFA #id] status: andamento   (aceita também data:, para:, titulo:, nota:)
        Mova a tarefa quando começar (andamento), quando depender de alguém (aguardando) e ao terminar (feito). \
        Hoje é \(TaskDates.string(from: now)).
        """ + (list.isEmpty ? "\nNenhuma tarefa aberta." : "\nTarefas abertas:\n" + list.joined(separator: "\n") + more)
    }
}
