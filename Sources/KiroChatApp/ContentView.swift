import KiroChatCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ChatViewModel
    @EnvironmentObject var updater: Updater
    @State private var showSidebar = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showSidebar {
                VStack(spacing: 0) {
                    // Faixa dos botões da janela (fechar, minimizar, zoom), que ficam sobre o conteúdo.
                    Color.clear.frame(height: 30)
                    Sidebar()
                }
                .frame(width: 272)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Group {
                if let channel = model.selectedChannel {
                    ChannelView(channel: channel, showSidebar: $showSidebar)
                } else {
                    ContentUnavailableView("Escolha um canal", systemImage: "number")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeOut(duration: 0.18), value: showSidebar)
        .onAppear { updater.start() }
        .sheet(isPresented: $updater.showSheet) { UpdateSheet().environmentObject(updater) }
        .sheet(isPresented: $model.showSetup) { SetupView().environmentObject(model) }
        .sheet(isPresented: $model.showNewChannel) { NewChannelView().environmentObject(model) }
        .sheet(isPresented: $model.showAddBots) { AddBotsView().environmentObject(model) }
        .confirmationDialog(model.purgeRequest.map(model.purgeTitle) ?? "",
                            isPresented: Binding(get: { model.purgeRequest != nil },
                                                 set: { if !$0 { model.purgeRequest = nil } }),
                            titleVisibility: .visible) {
            if let r = model.purgeRequest, r.count > 0 {
                Button("Apagar \(r.count) \(r.count == 1 ? "mensagem" : "mensagens")", role: .destructive) { model.confirmPurge() }
            }
            Button("Cancelar", role: .cancel) { model.purgeRequest = nil }
        } message: {
            if let r = model.purgeRequest {
                Text(r.count == 0 ? "Não há mensagens para apagar." : "Isso não pode ser desfeito.")
            }
        }
        .sheet(isPresented: $model.showNamePrompt) {
            NameSheet(firstRun: !model.hasChosenName).environmentObject(model)
        }
        .sheet(item: $model.triggerSheetBot) { bot in
            TriggerSheet(bot: bot, existing: model.trigger(for: bot.name)).environmentObject(model)
        }
        .alert("Erro", isPresented: Binding(get: { model.errorMessage != nil },
                                           set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Apagar mensagens

/// Menu "Apagar mensagens": antigas (1, 7 ou 30 dias) ou todas. Sempre pede confirmação.
struct PurgeMenu: View {
    @EnvironmentObject var model: ChatViewModel
    let channel: String
    var compact = false
    var title = "Apagar mensagens"

    var body: some View {
        if compact {
            Menu { items } label: {
                Image(systemName: "trash").font(.system(size: 14, weight: .medium))
            }
            .help("Apagar mensagens antigas ou todas deste canal")
        } else {
            Menu(title) { items }
        }
    }

    @ViewBuilder private var items: some View {
        Button("Com mais de 1 dia") { model.requestPurge(channel: channel, days: 1) }
        Button("Com mais de 7 dias") { model.requestPurge(channel: channel, days: 7) }
        Button("Com mais de 30 dias") { model.requestPurge(channel: channel, days: 30) }
        Divider()
        Button("Todas", role: .destructive) { model.requestPurge(channel: channel, days: nil) }
    }
}

// MARK: - Sidebar

/// Linha clicável da barra lateral: cartão arredondado, destacado quando selecionado.
struct SidebarRow<Content: View>: View {
    var selected = false
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.selection : (hover && action != nil ? Theme.card : .clear)))
            .contentShape(Rectangle())
            .onTapGesture { action?() }
            .onHover { hover = $0 }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: ChatViewModel
    @State private var search = ""

    private func matches(_ s: String) -> Bool { search.isEmpty || s.localizedCaseInsensitiveContains(search) }

    var body: some View {
        let others = model.bots.filter { $0.name != model.me }
        let online = others.filter { !$0.isHuman && $0.isOnline(now: model.now) }.count
        let total = others.filter { !$0.isHuman }.count
        let channels = model.channels.filter { !$0.isDirect && matches($0.name) }
        let bots = others.filter { matches($0.displayName) || matches($0.description) }

        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kiro Chat").font(.system(size: 15, weight: .semibold))
                    Text("\(online) de \(total) bots online")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                IconButton(systemName: "plus", help: "Adicionar bots ao chat (⇧⌘B)") { model.showAddBots = true }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                TextField("Buscar canais e bots…", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .themeCard(Theme.card, radius: 10)
            .padding(.horizontal, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Canais") {
                        Button { model.showNewChannel = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.tertiaryText)
                            .help("Novo canal (⇧⌘N)")
                    }
                    ForEach(channels) { c in channelRow(c) }

                    SectionTitle("Bots")
                    if bots.isEmpty {
                        Text(search.isEmpty ? "Nenhum bot no chat ainda." : "Nada encontrado.")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 10)
                    }
                    ForEach(bots) { bot in botRow(bot) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            UpdateCard()
            Rectangle().fill(Theme.stroke).frame(height: 1)
            if let me = model.bots.first(where: { $0.name == model.me }) {
                meRow(me)
            }
        }
        .themeCard(Theme.panel)
    }

    private func channelRow(_ c: ChannelInfo) -> some View {
        SidebarRow(selected: model.selectedChannel == c.name, action: { model.selectedChannel = c.name }) {
            HStack(spacing: 10) {
                Image(systemName: c.isOpen ? "megaphone.fill" : "number")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(c.isOpen ? "Todos os bots escutam" : (c.topic.isEmpty ? "Canal" : c.topic))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let n = model.unread[c.name], n > 0, c.name != model.selectedChannel { UnreadBadge(count: n) }
            }
        }
        .contextMenu {
            Toggle("Canal aberto (todos os bots escutam)",
                   isOn: Binding(get: { c.isOpen }, set: { model.setChannelOpen(c.name, $0) }))
            Divider()
            PurgeMenu(channel: c.name)
        }
    }

    /// Cada bot é também a conversa direta com ele: clicar seleciona `dm-<bot>`.
    private func botRow(_ bot: BotInfo) -> some View {
        let dm = bot.directChannel
        let hasDM = model.channels.contains { $0.name == dm }
        return SidebarRow(selected: !bot.isHuman && model.selectedChannel == dm,
                          action: bot.isHuman ? nil : { model.selectedChannel = dm }) {
            HStack(spacing: 10) {
                BotRow(bot: bot)
                Spacer(minLength: 0)
                if !bot.isHuman, let n = model.unread[dm], n > 0, dm != model.selectedChannel { UnreadBadge(count: n) }
            }
        }
        .help(bot.isHuman ? bot.description
              : bot.description.isEmpty ? "Clique para conversar só com \(bot.displayName)"
              : "\(bot.description)\nClique para conversar só com \(bot.displayName)")
        .contextMenu {
            Button("Mencionar \(bot.handle)") { model.insertMention(bot.handle) }
            if !bot.isHuman {
                Button("Gatilho de chamada…") { model.triggerSheetBot = bot }
                if hasDM {
                    Divider()
                    PurgeMenu(channel: dm, title: "Apagar mensagens da conversa")
                }
                Divider()
                Button("Remover do chat", role: .destructive) { model.removeBot(bot.name) }
            }
        }
    }

    /// Você, no rodapé: clicar não faz nada; nome pelo menu de contexto ou em Ajustes.
    private func meRow(_ me: BotInfo) -> some View {
        HStack(spacing: 10) {
            Avatar(name: me.displayName, key: me.name, isHuman: true, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(me.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Você").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ajustes (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Alterar meu nome…") { model.showNamePrompt = true }
        }
    }
}

extension BotInfo {
    /// Canal da conversa direta com este bot (`dm-<bot>`).
    var directChannel: String { ChatStore.directChannelName(for: name) }
}

struct BotRow: View {
    @EnvironmentObject var model: ChatViewModel
    let bot: BotInfo

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: bot.displayName, key: bot.name, isHuman: bot.isHuman, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(bot.isOnline(now: model.now) ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(bot.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if bot.name != model.me, let t = model.trigger(for: bot.name), t.enabled {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                            .help("Tem gatilho: é acordado quando for mencionado")
                    }
                }
                if !bot.description.isEmpty {
                    Text(bot.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Canal

struct ChannelView: View {
    @EnvironmentObject var model: ChatViewModel
    let channel: String
    @Binding var showSidebar: Bool

    var info: ChannelInfo? { model.channels.first { $0.name == channel } }

    var body: some View {
        VStack(spacing: 0) {
            ChannelHeader(channel: channel, info: info, showSidebar: $showSidebar)
            if model.botsPaused {
                Banner(systemName: "stop.circle.fill", text: "Bots parados: menções não acordam ninguém.",
                       button: "Retomar bots") { model.setBotsPaused(false) }
            }
            if let dm = info?.dmWith, model.trigger(for: dm)?.enabled != true,
               let bot = model.bots.first(where: { $0.name == dm }) {
                Banner(systemName: "bolt.slash",
                       text: "\(bot.displayName) não tem gatilho de chamada: ele só responde aqui se já estiver rodando.",
                       button: "Configurar gatilho") { model.triggerSheetBot = bot }
            }
            MessageList()
            Composer(channel: channel)
        }
    }
}

/// Aviso em cartão, logo abaixo do cabeçalho.
struct Banner: View {
    let systemName: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName).foregroundStyle(Theme.warning)
            Text(text).font(.system(size: 13))
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .themeCard(Theme.warning.opacity(0.10), radius: 12, stroke: Theme.warning.opacity(0.25))
        .frame(maxWidth: MessageList.maxWidth)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct ChannelHeader: View {
    @EnvironmentObject var model: ChatViewModel
    let channel: String
    let info: ChannelInfo?
    @Binding var showSidebar: Bool

    private var dmBot: BotInfo? { info?.dmWith.flatMap { dm in model.bots.first { $0.name == dm } } }

    private var title: String {
        guard let info else { return "#\(channel)" }
        return info.isDirect ? model.directTitle(info) : "#\(channel)"
    }

    private var subtitle: String {
        if let bot = dmBot {
            let status = bot.isOnline(now: model.now) ? "online"
                : bot.lastSeen.map { "visto \($0.formatted(.relative(presentation: .named).locale(Theme.locale)))" } ?? "offline"
            return "Conversa direta · \(status)"
        }
        if info?.isOpen == true { return "Canal aberto · todos os bots escutam" }
        return info?.topic.isEmpty == false ? info!.topic : "Canal"
    }

    var body: some View {
        HStack(spacing: 6) {
            IconButton(systemName: "sidebar.left", help: showSidebar ? "Esconder barra lateral" : "Mostrar barra lateral") {
                showSidebar.toggle()
            }
            HStack(spacing: 10) {
                if let bot = dmBot {
                    Avatar(name: bot.displayName, key: bot.name, size: 26)
                } else {
                    Image(systemName: info?.isOpen == true ? "megaphone.fill" : "number")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.accent.opacity(0.16)))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .themeCard(Theme.card, radius: 22)

            Spacer()

            PurgeMenu(channel: channel, compact: true)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(Theme.secondaryText)
                .frame(width: 30, height: 30)
            if model.botsPaused {
                IconButton(systemName: "play.circle.fill", tint: Theme.warning,
                           help: "Os bots estão parados. Clique para voltar a acordá-los quando forem mencionados (ou digite /retomar).") {
                    model.setBotsPaused(false)
                }
            } else {
                IconButton(systemName: "stop.circle",
                           help: "Para a conversa entre os bots: ninguém é acordado e quem está respondendo é interrompido (ou digite /parar).") {
                    model.setBotsPaused(true)
                }
            }
            IconButton(systemName: "point.3.connected.trianglepath.dotted", help: "Como conectar os bots do Kiro Crew a este chat") {
                model.showSetup = true
            }
        }
        // Sem a barra lateral, os botões da janela ficam sobre o cabeçalho.
        .padding(.leading, showSidebar ? 6 : 70)
        .padding(.trailing, 6)
        .frame(height: 48)
    }
}

struct MessageList: View {
    @EnvironmentObject var model: ChatViewModel
    /// Largura máxima da coluna de conversa, para as linhas não ficarem longas demais.
    static let maxWidth: CGFloat = 860

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.messages.isEmpty {
                        Text("Nenhuma mensagem ainda. Os bots vão aparecer aqui quando escreverem.")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { idx, m in
                        let prev = idx > 0 ? model.messages[idx - 1] : nil
                        MessageRow(message: m, grouped: isGrouped(m, after: prev))
                            .id(m.id)
                    }
                    // Fim da conversa, já com o respiro abaixo da última mensagem. Rolar até aqui
                    // (e não até a última mensagem) deixa o espaço antes da caixa de texto visível.
                    Color.clear
                        .frame(height: 18)
                        .id(Self.bottomID)
                }
                .frame(maxWidth: Self.maxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
            // Se o conteúdo cresce embaixo (status de quem está respondendo), a conversa continua no fim.
            .defaultScrollAnchor(.bottom)
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: model.messages.last?.id) { scrollToBottom(proxy, animated: true) }
            .onChange(of: model.messages.last.flatMap { model.listeners[$0.id] }) { scrollToBottom(proxy, animated: true) }
        }
    }

    private static let bottomID = "fim-da-conversa"

    private func isGrouped(_ m: ChatMessage, after prev: ChatMessage?) -> Bool {
        guard let prev, prev.sender == m.sender, prev.kind == .message, m.kind == .message else { return false }
        return m.createdAt.timeIntervalSince(prev.createdAt) < 120
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !model.messages.isEmpty else { return }
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        else { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}

struct MessageRow: View {
    @EnvironmentObject var model: ChatViewModel
    let message: ChatMessage
    let grouped: Bool

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var mentionsMe: Bool { message.mentions.contains(model.me) }
    private var isMine: Bool { message.sender == model.me }
    private var isHuman: Bool { model.bots.first { $0.name == message.sender }?.isHuman ?? false }
    private var isAlert: Bool { message.kind == .alert }

    /// "18:02 · #12 · ↩ #11", em fonte monoespaçada e discreta, abaixo da mensagem.
    private var meta: some View {
        var parts = [Self.timeFormat.string(from: message.createdAt), "#\(message.id)"]
        if let r = message.replyTo { parts.append("↩ #\(r)") }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.tertiaryText)
    }

    var body: some View {
        Group {
            if message.kind == .system {
                systemRow
            } else if isMine {
                mineRow
            } else {
                otherRow
            }
        }
        .contextMenu {
            if message.kind != .system {
                Button("Responder") { model.draft = "\(model.handle(for: message.sender)) " }
            }
            Button("Copiar texto") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
        }
    }

    private var systemRow: some View {
        Text(message.text)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .themeCard(Theme.panel, radius: 10)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// Minhas mensagens: balão roxo à direita.
    private var mineRow: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isAlert {
                Label("ALERTA", systemImage: "bell.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.warning)
            }
            MessageBody(text: message.text, me: model.me, handles: model.handles, onAccent: true)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isAlert ? Color.orange.gradient : Theme.accent.gradient))
            if !grouped { meta }
            ListenerStatus(messageId: message.id)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 90)
        .padding(.top, grouped ? 4 : 12)
    }

    /// Mensagens dos bots (e de outros humanos): cartão escuro à esquerda, com avatar e nome.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if grouped {
                Color.clear.frame(width: 30, height: 1)
            } else {
                Avatar(name: message.senderName, key: message.sender, isHuman: isHuman, size: 30)
            }
            VStack(alignment: .leading, spacing: 5) {
                if !grouped {
                    HStack(spacing: 6) {
                        Text(message.senderName).font(.system(size: 13, weight: .semibold))
                        if isAlert {
                            Label("ALERTA", systemImage: "bell.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                MessageBody(text: message.text, me: model.me, handles: model.handles)
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .themeCard(isAlert ? Theme.warning.opacity(0.08) : Theme.card, radius: 14,
                               stroke: isAlert ? Theme.warning.opacity(0.5)
                                   : mentionsMe ? Theme.accent.opacity(0.7) : Theme.stroke)
                meta
                ListenerStatus(messageId: message.id)
            }
            Spacer(minLength: 60)
        }
        .padding(.top, grouped ? 4 : 12)
    }
}

/// Quem escutou uma mensagem de canal aberto: respondendo, aguardando, ouviu sem responder, falhou.
struct ListenerStatus: View {
    @EnvironmentObject var model: ChatViewModel
    let messageId: Int64

    var body: some View {
        if let l = model.listeners[messageId], !l.isEmpty {
            HStack(spacing: 10) {
                if !l.awaitingApproval.isEmpty {
                    Label("Aprovar no Kiro Crew: " + l.awaitingApproval.joined(separator: ", "), systemImage: "checkmark.shield")
                        .foregroundStyle(Theme.warning)
                        .help("O Kiro Crew pediu aprovação para o Bot rodar: abra o painel do Kiro Crew → Approvals. Depois de aprovado, o Bot trabalha e responde aqui.")
                }
                if !l.executing.isEmpty {
                    Label("Executando no Kiro Crew: " + l.executing.joined(separator: ", "), systemImage: "hammer")
                        .help("O Bot pediu para executar uma ação e está rodando pelo Kiro Crew, com as ferramentas dele.")
                }
                if !l.answering.isEmpty {
                    Label("Respondendo: " + l.answering.joined(separator: ", "), systemImage: "ellipsis.bubble")
                }
                if !l.queued.isEmpty {
                    Label("Aguardando: " + l.queued.joined(separator: ", "), systemImage: "hourglass")
                        .help("Ainda não acordado: a espera do gatilho, o limite de chamadas por hora ou o bot ainda está respondendo outra mensagem.")
                }
                if !l.heard.isEmpty {
                    Label("Ouviram e não responderam: " + l.heard.joined(separator: ", "), systemImage: "ear")
                        .help("Acordados por esta mensagem, decidiram que não tinham nada a acrescentar.")
                }
                if !l.failed.isEmpty {
                    Label("Falhou: " + l.failed.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .help("O gatilho desse bot deu erro. Veja em Gatilho de chamada → Últimos disparos.")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
        }
    }
}

enum MessageText {
    /// Markdown inline + destaque das @menções, exibidas com o nome do bot ("@jon" → "@Jon").
    static func render(_ text: String, me: String, handles: [String: String] = [:], onAccent: Bool = false) -> AttributedString {
        var attr = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // `código` inline: fonte monoespaçada (já vem do Markdown) com um fundo leve.
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].backgroundColor = onAccent ? Color.black.opacity(0.22) : Color.white.opacity(0.09)
            if !onAccent { attr[run.range].foregroundColor = Color(red: 0.86, green: 0.78, blue: 1.0) }
        }
        let plain = String(attr.characters)
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.-])@[A-Za-z0-9_][A-Za-z0-9_.-]*"#) else { return attr }
        let ns = plain as NSString
        // De trás para frente: substituir o texto muda o tamanho e invalidaria os índices seguintes.
        for match in regex.matches(in: plain, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let r = Range(match.range, in: plain) else { continue }
            let start = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let len = plain.distance(from: r.lowerBound, to: r.upperBound)
            let a = attr.characters.index(attr.startIndex, offsetBy: start)
            let b = attr.characters.index(a, offsetBy: len)
            let name = ChatNames.normalize(String(plain[r]))
            let shown = ChatNames.broadcast.contains(name) ? "@" + name : handles[name] ?? "@" + ChatNames.display(forKey: name)
            var token = AttributedString(shown)
            token.foregroundColor = onAccent ? .white : name == me || ChatNames.broadcast.contains(name) ? .orange : Theme.accent
            token.font = .body.bold()
            attr.replaceSubrange(a..<b, with: token)
        }
        return attr
    }
}

struct Avatar: View {
    /// Nome exibido (iniciais).
    let name: String
    /// Chave estável para a cor (minúsculas).
    var key: String? = nil
    var isHuman = false
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if isHuman {
                Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(.white)
            } else {
                Text(String(name.prefix(2)).uppercased())
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var color: Color {
        let palette: [Color] = [Theme.accent, .blue, .pink, .teal, .indigo, .green, .orange, .mint, .cyan, .purple]
        var h: UInt32 = 5381
        for b in (key ?? ChatNames.normalize(name)).utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var model: ChatViewModel
    let channel: String
    @FocusState private var focused: Bool

    /// Altura de uma linha do campo; ícones e botão usam a mesma para ficarem centralizados.
    static let rowHeight: CGFloat = 32

    var body: some View {
        let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 4) {
            Menu {
                ForEach(model.bots.filter { $0.name != model.me }) { bot in
                    Button(bot.handle) { model.insertMention(bot.handle) }
                }
                Divider()
                Button("@todos") { model.insertMention("todos") }
            } label: {
                Image(systemName: "at")
                    .font(.system(size: 15, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: Self.rowHeight)
            .help("Mencionar um bot")

            Toggle(isOn: $model.sendAsAlert) {
                Image(systemName: model.sendAsAlert ? "bell.fill" : "bell")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(model.sendAsAlert ? Theme.warning : Theme.secondaryText)
            .help("Enviar como alerta (prioridade para os bots mencionados)")

            TextField(model.composerPlaceholder(for: channel),
                      text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .onKeyPress(.downArrow) { model.mentionSuggestions.isEmpty ? .ignored : { model.moveSuggestion(1); return .handled }() }
                .onKeyPress(.upArrow) { model.mentionSuggestions.isEmpty ? .ignored : { model.moveSuggestion(-1); return .handled }() }
                .onKeyPress(.tab) { model.acceptSuggestion() ? .handled : .ignored }
                // Enter: completa a menção ou envia. ⇧/⌥ + Enter quebra linha.
                // (Não usamos onSubmit: no macOS ele também dispara quando o campo perde o foco.)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        model.draft += "\n"
                        return .handled
                    }
                    if !model.acceptSuggestion() { model.send() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !model.mentionSuggestions.isEmpty else { return .ignored }
                    model.dismissSuggestions()
                    return .handled
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .frame(minHeight: Self.rowHeight)

            Button { model.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(empty ? Theme.tertiaryText : Color.white)
                    .frame(width: Self.rowHeight, height: Self.rowHeight)
                    .background(Circle().fill(empty ? Theme.cardHover : Theme.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(empty)
            .help("Enviar (↩ ou ⌘↩)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .themeCard(Theme.card, radius: 20,
                   stroke: focused ? Theme.accent.opacity(0.45) : Theme.stroke)
        // Menu de menções logo acima do campo.
        .overlay(alignment: .topLeading) {
            MentionSuggestionsView()
                .alignmentGuide(.top) { $0[.bottom] + 8 }
                .padding(.leading, 70)
        }
        .frame(maxWidth: MessageList.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onAppear { focused = true }
        .onChange(of: model.focusComposer) { focused = true }
    }
}

/// Menu que aparece ao digitar "@": bots online primeiro, filtrando pelo que foi digitado.
struct MentionSuggestionsView: View {
    @EnvironmentObject var model: ChatViewModel

    var body: some View {
        let list = model.mentionSuggestions
        if !list.isEmpty {
            let selected = min(model.suggestionIndex, list.count - 1)
            let online = list.filter { $0.online && !$0.isBroadcast }.count
            VStack(alignment: .leading, spacing: 2) {
                Text(online == 1 ? "1 bot online" : "\(online) bots online")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                            row(s, selected: i == selected)
                                .onTapGesture { model.completeMention(String(s.handle.dropFirst())) }
                                .onHover { if $0 { model.suggestionIndex = i } }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                Text("↑↓ navegar · ↩ ou Tab escolher · Esc fechar")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .padding(6)
            .frame(width: 320)
            .themeCard(Theme.panel, radius: 12)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
        }
    }

    private func row(_ s: ChatViewModel.MentionSuggestion, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if s.isBroadcast {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.orange.gradient))
            } else {
                Avatar(name: s.title, key: s.key, size: 24)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(s.online ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 1.5))
                    }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(s.handle).fontWeight(.semibold)
                if !s.subtitle.isEmpty {
                    Text(s.subtitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !s.isBroadcast && !s.online {
                Text("offline").font(.caption2).foregroundStyle(Theme.tertiaryText)
            }
        }
        .opacity(s.online ? 1 : 0.6)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selection : Color.clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Novo canal

struct NewChannelView: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Novo canal").font(.title2.bold())
            TextField("nome (ex: feature-login)", text: $name)
            TextField("assunto (opcional)", text: $topic)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Criar") {
                    model.createChannel(name, topic: topic)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ChatNames.normalize(name).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject var model: ChatViewModel
    @EnvironmentObject var updater: Updater
    @State private var nameDraft = ""
    @State private var nameError: String?

    private var nameChanged: Bool {
        !ChatNames.normalize(nameDraft).isEmpty && ChatNames.displayName(fromRaw: nameDraft) != model.humanName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Você") {
                SettingsRow("Seu nome no chat", detail: "Como os bots e as menções te veem (@\(model.humanName)).") {
                    HStack(spacing: 8) {
                        TextField("Nome", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onSubmit { if nameChanged { nameError = model.setHumanName(nameDraft) } }
                        Button("Salvar") { nameError = model.setHumanName(nameDraft) }
                            .disabled(!nameChanged)
                    }
                }
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.red)
                }
                SettingsDivider()
                SettingsRow("Notificações", detail: "Avisar quando eu for mencionado ou houver um alerta.") {
                    Toggle("", isOn: $model.notificationsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsSection("Bots") {
                SettingsRow("Disparar gatilhos com o app fechado",
                            detail: "Instala um serviço leve em segundo plano (LaunchAgent) que acorda os bots quando forem mencionados.") {
                    Toggle("", isOn: Binding(get: { model.backgroundDispatch }, set: { model.setBackgroundDispatch($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Trocas seguidas entre bots",
                            detail: "Depois disso, menções entre bots não acordam ninguém até um humano escrever. Evita conversas sem fim.") {
                    HStack(spacing: 6) {
                        Text("\(model.maxBotHops)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 22, alignment: .trailing)
                        Stepper("", value: Binding(get: { model.maxBotHops }, set: { model.setMaxBotHops($0) }), in: 1...50)
                            .labelsHidden()
                    }
                }
            }

            SettingsSection("Atualizações") {
                SettingsRow("Versão instalada", detail: updateStatus) {
                    Button("Verificar agora") { updater.check(userInitiated: true) }
                }
                SettingsDivider()
                SettingsRow("Procurar versões novas automaticamente", detail: "Ao abrir o app e a cada 6 horas.") {
                    Toggle("", isOn: $updater.autoCheck).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsSection("Dados") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Banco de dados").font(.system(size: 13, weight: .medium))
                    HStack(alignment: .top, spacing: 8) {
                        Text(model.databasePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)])
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .onAppear { nameDraft = model.humanName }
    }

    private var updateStatus: String {
        var parts = ["Kiro Chat \(updater.currentVersion)"]
        if let r = updater.available {
            parts.append("versão \(r.version) disponível")
        } else if let d = updater.lastChecked {
            parts.append("verificado \(d.formatted(.relative(presentation: .named).locale(Theme.locale)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Grupo de ajustes: título pequeno em cima e um cartão com as linhas.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themeCard(Theme.panel)
        }
    }
}

/// Uma linha de ajuste: título e explicação à esquerda, controle à direita.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize()
        }
    }
}

private struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.stroke).frame(height: 1) }
}
