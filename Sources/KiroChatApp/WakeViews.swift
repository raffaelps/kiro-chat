import AppKit
import KiroChatCore
import SwiftUI

// MARK: - Despachante em segundo plano (LaunchAgent)

/// Mantém `kiro-chat-mcp dispatch` rodando pelo launchd, para os gatilhos funcionarem com o app fechado.
enum BackgroundDispatcher {
    static let label = "dev.kirochat.dispatcher"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KiroChat/dispatcher.log")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func install(binary: String) throws {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw ChatStoreError.invalid("Binário kiro-chat-mcp não encontrado em \(binary).")
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "dispatch"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        if status != 0 {
            try? FileManager.default.removeItem(at: plistURL)
            throw ChatStoreError.invalid("launchctl bootstrap falhou (código \(status)).")
        }
    }

    static func uninstall() throws {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Nome do humano

struct NameSheet: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let firstRun: Bool
    @State private var name = ""
    @State private var error: String?

    private var preview: String {
        let d = ChatNames.displayName(fromRaw: name)
        let key = ChatNames.normalize(d)
        return key.isEmpty ? "" : "@" + (d.lowercased() == key ? d : key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(firstRun ? "Como você quer aparecer no chat?" : "Alterar meu nome")
                .font(.title2.bold())
            Text("Os bots vão te chamar por esse nome. Para trocar depois, clique no seu nome na lista de participantes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Seu nome", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if !preview.isEmpty {
                Text("Você aparecerá como **\(ChatNames.displayName(fromRaw: name))** e será mencionado com **\(preview)**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !firstRun {
                Text("Suas mensagens antigas passam para o nome novo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if !firstRun { Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(firstRun ? "Começar" : "Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(firstRun)
        .onAppear {
            if firstRun {
                name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
            } else {
                name = model.humanName
            }
        }
        .onChange(of: name) { error = nil }
    }

    private func save() {
        guard !preview.isEmpty else { return }
        if let e = model.setHumanName(name) { error = e } else { dismiss() }
    }
}

// MARK: - Gatilho de chamada

struct TriggerSheet: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let bot: BotInfo
    let existing: WakeTrigger?
    @State private var t: WakeTrigger
    @State private var logs: [WakeLogEntry] = []
    @State private var crewBots: [KiroCrew.Bot] = []
    @State private var crewKey = ""
    @State private var expandedLogs = Set<Int64>()

    init(bot: BotInfo, existing: WakeTrigger?) {
        self.bot = bot
        self.existing = existing
        var initial = existing ?? WakeTrigger(bot: bot.name, enabled: true)
        // Novo gatilho: se houver um Bot do Kiro Crew com o mesmo nome, já vem configurado.
        if existing == nil, KiroCrew.isInstalled, let match = KiroCrew.match(for: bot.name) {
            initial.command = KiroCrew.command(for: match)
            initial.postReply = true
        }
        _t = State(initialValue: initial)
    }

    /// Bot do Kiro Crew que o comando atual aciona (para mostrar no seletor).
    private func crewKey(in command: String) -> String {
        crewBots.first { KiroCrew.command(for: $0) == command }?.key ?? ""
    }

    private static let variables: [(String, String)] = [
        ("KIRO_CHAT_PROMPT", "Texto pronto para o bot: quem chamou, as mensagens e o que fazer"),
        ("KIRO_CHAT_BOT", "Nome do bot (\"Jon\"); KIRO_CHAT_BOT_KEY é a chave (\"jon\")"),
        ("KIRO_CHAT_FROM", "Quem chamou"),
        ("KIRO_CHAT_CHANNEL", "Canal da mensagem"),
        ("KIRO_CHAT_TEXT", "Texto da última mensagem"),
        ("KIRO_CHAT_MESSAGE_ID", "Id da última mensagem (para reply_to); KIRO_CHAT_MESSAGE_IDS lista todas"),
        ("KIRO_CHAT_COUNT", "Quantas menções foram agrupadas neste disparo"),
    ]

    private var templates: [(String, String)] {
        [
            ("Agente do kiro-cli (não serve para Bots do Kiro Crew)",
             "kiro-cli chat --no-interactive --agent \(bot.name) \"$KIRO_CHAT_PROMPT\""),
            ("Notificação do macOS (para testar)",
             "osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' \"Kiro Chat → $KIRO_CHAT_BOT\" \"$KIRO_CHAT_FROM: $KIRO_CHAT_TEXT\""),
            ("Script próprio", "~/kiro-bots/acordar.sh \"$KIRO_CHAT_BOT_KEY\""),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Avatar(name: bot.displayName, key: bot.name, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gatilho de chamada — \(bot.handle)").font(.title2.bold())
                    Text("Quando \(bot.handle) for mencionado, o chat roda isto para acordá-lo. Ninguém fica escutando com modelo: não gasta tokens nem prende sessão.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Acordar \(bot.handle) quando for mencionado", isOn: $t.enabled)

            Picker("", selection: $t.kind) {
                Text("Comando").tag(WakeTrigger.Kind.command)
                Text("Webhook").tag(WakeTrigger.Kind.webhook)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if t.kind == .command {
                if KiroCrew.isInstalled {
                    HStack {
                        Text("Bot do Kiro Crew")
                        Picker("", selection: $crewKey) {
                            Text("Nenhum (comando próprio)").tag("")
                            ForEach(crewBots) { b in
                                Text(b.displayName.isEmpty ? b.key : "\(b.displayName)  (\(b.key))").tag(b.key)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        .onChange(of: crewKey) {
                            guard let b = crewBots.first(where: { $0.key == crewKey }) else { return }
                            t.command = KiroCrew.command(for: b)
                            t.postReply = true
                        }
                        Spacer()
                    }
                    .help("Monta o comando com a chave interna do Bot (o nome exibido, como \"Jon - Chief\", não funciona em --agent).")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Comando (roda no zsh, a partir da sua pasta de usuário)").font(.callout)
                        Spacer()
                        Menu("Modelos") {
                            ForEach(templates, id: \.0) { item in
                                Button(item.0) { t.command = item.1 }
                            }
                        }
                        .fixedSize()
                    }
                    CodeEditor(text: $t.command)
                        .padding(4)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    Toggle("Publicar no chat o que o comando responder, como mensagem de \(bot.handle)", isOn: $t.postReply)
                        .help("O que o comando imprimir vira a resposta do bot, no canal de quem chamou. Assim o bot não precisa de ferramentas para responder.")
                    DisclosureGroup("Variáveis disponíveis no comando") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            ForEach(Self.variables, id: \.0) { v in
                                GridRow {
                                    Text("$" + v.0).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(v.1).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                        Text("O texto das mensagens só chega por essas variáveis, nunca é colado no comando. Use sempre entre aspas: \"$KIRO_CHAT_PROMPT\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://…", text: $t.url).textFieldStyle(.roundedBorder)
                    Text("Recebe um POST JSON com bot, botName, prompt e messages (id, channel, from, text…).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                Stepper("Esperar \(Int(t.delaySeconds)) s antes", value: $t.delaySeconds, in: 0...300, step: 1)
                    .help("Dá tempo de o bot pegar a menção sozinho, se já estiver ativo (ex: em wait_for_mentions). Nesse caso o gatilho não dispara.")
                Stepper("No máximo \(t.maxPerHour) por hora", value: $t.maxPerHour, in: 1...500)
                    .help("Evita bots se chamando sem parar. Menções que chegam juntas viram um disparo só.")
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("A espera dá tempo de o bot pegar a menção sozinho, se já estiver ativo; nesse caso o gatilho não dispara. Menções que chegam juntas viram um disparo só, e o limite por hora evita bots se chamando sem parar.")
            }

            Divider()

            HStack {
                Text("Últimos disparos").font(.headline)
                Spacer()
                Button {
                    model.saveTrigger(t)
                    model.testTrigger(bot: bot.name)
                } label: {
                    Label("Salvar e testar", systemImage: "play.fill")
                }
                .disabled(!t.isConfigured)
            }
            logList

            if !model.backgroundDispatch {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Agora os gatilhos só disparam com o Kiro Chat aberto.")
                        .font(.caption)
                    Spacer()
                    Button("Rodar também com o app fechado") { model.setBackgroundDispatch(true) }
                        .controlSize(.small)
                }
            }

            HStack {
                if existing != nil {
                    Button("Remover gatilho", role: .destructive) {
                        model.deleteTrigger(bot: bot.name)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    model.saveTrigger(t)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!t.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            logs = model.wakeLogs(bot: bot.name)
            crewBots = KiroCrew.isInstalled ? KiroCrew.bots() : []
            crewKey = crewKey(in: t.command)
        }
        .onChange(of: t.command) { crewKey = crewKey(in: t.command) }
        .onChange(of: model.now) { logs = model.wakeLogs(bot: bot.name) }
    }

    @ViewBuilder private var logList: some View {
        if logs.isEmpty {
            Text("Nenhum disparo ainda.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(logs) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if l.finishedAt == nil {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: l.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(l.succeeded ? .green : .red)
                                }
                                Text(ChatFormat.time(l.startedAt)).font(.caption.monospacedDigit())
                                if l.isTest { Text("teste").font(.caption2).foregroundStyle(.secondary) }
                                Text(l.status.isEmpty ? "rodando…" : l.status).font(.caption.bold())
                                if !l.messageIds.isEmpty && !l.isTest {
                                    Text(l.messageIds.map { "#\($0)" }.joined(separator: " "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !l.output.isEmpty {
                                let full = expandedLogs.contains(l.id)
                                Text(l.output.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(full ? nil : 4)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: full)
                                Button(full ? "Recolher" : "Ver saída completa") {
                                    if full { expandedLogs.remove(l.id) } else { expandedLogs.insert(l.id) }
                                }
                                .buttonStyle(.link)
                                .font(.caption2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 56, maxHeight: expandedLogs.isEmpty ? 130 : 260)
        }
    }
}

// MARK: - Editor de comando

/// Editor de texto para comandos de shell: sem aspas "inteligentes", travessões ou correção automática
/// (o TextEditor do SwiftUI troca ' e " por aspas tipográficas e quebra o comando).
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

extension WakeTrigger {
    /// Aspas tipográficas coladas de outro app quebram o shell; troca pelas retas.
    var sanitized: WakeTrigger {
        var t = self
        let map: [Character: Character] = ["“": "\"", "”": "\"", "„": "\"", "‘": "'", "’": "'", "‚": "'"]
        t.command = String(t.command.map { map[$0] ?? $0 })
        t.url = t.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }
}
