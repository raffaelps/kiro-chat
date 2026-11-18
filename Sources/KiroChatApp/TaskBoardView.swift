import KiroChatCore
import SwiftUI

/// Filtro do quadro por data.
enum TaskDayFilter: String, CaseIterable, Identifiable {
    case all, today, tomorrow, future, undated
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Todas"
        case .today: return "Hoje"
        case .tomorrow: return "Amanhã"
        case .future: return "Futuras"
        case .undated: return "Sem data"
        }
    }

    /// "Hoje" inclui as atrasadas que ainda não foram feitas.
    func includes(_ t: ChatTask, now: Date) -> Bool {
        let day = t.day(now: now)
        switch self {
        case .all: return true
        case .today: return day == .today || (day == .overdue && t.status != .done)
        case .tomorrow: return day == .tomorrow
        case .future: return day == .future
        case .undated: return day == .none
        }
    }
}

extension TaskStatus {
    var icon: String {
        switch self {
        case .backlog: return "tray"
        case .inProgress: return "play.circle"
        case .waiting: return "pause.circle"
        case .done: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .backlog: return Theme.secondaryText
        case .inProgress: return Theme.accent
        case .waiting: return Theme.warning
        case .done: return Color(red: 0.36, green: 0.80, blue: 0.52)
        }
    }
}

// MARK: - Barra lateral

/// Entrada "Tarefas" na barra lateral, com o que vence hoje.
struct TasksRow: View {
    @EnvironmentObject var model: ChatViewModel

    var body: some View {
        let open = model.tasks.filter { $0.status != .done }
        let overdue = open.filter { $0.day(now: model.now) == .overdue }.count
        let today = open.filter { $0.day(now: model.now) == .today }.count
        let subtitle = [today > 0 ? "\(today) para hoje" : nil, overdue > 0 ? "\(overdue) atrasada\(overdue == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        SidebarRow(selected: model.showBoard, action: { model.showBoard = true }) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tarefas").font(.system(size: 13, weight: .semibold))
                    Text(subtitle.isEmpty ? (open.isEmpty ? "Quadro dos bots" : "\(open.count) abertas") : subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(overdue > 0 ? Theme.warning : Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if today + overdue > 0 {
                    Text("\(today + overdue)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(overdue > 0 ? Theme.warning : Theme.accent))
                        .foregroundStyle(overdue > 0 ? Color.black : Color.white)
                }
            }
        }
    }
}

// MARK: - Quadro

struct TaskBoardView: View {
    @EnvironmentObject var model: ChatViewModel
    @Binding var showSidebar: Bool
    @AppStorage("taskDayFilter") private var filterRaw = TaskDayFilter.all.rawValue
    @AppStorage("taskAssigneeFilter") private var assigneeFilter = ""

    static let minColumnWidth: CGFloat = 230

    private var filter: TaskDayFilter { TaskDayFilter(rawValue: filterRaw) ?? .all }

