import Foundation
import KiroChatCore

// Uso:
//   kiro-chat-mcp [--bot NOME] [--description "o que faz"] [--db caminho]   → servidor MCP (stdio)
//   kiro-chat-mcp send  --bot NOME [--channel geral] "texto com @outro"     → envia mensagem
//   kiro-chat-mcp notify --bot NOME --to ALVO "texto"                       → envia alerta
//   kiro-chat-mcp read  [--channel geral] [--limit 30]                      → mostra histórico
//   kiro-chat-mcp mentions --bot NOME                                       → menções não lidas
//   kiro-chat-mcp bots                                                      → lista bots
// Variáveis de ambiente: KIRO_CHAT_BOT, KIRO_CHAT_BOT_DESCRIPTION, KIRO_CHAT_DB.

let env = ProcessInfo.processInfo.environment
var rawArgs = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var positional: [String] = []
var i = 0
while i < rawArgs.count {
    let a = rawArgs[i]
    if a.hasPrefix("--") {
        let key = String(a.dropFirst(2))
        if let eq = key.firstIndex(of: "=") {
            options[String(key[..<eq])] = String(key[key.index(after: eq)...])
        } else if i + 1 < rawArgs.count, !rawArgs[i + 1].hasPrefix("--") {
            options[key] = rawArgs[i + 1]; i += 1
        } else {
            options[key] = "true"
        }
    } else {
        positional.append(a)
    }
    i += 1
}

if options["help"] != nil || positional.first == "help" {
    print("""
    kiro-chat-mcp — chat aberto entre os bots do Kiro Crew

    Servidor MCP (configure no Kiro):
      kiro-chat-mcp [--bot Jon --description "o que faz"]   (sem --bot: o bot entra com join_chat)

    CLI (útil em hooks e scripts):
      kiro-chat-mcp send --bot jon [--channel geral] "texto com @catelyn"
      kiro-chat-mcp notify --bot bran --to jon "build quebrou"
      kiro-chat-mcp read [--channel geral] [--limit 30]
      kiro-chat-mcp mentions --bot coder
      kiro-chat-mcp bots

    Gatilhos (acordar um bot quando ele for mencionado, sem gastar tokens esperando):
      kiro-chat-mcp trigger --bot jon --command 'kiro-cli chat --no-interactive --agent jon "$KIRO_CHAT_PROMPT"'
      kiro-chat-mcp trigger --bot jon --url https://exemplo/webhook [--delay 3] [--max-per-hour 30]
      kiro-chat-mcp trigger --bot jon --kirocrew [CHAVE]   → acorda o Bot do Kiro Crew e publica a resposta
          [--mode hybrid|spawn|chat]                        hybrid (padrão): rápido, e pelo Kiro Crew quando precisa agir
      kiro-chat-mcp trigger --bot jon --test | --off | --on | --remove | --post-reply on|off
      kiro-chat-mcp kirocrew-bots                 → Bots do Kiro Crew e a chave de cada um
      kiro-chat-mcp triggers                      → lista gatilhos e últimos disparos
      kiro-chat-mcp dispatch                      → escuta o chat e dispara os gatilhos (deixe rodando)

    Controle da conversa entre bots:
      kiro-chat-mcp stop [--bot raffael]          → para os bots: ninguém é acordado e quem está rodando é interrompido
      kiro-chat-mcp resume [--bot raffael]        → retoma os bots
      kiro-chat-mcp max-hops [N]                  → mostra/define o limite de trocas seguidas entre bots (padrão 6)
      kiro-chat-mcp open geral | close geral      → canal aberto: mensagens de humanos sem @ são ouvidas por todos os bots

    Variáveis que o comando recebe: KIRO_CHAT_PROMPT, KIRO_CHAT_BOT, KIRO_CHAT_FROM,
      KIRO_CHAT_CHANNEL, KIRO_CHAT_TEXT, KIRO_CHAT_MESSAGE_ID(S), KIRO_CHAT_COUNT, KIRO_CHAT_DB

    Ambiente: KIRO_CHAT_BOT, KIRO_CHAT_BOT_DESCRIPTION, KIRO_CHAT_DB
    Banco padrão: \(ChatPaths.defaultDatabaseURL.path)
    """)
    exit(0)
}

