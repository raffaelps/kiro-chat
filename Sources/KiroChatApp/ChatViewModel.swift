import Foundation
import KiroChatCore
import SwiftUI
import UserNotifications

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var channels: [ChannelInfo] = []
    @Published private(set) var bots: [BotInfo] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var unread: [String: Int] = [:]
    @Published var selectedChannel: String? = ChatNames.defaultChannel {
        didSet {
            guard oldValue != selectedChannel else { return }
            createDirectChannelIfNeeded()
            loadSelectedChannel()
        }
    }
    @Published var draft = "" {
        didSet { if draft != oldValue { suggestionIndex = 0 } }
    }
    @Published var sendAsAlert = false
    @Published var errorMessage: String?
    @Published var showSetup = false
    @Published var showNewChannel = false
    @Published var showAddBots = false
    /// Pedido de apagar mensagens aguardando confirmação.
    @Published var purgeRequest: PurgeRequest?
    /// Mensagens de canal aberto: quem ouviu sem responder e quem ainda vai ouvir.
    @Published private(set) var listeners: [Int64: ChatStore.Listeners] = [:]
    /// Pede o nome do humano (primeiro uso ou "Alterar meu nome").
    @Published var showNamePrompt = false
    /// Bot cuja tela de gatilho está aberta.
    @Published var triggerSheetBot: BotInfo?
    @Published private(set) var triggers: [String: WakeTrigger] = [:]
    @Published private(set) var backgroundDispatch = BackgroundDispatcher.isInstalled
    /// "Parar bots": nenhum gatilho dispara (vale também para o despachante em segundo plano).
    @Published private(set) var botsPaused = false
    @Published private(set) var maxBotHops = ChatStore.defaultMaxBotHops
    @Published var now = Date()

    /// Nome como o humano digitou (ex: "Raffael"); a chave interna é `me`.
    @Published private(set) var humanName: String
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    let store: ChatStore?
    private var dispatcher: WakeDispatcher?
    private var timer: Timer?
    private var lastNotifiedId: Int64 = 0

    var me: String { ChatNames.normalize(humanName) }

    /// O humano já escolheu o nome (senão, o app pergunta no primeiro uso).
    var hasChosenName: Bool { UserDefaults.standard.string(forKey: "humanName") != nil }

    var mcpBinaryPath: String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "kiro-chat-mcp"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("kiro-chat-mcp")
        return sibling?.path ?? "kiro-chat-mcp"
    }

    var databasePath: String { store?.url.path ?? ChatPaths.defaultDatabaseURL.path }

    init() {
        humanName = ChatNames.displayName(fromRaw: UserDefaults.standard.string(forKey: "humanName") ?? "Humano")
        notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        do {
            store = try ChatStore()
        } catch {
            store = nil
            errorMessage = "Não foi possível abrir o banco do chat: \(error)"
        }
        guard let store else { return }
        _ = try? store.registerBot(humanName, description: "Humano operando o Kiro Chat", isHuman: true)
        lastNotifiedId = (try? store.maxMessageId()) ?? 0
        // Primeiro uso: pergunta como o humano quer aparecer no chat.
        if UserDefaults.standard.string(forKey: "humanName") == nil { showNamePrompt = true }
        updateDispatcher()
        refresh()
        loadSelectedChannel()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Atualização (polling do SQLite compartilhado)

    func refresh() {
        guard let store else { return }
        now = Date()
        do {
            let newChannels = try store.listChannels()
            if newChannels != channels { channels = newChannels }
            let newBots = try store.listBots()
            if newBots != bots { bots = newBots }
            let newTriggers = Dictionary(try store.listTriggers().map { ($0.bot, $0) }, uniquingKeysWith: { a, _ in a })
            if newTriggers != triggers { triggers = newTriggers }
            if store.wakePaused != botsPaused { botsPaused = store.wakePaused }
            if store.maxBotHops != maxBotHops { maxBotHops = store.maxBotHops }

            if let channel = selectedChannel {
                let after = messages.last?.id ?? 0
                let fresh = try store.messages(channel: channel, afterId: after, limit: 500)
                if !fresh.isEmpty { messages.append(contentsOf: fresh) }
                if let last = messages.last, NSApp.isActive {
                    try store.setReadCursor(bot: me, channel: channel, lastId: last.id)
                    try store.markMentionsRead(for: me, messageIds: fresh.filter { $0.mentions.contains(me) }.map(\.id))
                }
            }
            if channels.first(where: { $0.name == selectedChannel })?.isOpen == true {
                let ids = messages.suffix(200).filter { $0.sender == me }.map(\.id)
                let fresh = try store.listeners(for: ids)
                if fresh != listeners { listeners = fresh }
            } else if !listeners.isEmpty {
                listeners = [:]
            }
            let newUnread = try store.unreadCounts(for: me)
            if newUnread != unread { unread = newUnread }
            try notifyIfNeeded()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func loadSelectedChannel() {
        guard let store, let channel = selectedChannel else { messages = []; return }
        do {
            messages = try store.messages(channel: channel, limit: 300)
            if let last = messages.last { try store.setReadCursor(bot: me, channel: channel, lastId: last.id) }
            unread = try store.unreadCounts(for: me)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func notifyIfNeeded() throws {
        guard let store else { return }
        let fresh = try store.messages(afterId: lastNotifiedId, limit: 100)
        guard let last = fresh.last else { return }
        lastNotifiedId = last.id
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let directs = Set(channels.filter(\.isDirect).map(\.name))
        // Conversa direta: toda mensagem do bot avisa (como uma DM), se você não estiver olhando para ela.
        for m in fresh where m.sender != me && m.kind != .system
            && (m.mentions.contains(me) || m.kind == .alert
                || (directs.contains(m.channel) && !(NSApp.isActive && selectedChannel == m.channel))) {
            let content = UNMutableNotificationContent()
            content.title = m.kind == .alert ? "🔔 Alerta de @\(m.senderName)"
                : directs.contains(m.channel) ? "\(m.senderName) (conversa direta)" : "@\(m.senderName) em #\(m.channel)"
            content.body = m.text
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "msg-\(m.id)", content: content, trigger: nil))
        }
    }

    // MARK: - Ações

    func send() {
        guard let store, let channel = selectedChannel else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Atalhos: /parar e /retomar.
        switch text.lowercased() {
        case "/parar", "/stop": setBotsPaused(true); draft = ""; return
        case "/retomar", "/resume": setBotsPaused(false); draft = ""; return
        default: break
        }
        do {
            try store.post(channel: channel, sender: me, text: text, kind: sendAsAlert ? .alert : .message)
            draft = ""
            sendAsAlert = false
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Insere uma menção no rascunho. Aceita "Jon" ou "@Jon".
    /// Não duplica: se o bot já está mencionado no rascunho, só devolve o foco ao campo.
    func insertMention(_ handle: String) {
        let name = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        defer { focusComposer &+= 1 }
        if ChatNames.extractMentions(from: draft).contains(ChatNames.normalize(name)) { return }
        // Se o rascunho termina num "@parcial" (menu aberto), completa em vez de anexar.
        if mentionQuery != nil { return completeMention(name) }
        let sep = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        draft += "\(sep)@\(name) "
    }

    // MARK: - Autocomplete de @menções

    struct MentionSuggestion: Identifiable, Equatable {
        let key: String
        let handle: String
        let title: String
        let subtitle: String
        let online: Bool
        let isBroadcast: Bool
        var id: String { key }
    }

    /// Pede ao campo de texto para ganhar foco (incrementado a cada pedido).
    @Published var focusComposer = 0
    @Published var suggestionIndex = 0
    /// Esc fecha o menu até o usuário começar outra menção.
    @Published private var dismissedQueryDraft: String?

    /// Texto digitado depois do "@" no fim do rascunho (nil se não estiver digitando uma menção).
    var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil } // e-mail, etc.
        }
        let query = draft[draft.index(after: at)...]
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard query.allSatisfy({ allowed.contains($0) }) else { return nil }
        return String(query)
    }

    /// Bots para o menu: online primeiro, depois offline; filtra pelo que já foi digitado.
    var mentionSuggestions: [MentionSuggestion] {
        guard let q = mentionQuery?.lowercased(), dismissedQueryDraft != draft,
              let at = draft.lastIndex(of: "@") else { return [] }
        // Quem já foi mencionado no rascunho não aparece de novo.
        let already = Set(ChatNames.extractMentions(from: String(draft[..<at])))
        let matches = bots
            .filter { $0.name != me && !already.contains($0.name) }
            .filter { q.isEmpty || $0.name.hasPrefix(q) || $0.displayName.lowercased().hasPrefix(q) }
            .sorted { a, b in
                let ao = a.isOnline(now: now), bo = b.isOnline(now: now)
                return ao != bo ? ao : a.displayName.lowercased() < b.displayName.lowercased()
            }
            .map { b in
                MentionSuggestion(key: b.name, handle: b.handle, title: b.displayName,
                                  subtitle: b.description, online: b.isOnline(now: now), isBroadcast: false)
            }
        let all = "todos".hasPrefix(q) && !matches.isEmpty && already.isDisjoint(with: ChatNames.broadcast)
            ? [MentionSuggestion(key: "todos", handle: "@todos", title: "todos",
                                 subtitle: "Notifica todos os bots", online: true, isBroadcast: true)]
            : []
        return matches + all
    }

    func moveSuggestion(_ delta: Int) {
        let count = mentionSuggestions.count
        guard count > 0 else { return }
        suggestionIndex = (min(suggestionIndex, count - 1) + delta + count) % count
    }

    /// Completa a menção selecionada. Retorna false se o menu não estava aberto.
    @discardableResult
    func acceptSuggestion() -> Bool {
        let list = mentionSuggestions
        guard !list.isEmpty else { return false }
        completeMention(String(list[min(suggestionIndex, list.count - 1)].handle.dropFirst()))
        return true
    }

    func dismissSuggestions() { dismissedQueryDraft = draft }

    /// Troca o "@parcial" do fim do rascunho pela menção completa.
    func completeMention(_ name: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@\(name) "
        suggestionIndex = 0
        focusComposer &+= 1
    }

    /// Chave → handle de exibição ("jon" → "@Jon").
    var handles: [String: String] {
        Dictionary(bots.map { ($0.name, $0.handle) }, uniquingKeysWith: { a, _ in a })
    }

    func handle(for key: String) -> String {
        handles[key] ?? "@" + ChatNames.display(forKey: key)
    }

    /// Troca o nome do humano no chat (mantém a capitalização digitada, 1ª letra maiúscula).
    /// As mensagens e menções antigas passam para o nome novo.
    /// Retorna a mensagem de erro, ou nil se deu certo.
    @discardableResult
    func setHumanName(_ raw: String) -> String? {
        guard let store else { return "Banco indisponível." }
        do {
            let info = try store.renameBot(from: me, to: raw, description: "Humano operando o Kiro Chat", isHuman: true)
            humanName = info.displayName
            UserDefaults.standard.set(info.displayName, forKey: "humanName")
            loadSelectedChannel()
            refresh()
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Controle da conversa entre bots

    /// Para (ou retoma) todos os bots: ninguém é acordado e os gatilhos em execução são interrompidos.
    func setBotsPaused(_ paused: Bool) {
        do {
            try store?.setWakePaused(paused, by: me, channel: selectedChannel ?? ChatNames.defaultChannel)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Conversas diretas

    /// Abre (ou cria) a conversa direta com um bot e a seleciona.
    func openDirect(with bot: String) {
        do {
            selectedChannel = try store?.openDirectChannel(with: bot, by: me)
            refresh()
            focusComposer &+= 1
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Selecionar um bot em Participantes seleciona `dm-<bot>`; na primeira vez a conversa ainda não existe.
    private func createDirectChannelIfNeeded() {
        guard let store, let channel = selectedChannel, channel.hasPrefix("dm-"),
              !channels.contains(where: { $0.name == channel }) else { return }
        let bot = String(channel.dropFirst(3))
        guard bots.contains(where: { $0.name == bot && !$0.isHuman }) else { return }
        do {
            try store.openDirectChannel(with: bot, by: me)
            channels = try store.listChannels()
            focusComposer &+= 1
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Nome mostrado para uma conversa direta (o nome do bot, ex: "Jon").
    func directTitle(_ c: ChannelInfo) -> String {
        guard let dm = c.dmWith else { return "#\(c.name)" }
        return bots.first { $0.name == dm }?.displayName ?? ChatNames.display(forKey: dm)
    }

    func composerPlaceholder(for channel: String) -> String {
        guard let c = channels.first(where: { $0.name == channel }) else { return "Mensagem para #\(channel)" }
        if c.isDirect { return "Mensagem para \(directTitle(c))" }
        if c.isOpen { return "Mensagem para #\(channel) · todos os bots escutam" }
        return "Mensagem para #\(channel) · digite @ para chamar um bot"
    }

    /// Canal aberto: mensagens suas sem menção acordam todos os bots ao mesmo tempo.
    func setChannelOpen(_ channel: String, _ open: Bool) {
        do { try store?.setChannelOpen(channel, open, by: me); refresh() } catch { errorMessage = "\(error)" }
    }

    func setMaxBotHops(_ n: Int) {
        do { try store?.setMaxBotHops(n); refresh() } catch { errorMessage = "\(error)" }
    }

    // MARK: - Adicionar bots

    /// Coloca Bots do Kiro Crew no chat, com o primeiro nome deles, e cria o gatilho que os acorda
    /// (sem mexer em gatilhos que já existem). Retorna os nomes adicionados.
    @discardableResult
    func addCrewBots(_ crew: [KiroCrew.Bot], withTrigger: Bool) -> [String] {
        guard let store else { return [] }
        var added: [String] = []
        for b in crew {
            do {
                let desc = b.description.isEmpty ? b.label : b.description
                let info = try store.registerBot(KiroCrew.chatName(for: b), description: desc)
                if withTrigger, try store.trigger(for: info.name) == nil {
                    try store.saveTrigger(WakeTrigger(bot: info.name, command: KiroCrew.command(for: b), postReply: true))
                }
                added.append(info.displayName)
            } catch {
                errorMessage = "\(b.label): \(error)"
            }
        }
        refresh()
        return added
    }

    /// Adiciona um bot qualquer pelo nome. Retorna a mensagem de erro, ou nil se deu certo.
    func addBot(name: String, description: String) -> String? {
        guard let store else { return "Banco indisponível." }
        let key = ChatNames.normalize(name)
        if key == me { return "Esse é o seu nome no chat." }
        if bots.contains(where: { $0.name == key }) { return "\(ChatNames.displayName(fromRaw: name)) já está no chat." }
        do {
            let d = description.trimmingCharacters(in: .whitespaces)
            try store.registerBot(name, description: d.isEmpty ? nil : d)
            refresh()
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Gatilhos (acordar bots)

    func trigger(for bot: String) -> WakeTrigger? { triggers[bot] }

    func saveTrigger(_ t: WakeTrigger) {
        do { try store?.saveTrigger(t.sanitized); refresh() } catch { errorMessage = "\(error)" }
    }

    func deleteTrigger(bot: String) {
        do { try store?.deleteTrigger(bot: bot); refresh() } catch { errorMessage = "\(error)" }
    }

    func testTrigger(bot: String) {
        // Usa o despachante local mesmo se o de segundo plano estiver ativo.
        (dispatcher ?? store.map { WakeDispatcher(store: $0) })?.test(bot: bot, from: me)
    }

    func wakeLogs(bot: String) -> [WakeLogEntry] {
        (try? store?.wakeLogs(bot: bot, limit: 15)) ?? []
    }

    /// Liga/desliga o despachante em segundo plano (LaunchAgent), que funciona com o app fechado.
    func setBackgroundDispatch(_ on: Bool) {
        do {
            if on { try BackgroundDispatcher.install(binary: mcpBinaryPath) } else { try BackgroundDispatcher.uninstall() }
        } catch {
            errorMessage = "\(error)"
        }
        backgroundDispatch = BackgroundDispatcher.isInstalled
        updateDispatcher()
    }

    /// Com o despachante em segundo plano ativo, o app não precisa do seu.
    private func updateDispatcher() {
        guard let store else { return }
        if backgroundDispatch {
            dispatcher?.stop()
            dispatcher = nil
        } else if dispatcher == nil {
            let d = WakeDispatcher(store: store) { NSLog("[kiro-chat] %@", $0) }
            d.start()
            dispatcher = d
        }
    }

    func createChannel(_ name: String, topic: String) {
        guard let store else { return }
        do {
            let n = try store.createChannel(name, topic: topic)
            try store.post(channel: n, sender: "sistema", text: "📢 \(handle(for: me)) criou o canal #\(n).", kind: .system)
            refresh()
            selectedChannel = n
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Apagar mensagens

    struct PurgeRequest: Identifiable {
        let channel: String
        /// nil = todas as mensagens.
        let days: Int?
        let count: Int
        var id: String { "\(channel)-\(days ?? 0)" }
        var cutoff: Date? { days.map { Date().addingTimeInterval(-Double($0) * 86_400) } }
    }

    /// Prepara a confirmação: conta quantas mensagens serão apagadas.
    func requestPurge(channel: String, days: Int?) {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let count = (try? store?.countMessages(channel: channel, olderThan: cutoff)) ?? 0
        purgeRequest = PurgeRequest(channel: channel, days: days, count: count)
    }

    func purgeTitle(_ r: PurgeRequest) -> String {
        let place = channels.first { $0.name == r.channel }.map { $0.isDirect ? "da conversa com \(directTitle($0))" : "de #\(r.channel)" }
            ?? "de #\(r.channel)"
        guard let days = r.days else { return "Apagar todas as mensagens \(place)?" }
        return "Apagar as mensagens \(place) com mais de \(days) \(days == 1 ? "dia" : "dias")?"
    }

    func confirmPurge() {
        guard let store, let r = purgeRequest else { return }
        purgeRequest = nil
        do {
            let n = try store.deleteMessages(channel: r.channel, olderThan: r.cutoff)
            let what = r.days.map { "as mensagens com mais de \($0) \($0 == 1 ? "dia" : "dias")" } ?? "todas as mensagens"
            try store.post(channel: r.channel, sender: "sistema",
                           text: "🗑 \(humanName) apagou \(what) (\(n)).", kind: .system)
            if selectedChannel == r.channel { loadSelectedChannel() }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func removeBot(_ name: String) {
        guard let store else { return }
        try? store.removeBot(name)
        refresh()
    }
}