    private var visible: [ChatTask] {
        model.tasks.filter { filter.includes($0, now: model.now) && (assigneeFilter.isEmpty || $0.assignee == assigneeFilter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            // Colunas dividem a largura; em janela estreita, mantêm um mínimo e rolam para o lado.
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let width = max(Self.minColumnWidth, (geo.size.width - 12 - spacing * 3) / 4)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            TaskColumn(status: status, tasks: column(status))
                                .frame(width: width)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: geo.size.height)
                }
                .scrollIndicators(.automatic)
            }
            .padding(.top, 6)
        }
    }

    /// Tarefas de uma coluna: as abertas pela data (sem data no fim); as feitas, das mais recentes.
    private func column(_ status: TaskStatus) -> [ChatTask] {
        let list = visible.filter { $0.status == status }
        if status == .done { return list.sorted { $0.updatedAt > $1.updatedAt } }
        return list.sorted { ($0.due ?? "9999", $0.id) < ($1.due ?? "9999", $1.id) }
    }

    private var assigneeOptions: [BotInfo] {
        let used = Set(model.tasks.compactMap(\.assignee))
        return model.bots.filter { used.contains($0.name) || !$0.isHuman || $0.name == model.me }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "sidebar.left", help: showSidebar ? "Esconder barra lateral" : "Mostrar barra lateral") {
                showSidebar.toggle()
            }
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tarefas").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Arraste entre as colunas · os bots também criam e movem")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                .layoutPriority(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .themeCard(Theme.card, radius: 22)

            Spacer(minLength: 8)

            Button {
                model.taskEditor = TaskEditorRequest(status: .backlog, due: newTaskDue)
            } label: {
                Label("Nova tarefa", systemImage: "plus").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .fixedSize()
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .help("Nova tarefa (⇧⌘T)")
        }
        .padding(.leading, showSidebar ? 6 : 70)
        .padding(.trailing, 6)
        .frame(height: 48)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Data", selection: $filterRaw) {
                ForEach(TaskDayFilter.allCases) { f in Text(f.label).tag(f.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                Picker("Responsável", selection: $assigneeFilter) {
                    Text("Todos").tag("")
                    ForEach(assigneeOptions) { b in Text(b.displayName).tag(b.name) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(assigneeFilter.isEmpty ? "Todos" : model.bots.first { $0.name == assigneeFilter }?.displayName
                          ?? ChatNames.display(forKey: assigneeFilter),
                      systemImage: "person.crop.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(Theme.secondaryText)
            .help("Mostrar só as tarefas de um responsável")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    /// Com o filtro "Hoje" ou "Amanhã", a tarefa nova já nasce com essa data.
    private var newTaskDue: String? {
        switch filter {
        case .today: return TaskDates.parse("hoje")
        case .tomorrow: return TaskDates.parse("amanhã")
        default: return nil
        }
    }
}

/// Uma coluna do Kanban: recebe cartões arrastados de outras colunas.
struct TaskColumn: View {
    @EnvironmentObject var model: ChatViewModel
    let status: TaskStatus
    let tasks: [ChatTask]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: status.icon).foregroundStyle(status.tint)
                Text(status.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                Spacer()
                Button {
                    model.taskEditor = TaskEditorRequest(status: status)
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .help("Nova tarefa em \(status.label)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tasks) { t in
                        TaskCard(task: t)
                            .draggable(String(t.id)) {
                                TaskCard(task: t).frame(width: 240).environmentObject(model)
                            }
                    }
                    if tasks.isEmpty {
                        Text(targeted ? "Solte aqui" : "Nenhuma tarefa")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .themeCard(targeted ? Theme.selection : Theme.panel,
                   stroke: targeted ? Theme.accent.opacity(0.7) : Theme.stroke)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap { Int64($0) }
            for id in ids { model.moveTask(id, to: status) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

/// Cartão de uma tarefa: título, data, responsável. Clique para editar.
struct TaskCard: View {
    @EnvironmentObject var model: ChatViewModel
    let task: ChatTask
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(task.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                Text(Linkify.attributed(task.title))
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(task.status == .done, color: Theme.secondaryText)
                    .foregroundStyle(task.status == .done ? Theme.secondaryText : Color.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !task.notes.isEmpty {
                Text(Linkify.attributed(task.notes))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let due = task.due { DueChip(due: due, done: task.status == .done).layoutPriority(1) }
                Spacer(minLength: 0)
                if let who = task.assignee {
                    let bot = model.bots.first { $0.name == who }
                    HStack(spacing: 4) {
                        Avatar(name: bot?.displayName ?? ChatNames.display(forKey: who), key: who,
                               isHuman: bot?.isHuman ?? false, size: 18)
                        Text(bot?.displayName ?? ChatNames.display(forKey: who))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(hover ? Theme.cardHover : Theme.card, radius: 10)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.taskEditor = TaskEditorRequest(task: task) }
        .help(helpText)
        .contextMenu {
            ForEach(TaskStatus.allCases.filter { $0 != task.status }, id: \.self) { s in
                Button("Mover para \(s.label)") { model.moveTask(task.id, to: s) }
            }
            Divider()
            Button("Editar…") { model.taskEditor = TaskEditorRequest(task: task) }
            Button("Apagar", role: .destructive) { model.deleteTask(task.id) }
        }
    }

    private var helpText: String {
        let created = "Criada por \(model.handle(for: task.createdBy)) \(task.createdAt.formatted(.relative(presentation: .named).locale(Theme.locale)))"
        guard task.updatedBy != task.createdBy || task.updatedAt.timeIntervalSince(task.createdAt) > 1 else { return created }
        return created + "\nAlterada por \(model.handle(for: task.updatedBy)) \(task.updatedAt.formatted(.relative(presentation: .named).locale(Theme.locale)))"
    }
}

/// Data da tarefa: "hoje", "amanhã", "20/11"; atrasada em destaque.
struct DueChip: View {
    @EnvironmentObject var model: ChatViewModel
    let due: String
    var done = false

    var body: some View {
        let day = TaskDay.of(due, now: model.now)
        let color: Color = done ? Theme.tertiaryText
            : day == .overdue ? Color(red: 1, green: 0.42, blue: 0.42)
            : day == .today ? Theme.accent
            : day == .tomorrow ? Theme.warning : Theme.secondaryText
        Label(day == .overdue && !done ? "atrasada · " + TaskDates.label(due, now: model.now)
                  : TaskDates.label(due, now: model.now),
              systemImage: "calendar")
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Criar / editar

struct TaskSheet: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let request: TaskEditorRequest

    @State private var title = ""
    @State private var notes = ""
    @State private var status: TaskStatus = .backlog
    @State private var assignee = ""
    @State private var hasDue = false
    @State private var dueDate = Date()
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.task.map { "Tarefa #\($0.id)" } ?? "Nova tarefa").font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Título").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                TextField("O que precisa ser feito", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .themeCard(Theme.card, radius: 8)
                    // Enter salva (título é uma linha só; o texto quebra sozinho na tela).
                    .onKeyPress(keys: [.return]) { _ in
                        if canSave { save() }
                        return .handled
                    }
                LinkList(text: title)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Status").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    Picker("Status", selection: $status) {
                        ForEach(TaskStatus.allCases, id: \.self) { s in Label(s.label, systemImage: s.icon).tag(s) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Responsável").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    Picker("Responsável", selection: $assignee) {
                        Text("Ninguém").tag("")
                        ForEach(people) { b in Text(b.name == model.me ? "\(b.displayName) (você)" : b.displayName).tag(b.name) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Data").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) {
                    Toggle("Com data", isOn: $hasDue).toggleStyle(.checkbox)
                    if hasDue {
                        DatePicker("Data", selection: $dueDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .environment(\.locale, Theme.locale)
                    }
                    Spacer()
                    Button("Hoje") { setDue(0) }.controlSize(.small)
                    Button("Amanhã") { setDue(1) }.controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notas").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                TextEditor(text: $notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .themeCard(Theme.card, radius: 8)
                LinkList(text: notes)
            }

            if let t = request.task {
                Text("Criada por \(model.handle(for: t.createdBy)) · alterada por \(model.handle(for: t.updatedBy)) \(t.updatedAt.formatted(.relative(presentation: .named).locale(Theme.locale)))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }

            HStack {
                if request.task != nil {
                    Button("Apagar", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.task == nil ? "Criar" : "Salvar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 580)
        .onAppear(perform: load)
        .confirmationDialog("Apagar a tarefa #\(request.task?.id ?? 0)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                if let t = request.task { model.deleteTask(t.id) }
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Isso não pode ser desfeito.")
        }
    }

    /// Bots e humanos que podem ser responsáveis (você incluído).
    private var people: [BotInfo] {
        model.bots.sorted { ($0.name == model.me ? 0 : 1, $0.displayName) < ($1.name == model.me ? 0 : 1, $1.displayName) }
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func setDue(_ days: Int) {
        hasDue = true
        dueDate = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private func load() {
        if let t = request.task {
            title = t.title
            notes = t.notes
            status = t.status
            assignee = t.assignee ?? ""
            if let due = t.due, let d = TaskDates.date(from: due) { hasDue = true; dueDate = d }
        } else {
            status = request.status
            if let due = request.due, let d = TaskDates.date(from: due) { hasDue = true; dueDate = d }
        }
    }

    private func save() {
        let oneLine = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        model.saveTask(id: request.task?.id, title: oneLine, notes: notes, status: status,
                       assignee: assignee.isEmpty ? nil : assignee,
                       due: hasDue ? TaskDates.string(from: dueDate) : nil)
        dismiss()
    }
}

/// Links clicáveis encontrados num texto que está sendo editado (o campo em si não abre links).
struct LinkList: View {
    let text: String

    var body: some View {
        let urls = Linkify.urls(in: text)
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(urls, id: \.self) { url in
                    Link(destination: url) {
                        Label(Linkify.short(url), systemImage: "link")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(url.absoluteString)
                }
            }
            .foregroundStyle(Theme.accent)
            .padding(.leading, 2)
        }
    }
}

/// Links em textos de tarefas: `[texto](url)` do Markdown e URLs soltas (https://…, www.…).
enum Linkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// URLs do texto, sem repetir, na ordem em que aparecem.
    static func urls(in text: String) -> [URL] {
        var seen = Set<URL>()
        return attributed(text).runs.compactMap(\.link).filter { seen.insert($0).inserted }
    }

    /// Markdown inline (negrito, código, [texto](url)) + URLs soltas viram links.
    static func attributed(_ text: String) -> AttributedString {
        var attr = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let plain = String(attr.characters)
        let ns = plain as NSString
        for match in detector?.matches(in: plain, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let url = match.url, let r = Range(match.range, in: plain) else { continue }
            let start = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let len = plain.distance(from: r.lowerBound, to: r.upperBound)
            let a = attr.characters.index(attr.startIndex, offsetBy: start)
            let b = attr.characters.index(a, offsetBy: len)
            if attr[a..<b].runs.contains(where: { $0.link != nil }) { continue }
            attr[a..<b].link = url
        }
        for run in attr.runs where run.link != nil {
            attr[run.range].foregroundColor = Theme.accent
            attr[run.range].underlineStyle = .single
        }
        return attr
    }

    /// "github.com/org/repo/pull/42" — sem o https:// para caber na linha.
    static func short(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}