let dbURL = options["db"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? ChatPaths.defaultDatabaseURL
let botName = options["bot"] ?? env["KIRO_CHAT_BOT"]
let botDescription = options["description"] ?? env["KIRO_CHAT_BOT_DESCRIPTION"]

let store: ChatStore
do {
    store = try ChatStore(url: dbURL)
} catch {
    FileHandle.standardError.write("Não foi possível abrir o banco em \(dbURL.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func requireBot() -> String {
    guard let botName, !ChatNames.normalize(botName).isEmpty else { fail("Informe --bot NOME (ou KIRO_CHAT_BOT).") }
    do { return try store.registerBot(botName, description: botDescription).name } catch { fail("\(error)") }
}

let channel = options["channel"] ?? ChatNames.defaultChannel

do {
    switch positional.first {
    case nil, "serve", "mcp":
        log("servidor MCP iniciado (bot: \(botName ?? "não definido"), db: \(dbURL.path))")
        MCPServer(tools: ChatTools(store: store, botName: botName, description: botDescription)).run()

    case "send":
        let bot = requireBot()
        let text = positional.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { fail("Informe o texto da mensagem.") }
        let m = try store.post(channel: channel, sender: bot, text: text)
        print(ChatFormat.line(m))

    case "notify":
        let bot = requireBot()
        guard let to = options["to"] else { fail("Informe --to ALVO.") }
        let text = positional.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { fail("Informe o texto do alerta.") }
        let target = ChatNames.normalize(to)
        let body = ChatNames.extractMentions(from: text).contains(target) ? text : "\(store.handle(for: target)) \(text)"
        let m = try store.post(channel: channel, sender: bot, text: body, kind: .alert, extraMentions: [target])
        print(ChatFormat.line(m))

    case "read":
        let limit = Int(options["limit"] ?? "") ?? 30
        print(ChatFormat.lines(try store.messages(channel: channel, limit: limit)))

    case "mentions":
        let bot = requireBot()
        let ms = try store.unreadMentions(for: bot)
        if options["keep"] == nil { try store.markMentionsRead(for: bot, messageIds: ms.map(\.id)) }
        print(ChatFormat.lines(ms, empty: "Nenhuma menção não lida."))

    case "bots":
        print(ChatFormat.bots(try store.listBots()))

    case "stop", "resume":
        let paused = positional.first == "stop"
        let human = try store.listBots().first(where: \.isHuman)?.name ?? "humano"
        let who = botName.flatMap { ChatNames.normalize($0).isEmpty ? nil : $0 } ?? human
        try store.setWakePaused(paused, by: who)
        print(paused ? "Bots parados. Ninguém será acordado até `kiro-chat-mcp resume`."
                     : "Bots retomados.")

    case "open", "close":
        guard let ch = positional.dropFirst().first else { fail("Informe o canal, ex: kiro-chat-mcp open geral") }
        let human = try store.listBots().first(where: \.isHuman)?.name ?? "humano"
        try store.setChannelOpen(ch, positional.first == "open", by: botName ?? human)
        print(positional.first == "open"
              ? "#\(ChatNames.normalize(ch)) aberto: todos os bots escutam as mensagens dos humanos."
              : "#\(ChatNames.normalize(ch)) fechado: só quem for mencionado é acordado.")

    case "max-hops":
        if let raw = positional.dropFirst().first {
            guard let n = Int(raw), n >= 1 else { fail("Informe um número maior que zero.") }
            try store.setMaxBotHops(n)
        }
        print("Limite de trocas seguidas entre bots: \(store.maxBotHops)")

    case "dispatch":
        let dispatcher = WakeDispatcher(store: store) { msg in
            let line = "[\(ChatFormat.time(Date()))] \(msg)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        dispatcher.start()
        log("despachante de gatilhos rodando (db: \(dbURL.path)). Ctrl+C para parar.")
        withExtendedLifetime(dispatcher) { dispatchMain() }

    case "kirocrew-bots":
        guard KiroCrew.isInstalled else { fail("Kiro Crew não encontrado nesta máquina.") }
        let bots = KiroCrew.bots()
        if bots.isEmpty { print("Nenhum Bot no Kiro Crew.") }
        for b in bots { print("\(b.key)\t\(b.label)\(b.description.isEmpty ? "" : " — " + b.description)") }

    case "triggers":
        let triggers = try store.listTriggers()
        if triggers.isEmpty { print("Nenhum gatilho configurado.") }
        for t in triggers {
            let target = t.kind == .command ? t.command : t.url
            print("\(store.handle(for: t.bot)) [\(t.enabled ? "ativo" : "desligado")] \(t.kind.rawValue): \(target)")
            print("    espera \(Int(t.delaySeconds))s · máx \(t.maxPerHour)/h\(t.postReply ? " · publica a resposta no chat" : "")")
            for l in try store.wakeLogs(bot: t.bot, limit: 3) {
                print("    \(ChatFormat.time(l.startedAt)) \(l.isTest ? "(teste) " : "")\(l.status.isEmpty ? "rodando…" : l.status)")
            }
        }

    case "trigger":
        guard let raw = options["bot"] ?? botName, !ChatNames.normalize(raw).isEmpty else { fail("Informe --bot NOME.") }
        let key = ChatNames.normalize(raw)
        if options["remove"] != nil {
            try store.deleteTrigger(bot: key)
            print("Gatilho de \(store.handle(for: key)) removido.")
            break
        }
        if options["test"] != nil {
            guard try store.trigger(for: key)?.isConfigured == true else { fail("\(store.handle(for: key)) não tem gatilho.") }
            let before = try store.wakeLogs(bot: key, limit: 1).first?.id ?? 0
            WakeDispatcher(store: store).test(bot: key, from: "teste")
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if let l = try store.wakeLogs(bot: key, limit: 1).first, l.id > before, l.finishedAt != nil {
                    print("Teste: \(l.status)")
                    if !l.output.isEmpty { print(l.output) }
                    exit(l.succeeded ? 0 : 1)
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            fail("Teste ainda rodando depois de 120s.")
        }
        var t = try store.trigger(for: key) ?? WakeTrigger(bot: key)
        if let c = options["command"] { t.kind = .command; t.command = c; t.escalate = false }
        if let k = options["kirocrew"] {
            guard KiroCrew.isInstalled else { fail("Kiro Crew não encontrado nesta máquina.") }
            let bots = KiroCrew.bots()
            guard let crewBot = k == "true" ? KiroCrew.match(for: key, in: bots) : bots.first(where: { $0.key == k }) else {
                fail("Não achei o Bot do Kiro Crew. Veja as chaves com `kiro-chat-mcp kirocrew-bots` e use --kirocrew CHAVE.")
            }
            let mode: KiroCrew.Mode
            switch options["mode"]?.lowercased() {
            case nil, "hybrid", "hibrido", "híbrido": mode = .hybrid
            case "spawn": mode = .spawn
            case "chat": mode = .chat
            default: fail("--mode deve ser hybrid, spawn ou chat.")
            }
            KiroCrew.configure(&t, bot: crewBot, mode: mode)
            print("Bot do Kiro Crew: \(crewBot.label) (chave \(crewBot.key), modo \(mode.rawValue))")
        }
        if let pr = options["post-reply"] { t.postReply = !["off", "false", "0", "nao", "não"].contains(pr.lowercased()) }
        if let u = options["url"] { t.kind = .webhook; t.url = u }
        if let d = options["delay"].flatMap(Double.init) { t.delaySeconds = d }
        if let m = options["max-per-hour"].flatMap(Int.init) { t.maxPerHour = m }
        if options["off"] != nil { t.enabled = false }
        if options["on"] != nil { t.enabled = true }
        guard t.isConfigured else { fail("Informe --command ou --url.") }
        try store.saveTrigger(t)
        print("Gatilho de \(store.handle(for: key)) salvo (\(t.enabled ? "ativo" : "desligado")).")
        print("Ele dispara enquanto o app Kiro Chat estiver aberto ou com `kiro-chat-mcp dispatch` rodando.")

    default:
        fail("Comando desconhecido: \(positional[0]). Use --help.")
    }
} catch {
    fail("Erro: \(error)")
}
