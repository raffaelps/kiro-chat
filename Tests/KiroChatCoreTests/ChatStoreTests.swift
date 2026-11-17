import XCTest
@testable import KiroChatCore

final class ChatStoreTests: XCTestCase {
    var url: URL!
    var store: ChatStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("kirochat-\(UUID().uuidString).sqlite")
        store = try ChatStore(url: url)
    }

    override func tearDown() {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    func testNormalizeAndExtractMentions() {
        XCTAssertEqual(ChatNames.normalize("@Code Reviewer"), "code-reviewer")
        XCTAssertEqual(ChatNames.normalize("#Geral"), "geral")
        XCTAssertEqual(ChatNames.extractMentions(from: "oi @Coder e @reviewer, email a@b.com, @coder de novo"),
                       ["coder", "reviewer"])
    }

    func testMentionsAndBroadcast() throws {
        try store.registerBot("planner")
        try store.registerBot("coder")
        try store.registerBot("reviewer")

        let m = try store.post(sender: "planner", text: "@coder implementa o login")
        XCTAssertEqual(m.mentions, ["coder"])
        XCTAssertEqual(try store.unreadMentionCount(for: "coder"), 1)
        XCTAssertEqual(try store.unreadMentionCount(for: "reviewer"), 0)

        let all = try store.post(sender: "planner", text: "@todos reunião", kind: .alert)
        XCTAssertEqual(Set(all.mentions), ["coder", "reviewer"])
        XCTAssertEqual(try store.unreadMentionCount(for: "planner"), 0, "quem envia não é notificado")

        try store.markMentionsRead(for: "coder")
        XCTAssertEqual(try store.unreadMentionCount(for: "coder"), 0)
        XCTAssertEqual(try store.unreadMentions(for: "reviewer").map(\.id), [all.id])
    }

    func testReadCursorsAndUnreadCounts() throws {
        try store.registerBot("a")
        try store.registerBot("b")
        let m1 = try store.post(sender: "a", text: "um")
        try store.post(channel: "dev", sender: "a", text: "dois")
        XCTAssertEqual(try store.unreadCounts(for: "b"), ["geral": 1, "dev": 1])
        XCTAssertEqual(try store.unreadCounts(for: "a"), [:], "próprias mensagens não contam")

        try store.setReadCursor(bot: "b", channel: "geral", lastId: m1.id)
        XCTAssertEqual(try store.unreadCounts(for: "b"), ["dev": 1])
        XCTAssertEqual(try store.listChannels().map(\.name), ["geral", "dev"])
    }

    func testTwoConnectionsShareTheSameChat() throws {
        let other = try ChatStore(url: url)
        try store.registerBot("planner")
        try other.registerBot("coder")
        try other.post(sender: "coder", text: "@planner feito")
        XCTAssertEqual(try store.unreadMentions(for: "planner").first?.text, "@planner feito")
        XCTAssertEqual(try store.listBots().map(\.name), ["coder", "planner"])
    }

    func testSystemMessagesDoNotNotify() throws {
        try store.registerBot("coder")
        let m = try store.post(sender: "sistema", text: "📢 @coder criou o canal #x.", kind: .system)
        XCTAssertEqual(m.mentions, [])
        XCTAssertEqual(try store.unreadMentionCount(for: "coder"), 0)
    }

    func testDisplayNamesKeepCapitalization() throws {
        XCTAssertEqual(ChatNames.displayName(fromRaw: "jon"), "Jon")
        XCTAssertEqual(ChatNames.displayName(fromRaw: "@JonSnow"), "JonSnow")
        XCTAssertEqual(ChatNames.displayName(fromRaw: "  code reviewer "), "Code reviewer")

        let jon = try store.registerBot("jon")
        XCTAssertEqual(jon.name, "jon")
        XCTAssertEqual(jon.displayName, "Jon")
        XCTAssertEqual(jon.handle, "@Jon")
        let cr = try store.registerBot("Code Reviewer")
        XCTAssertEqual(cr.name, "code-reviewer")
        XCTAssertEqual(cr.handle, "@code-reviewer")

        // Menção é case-insensitive e a mensagem traz os nomes de exibição.
        let m = try store.post(sender: "code-reviewer", text: "@JON e @jon olhem isso")
        XCTAssertEqual(m.mentions, ["jon"])
        XCTAssertEqual(m.mentionNames, ["Jon"])
        XCTAssertEqual(m.senderName, "Code Reviewer")
        XCTAssertEqual(try store.messages(limit: 1).first?.mentionNames, ["Jon"])
        XCTAssertTrue(ChatFormat.line(m).contains("@Code Reviewer → @Jon"))
    }

    func testMigratesOldBotsTable() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let old = try ChatStore(url: url)
        try old.exec("DROP TABLE bots; CREATE TABLE bots (name TEXT PRIMARY KEY, description TEXT NOT NULL DEFAULT '', is_human INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, last_seen REAL); INSERT INTO bots(name, created_at) VALUES ('jon', 0);")
        store = try ChatStore(url: url)
        XCTAssertEqual(try store.bot(named: "jon")?.displayName, "Jon")
    }

    func testRenameHumanMovesHistory() throws {
        try store.registerBot("humano", isHuman: true)
        try store.registerBot("jon")
        try store.post(sender: "humano", text: "oi @jon")
        try store.post(sender: "jon", text: "@humano oi!")
        let me = try store.renameBot(from: "humano", to: "raffael")
        XCTAssertEqual(me.displayName, "Raffael")
        XCTAssertNil(try store.bot(named: "humano"))
        XCTAssertEqual(try store.messages().filter { $0.sender == "raffael" }.count, 1)
        XCTAssertEqual(try store.unreadMentionCount(for: "raffael"), 1)
        XCTAssertEqual(try store.messages().first { $0.sender == "raffael" }?.senderName, "Raffael")
        XCTAssertThrowsError(try store.renameBot(from: "raffael", to: "Jon"), "não pode tomar o nome de um bot")
        XCTAssertThrowsError(try store.renameBot(from: "raffael", to: "todos"))
    }

    func testWakeClaimRespectsDelayReadAndRateLimit() throws {
        try store.registerBot("jon")
        try store.post(sender: "arya", text: "@jon antiga")          // antes do gatilho: não dispara
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "true", delaySeconds: 5, maxPerHour: 2))
        let m = try store.post(sender: "arya", text: "@jon nova")

        XCTAssertTrue(try store.claimPendingWakes().isEmpty, "ainda dentro do delay")
        let later = Date().addingTimeInterval(10)
        XCTAssertTrue(try store.claimPendingWakes(excluding: ["jon"], now: later).isEmpty, "bot ocupado")
        let claims = try store.claimPendingWakes(now: later)
        XCTAssertEqual(claims.first?.1.map(\.id), [m.id])
        XCTAssertTrue(try store.claimPendingWakes(now: later).isEmpty, "não dispara duas vezes")
        XCTAssertEqual(try store.unreadMentionCount(for: "jon"), 2, "despachar não marca como lida")

        // Menção lida antes do delay (bot em wait_for_mentions) não acorda ninguém.
        let r = try store.post(sender: "arya", text: "@jon lida")
        try store.markMentionsRead(for: "jon", messageIds: [r.id])
        XCTAssertTrue(try store.claimPendingWakes(now: later.addingTimeInterval(10)).isEmpty)

        // Limite por hora.
        _ = try store.startWakeLog(bot: "jon", messageIds: [], isTest: false)
        _ = try store.startWakeLog(bot: "jon", messageIds: [], isTest: false)
        try store.post(sender: "arya", text: "@jon mais uma")
        XCTAssertTrue(try store.claimPendingWakes(now: Date().addingTimeInterval(10)).isEmpty, "limite atingido")
    }

    func testKiroCrewMatchAndCommand() {
        let bots = [KiroCrew.Bot(key: "jon-chief", displayName: "Jon - Chief", description: ""),
                    KiroCrew.Bot(key: "catelyn", displayName: "Catelyn - App Quality", description: ""),
                    KiroCrew.Bot(key: "bran", displayName: "", description: "")]
        XCTAssertEqual(KiroCrew.match(for: "jon", in: bots)?.key, "jon-chief")
        XCTAssertEqual(KiroCrew.match(for: "Catelyn", in: bots)?.key, "catelyn")
        XCTAssertEqual(KiroCrew.match(for: "bran", in: bots)?.key, "bran")
        XCTAssertNil(KiroCrew.match(for: "robb", in: bots))
        XCTAssertEqual(bots.map(KiroCrew.chatName(for:)), ["Jon", "Catelyn", "Bran"])

        XCTAssertEqual(KiroCrew.command(for: bots[0], binary: "/x/kirocrew"),
                       "/x/kirocrew chat --agent jon-chief -m \"$KIRO_CHAT_PROMPT\"")
        XCTAssertEqual(KiroCrew.shellQuote("Jon - Chief"), "'Jon - Chief'")
        XCTAssertEqual(KiroCrew.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(KiroCrew.shellQuote("~/x"), "'~/x'")
    }

    func testCleanReplyAndPostReplyPrompt() throws {
        XCTAssertEqual(WakeDispatcher.cleanReply("\u{1B}[32m  oi  \u{1B}[0m\n"), "oi")
        let crewOut = """
        16:46:13 WARNING kiro_crew.config.loader: 12 stored config value(s) still hold a superseded default: stt.streaming.
        Oi! Aqui é o Jon.
        Às 16:46:13 tudo certo.
        """
        XCTAssertEqual(WakeDispatcher.cleanReply(crewOut), "Oi! Aqui é o Jon.\nÀs 16:46:13 tudo certo.")
        XCTAssertTrue(KiroCrew.isInternal("kirocrew-heartbeat"))
        XCTAssertTrue(KiroCrew.isInternal("default"))
        XCTAssertFalse(KiroCrew.isInternal("mate"))
        try store.registerBot("jon")
        let m = try store.post(channel: "geral", sender: "arya", text: "@jon tudo bem?")
        let p = WakeContext.prompt(botName: "Jon", messages: [m], postReply: true)
        XCTAssertTrue(p.contains("publicada automaticamente em #geral"))
        XCTAssertFalse(p.contains("send_message"))

        try store.saveTrigger(WakeTrigger(bot: "jon", command: "true", postReply: true))
        XCTAssertEqual(try store.trigger(for: "jon")?.postReply, true)
    }

    func testDispatcherPublishesCommandReply() throws {
        try store.registerBot("jon")
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "echo \"Oi, $KIRO_CHAT_FROM! Aqui é o Jon.\"",
                                          delaySeconds: 0, postReply: true))
        try store.createChannel("ops")
        let ask = try store.post(channel: "ops", sender: "arya", text: "@jon está aí?")

        let dispatcher = WakeDispatcher(store: store)
        dispatcher.start(interval: 0.2)
        defer { dispatcher.stop() }

        var reply: ChatMessage?
        let deadline = Date().addingTimeInterval(15)
        while reply == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            reply = try store.messages(channel: "ops").first { $0.sender == "jon" }
        }
        XCTAssertEqual(reply?.text, "Oi, Arya! Aqui é o Jon.")
        XCTAssertEqual(reply?.replyTo, ask.id)
        XCTAssertEqual(try store.unreadMentionCount(for: "jon"), 0, "menção respondida fica lida")
    }

    func testHopsCountBotExchangesAndHumanResets() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("jon"); try store.registerBot("catelyn")
        let h = try store.post(sender: "raffael", text: "@jon revisa o PR?")
        XCTAssertEqual(h.hop, 0)
        let j = try store.post(sender: "jon", text: "@catelyn olha os testes", replyTo: h.id)
        XCTAssertEqual(j.hop, 1)
        let c = try store.post(sender: "catelyn", text: "@jon feito")  // sem reply_to: usa a menção mais recente
        XCTAssertEqual(c.hop, 2)
        let h2 = try store.post(sender: "raffael", text: "@jon valeu")
        XCTAssertEqual(h2.hop, 0)
        XCTAssertEqual(try store.post(sender: "jon", text: "de nada", replyTo: h2.id).hop, 1)
    }

    func testEndMarkerPublishesWithoutWaking() throws {
        try store.registerBot("jon"); try store.registerBot("catelyn")
        try store.saveTrigger(WakeTrigger(bot: "catelyn", command: "true", delaySeconds: 0))
        let m = try store.post(sender: "jon", text: "@catelyn pronto, deploy feito [FIM]")
        XCTAssertEqual(m.text, "✅ @catelyn pronto, deploy feito")
        XCTAssertEqual(m.mentions, ["catelyn"], "continua mencionando")
        XCTAssertTrue(try store.claimPendingWakes(now: Date().addingTimeInterval(1)).isEmpty, "mas não acorda")
        XCTAssertTrue(FlowMarkers.isNoReply(" [SEM RESPOSTA]. "))
        XCTAssertTrue(FlowMarkers.isNoReply("sem resposta"))
        XCTAssertFalse(FlowMarkers.isNoReply("Sem resposta do servidor ainda, vou tentar de novo"))
    }

    func testPauseDiscardsPendingAndHopLimitBlocks() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("jon")
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "true", delaySeconds: 0))
        let later = { Date().addingTimeInterval(1) }

        try store.setWakePaused(true, by: "raffael")
        try store.post(sender: "raffael", text: "@jon oi")
        XCTAssertTrue(try store.claimPendingWakes(now: later()).isEmpty, "parado")
        try store.setWakePaused(false, by: "raffael")
        XCTAssertTrue(try store.claimPendingWakes(now: later()).isEmpty, "menção feita durante a pausa não dispara depois")
        try store.post(sender: "raffael", text: "@jon e agora?")
        XCTAssertEqual(try store.claimPendingWakes(now: later()).count, 1)

        try store.setMaxBotHops(2)
        try store.registerBot("catelyn")
        try store.post(sender: "catelyn", text: "@jon x", hop: 2)
        XCTAssertTrue(try store.claimPendingWakes(now: later()).isEmpty, "limite de trocas")
        let last = try store.messages(limit: 1).last
        XCTAssertEqual(last?.kind, .system)
        XCTAssertTrue(last?.text.contains("não foi acordado") ?? false)
    }

    func testPromptCarriesConversationContext() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("jon"); try store.registerBot("catelyn")
        try store.post(sender: "raffael", text: "Precisamos subir a versão 2.3 hoje")
        try store.post(sender: "jon", text: "Eu cuido do changelog")
        let m = try store.post(sender: "raffael", text: "@catelyn e as reviews da loja?")
        let ctx = try store.conversationContext(for: [m])
        XCTAssertEqual(ctx.count, 2 + 3, "2 avisos de entrada dos bots + 3 mensagens")
        let p = WakeContext.prompt(botName: "Catelyn", messages: [m], postReply: true, maxHops: 6, context: ctx)
        XCTAssertTrue(p.contains("versão 2.3"))
        XCTAssertTrue(p.contains("Eu cuido do changelog"))
        XCTAssertTrue(p.contains("◀ VOCÊ FOI CHAMADO AQUI"))
        XCTAssertTrue(p.contains("troca 1 de no máximo 6"))
    }

    func testTwoBotsPingPongStopsAtLimit() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("jon"); try store.registerBot("catelyn")
        // Cada um sempre responde chamando o outro: sem limite, conversariam para sempre.
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "echo '@catelyn e você, o que acha?'", delaySeconds: 0, postReply: true))
        try store.saveTrigger(WakeTrigger(bot: "catelyn", command: "echo '@jon acho ótimo, e você?'", delaySeconds: 0, postReply: true))
        try store.setMaxBotHops(3)
        try store.post(sender: "raffael", text: "@jon o que acha da ideia?")

        let dispatcher = WakeDispatcher(store: store)
        dispatcher.start(interval: 0.1)
        defer { dispatcher.stop() }
        let deadline = Date().addingTimeInterval(20)
        var stopped = false
        while !stopped, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            stopped = try store.messages(limit: 50).contains { $0.kind == .system && $0.text.contains("não foi acordado") }
        }
        XCTAssertTrue(stopped)
        Thread.sleep(forTimeInterval: 1)
        let botMessages = try store.messages(limit: 50).filter { ["jon", "catelyn"].contains($0.sender) }
        XCTAssertEqual(botMessages.map(\.hop), [1, 2, 3])
    }

    func testOpenChannelEveryoneListensToHumans() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("jon"); try store.registerBot("catelyn")
        XCTAssertTrue(try store.isChannelOpen("geral"), "#geral já nasce aberto")
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "true", delaySeconds: 0))
        try store.saveTrigger(WakeTrigger(bot: "catelyn", command: "true", delaySeconds: 0))
        let later = { Date().addingTimeInterval(1) }

        let h = try store.post(sender: "raffael", text: "bom dia, pessoal")
        XCTAssertEqual(h.mentions, [], "escutar não é ser mencionado")
        XCTAssertEqual(try store.unreadMentionCount(for: "jon"), 0)
        // Todos ao mesmo tempo.
        XCTAssertEqual(try store.claimPendingWakes(now: later()).map(\.0.bot).sorted(), ["catelyn", "jon"])

        // Mensagem de bot sem menção não acorda ninguém; humano mencionando só acorda o mencionado.
        try store.post(sender: "jon", text: "bom dia!")
        XCTAssertTrue(try store.claimPendingWakes(now: later()).isEmpty)
        try store.post(sender: "raffael", text: "@catelyn e as reviews?")
        XCTAssertEqual(try store.claimPendingWakes(now: later()).map(\.0.bot), ["catelyn"])

        // Canal fechado: sem menção, ninguém escuta.
        try store.setChannelOpen("geral", false, by: "raffael")
        try store.post(sender: "raffael", text: "alguém aí?")
        XCTAssertTrue(try store.claimPendingWakes(now: later()).isEmpty)
    }

    func testOpenChannelWakesEveryoneAtOnce() throws {
        let promptFile = FileManager.default.temporaryDirectory.appendingPathComponent("kirochat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: promptFile) }
        try store.registerBot("raffael", isHuman: true)
        for b in ["bran", "catelyn", "jon"] { try store.registerBot(b) }
        try store.saveTrigger(WakeTrigger(bot: "bran", command: "sleep 1; echo 'Bom dia! O CI está verde.'",
                                          delaySeconds: 0, postReply: true))
        try store.saveTrigger(WakeTrigger(bot: "catelyn", command: "echo \"$KIRO_CHAT_PROMPT\" > '\(promptFile.path)'; echo '[SEM RESPOSTA]'",
                                          delaySeconds: 0, postReply: true))
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "sleep 1; echo 'Bom dia, Raffael.'", delaySeconds: 0, postReply: true))
        let h = try store.post(sender: "raffael", text: "bom dia")

        let dispatcher = WakeDispatcher(store: store)
        dispatcher.start(interval: 0.1)
        defer { dispatcher.stop() }
        // Ninguém espera o outro: os três estão acordados ao mesmo tempo (Bran e Jon levam 1 s).
        var deadline = Date().addingTimeInterval(5)
        while try store.wakeLogs(limit: 10).count < 3, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(try store.wakeLogs(limit: 10).count, 3)
        XCTAssertGreaterThanOrEqual(try store.listeners(for: [h.id])[h.id]?.answering.count ?? 0, 2, "Bran e Jon respondendo juntos")
        deadline = Date().addingTimeInterval(20)
        while try store.wakeLogs(limit: 10).filter({ $0.finishedAt != nil }).count < 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let replies = try store.messages(limit: 50).filter { ["bran", "catelyn", "jon"].contains($0.sender) }
        XCTAssertEqual(replies.map(\.sender).sorted(), ["bran", "jon"], "Catelyn não tinha nada a acrescentar")
        XCTAssertTrue(replies.allSatisfy { $0.replyTo == h.id })
        let prompt = try String(contentsOf: promptFile, encoding: .utf8)
        XCTAssertTrue(prompt.contains("ao mesmo tempo"))
        XCTAssertTrue(prompt.contains("MENSAGEM PARA TODOS NO CANAL"))
        XCTAssertTrue(prompt.contains("responda você também"), "pergunta para todos: cada um responde")
        XCTAssertEqual(try store.wakeLogs(limit: 10).count, 3, "respostas dos bots não acordaram ninguém")
        let l = try store.listeners(for: [h.id])[h.id]
        XCTAssertEqual(l?.heard, ["Catelyn"], "quem ouviu e não respondeu aparece; quem respondeu, não")
        XCTAssertEqual(l?.queued, [])
        XCTAssertEqual(l?.answering, [])
    }

    func testDirectChannelOnlyReachesItsBot() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("jon"); try store.registerBot("catelyn")
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "echo 'Oi! Só eu aqui.'", delaySeconds: 0, postReply: true))
        try store.saveTrigger(WakeTrigger(bot: "catelyn", command: "echo 'não devia'", delaySeconds: 0, postReply: true))

        let ch = try store.openDirectChannel(with: "jon", by: "raffael")
        XCTAssertEqual(ch, "dm-jon")
        let info = try store.listChannels().first { $0.name == ch }
        XCTAssertEqual(info?.dmWith, "jon")
        XCTAssertEqual(info?.isOpen, false)
        XCTAssertEqual(try store.openDirectChannel(with: "Jon", by: "raffael"), ch, "reabrir não duplica")

        XCTAssertEqual(try store.post(channel: ch, sender: "raffael", text: "tudo certo?").mentions, ["jon"], "sem @")
        XCTAssertEqual(try store.post(channel: ch, sender: "raffael", text: "@catelyn viu isso?").mentions, ["jon"],
                       "outro bot não é acordado na conversa direta")
        XCTAssertEqual(try store.post(channel: ch, sender: "jon", text: "@catelyn @todos olhem").mentions, [])
        XCTAssertTrue(try store.canSee(channel: ch, bot: "jon"))
        XCTAssertTrue(try store.canSee(channel: ch, bot: "raffael"))
        XCTAssertFalse(try store.canSee(channel: ch, bot: "catelyn"))
        XCTAssertTrue(try store.canSee(channel: "geral", bot: "catelyn"))
        XCTAssertThrowsError(try store.setChannelOpen(ch, true, by: "raffael"))

        // De ponta a ponta: só o Jon responde, na conversa direta.
        try store.markMentionsRead(for: "jon")
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "echo 'Oi! Só eu aqui.'", delaySeconds: 0, postReply: true))
        let ask = try store.post(channel: ch, sender: "raffael", text: "oi")
        let dispatcher = WakeDispatcher(store: store)
        dispatcher.start(interval: 0.1)
        defer { dispatcher.stop() }
        var reply: ChatMessage?
        let deadline = Date().addingTimeInterval(15)
        while reply == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            reply = try store.messages(channel: ch).first { $0.sender == "jon" && $0.replyTo == ask.id }
        }
        XCTAssertEqual(reply?.text, "Oi! Só eu aqui.")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(try store.messages(limit: 100).contains { $0.sender == "catelyn" })
    }

    func testWritingToMissingDirectChannelCreatesTheDM() throws {
        try store.registerBot("raffael", isHuman: true)
        try store.registerBot("robb"); try store.registerBot("jon")
        XCTAssertThrowsError(try store.post(channel: "dm-robb", sender: "jon", text: "oi"), "Jon não abre a conversa do Robb")
        XCTAssertThrowsError(try store.post(channel: "dm-ninguem", sender: "raffael", text: "oi"))
        try store.post(channel: "dm-robb", sender: "robb", text: "msg direta")
        XCTAssertEqual(try store.dmBot(of: "dm-robb"), "robb", "nasce como conversa direta, não canal comum")
        XCTAssertFalse(try store.canSee(channel: "dm-robb", bot: "jon"))
        XCTAssertEqual(try store.listChannels().first { $0.name == "dm-robb" }?.isDirect, true)
    }

    func testDeleteOldOrAllMessages() throws {
        try store.registerBot("jon"); try store.registerBot("catelyn")
        let old = try store.post(channel: "release", sender: "catelyn", text: "@jon antiga")
        let recent = try store.post(channel: "release", sender: "catelyn", text: "@jon recente")
        try store.post(channel: "geral", sender: "catelyn", text: "@jon em outro canal")
        _ = try store.run("UPDATE messages SET created_at = ? WHERE id = ?",
                          [.double(Date().addingTimeInterval(-10 * 86_400).timeIntervalSince1970), .int(old.id)])

        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(try store.countMessages(channel: "release", olderThan: weekAgo), 1)
        XCTAssertEqual(try store.deleteMessages(channel: "release", olderThan: weekAgo), 1)
        XCTAssertEqual(try store.messages(channel: "release").map(\.id), [recent.id])
        XCTAssertEqual(try store.unreadMentions(for: "jon").count, 2, "a menção da mensagem apagada foi junto")

        XCTAssertEqual(try store.deleteMessages(channel: "release"), 1)
        XCTAssertTrue(try store.messages(channel: "release").isEmpty)
        XCTAssertFalse(try store.messages(channel: "geral").isEmpty, "outros canais ficam")
    }

    func testDefaultDelayIsThreeSecondsAndOldDefaultMigrates() throws {
        XCTAssertEqual(WakeTrigger(bot: "jon").delaySeconds, 3)
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "true", delaySeconds: 5))     // padrão antigo
        try store.saveTrigger(WakeTrigger(bot: "bran", command: "true", delaySeconds: 10))   // escolhido pelo usuário
        _ = try store.run("DELETE FROM settings WHERE key = 'default_delay_v2'", [])
        store = try ChatStore(url: url)
        XCTAssertEqual(try store.trigger(for: "jon")?.delaySeconds, 3)
        XCTAssertEqual(try store.trigger(for: "bran")?.delaySeconds, 10)
        try store.saveTrigger(WakeTrigger(bot: "jon", command: "true", delaySeconds: 5))
        store = try ChatStore(url: url)
        XCTAssertEqual(try store.trigger(for: "jon")?.delaySeconds, 5, "a migração roda uma vez só")
    }

    func testUpdateVersionsReleaseParsingAndChecksum() throws {
        XCTAssertTrue(AppUpdate.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertTrue(AppUpdate.isNewer("0.10.0", than: "0.9.9"), "compara números, não texto")
        XCTAssertTrue(AppUpdate.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(AppUpdate.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppUpdate.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(AppUpdate.isNewer("nightly", than: "0.1.0"))
        XCTAssertFalse(AppUpdate.isNewer("1.0.0", than: "dev"), "build local sem versão não oferece atualização")

        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/raffaelps/kiro-chat/releases/tag/v0.2.0",
         "body":"- Novidade","published_at":"2026-11-17T21:00:00Z",
         "assets":[{"name":"KiroChat.zip","browser_download_url":"https://example.com/KiroChat.zip"},
                   {"name":"KiroChat.zip.sha256","browser_download_url":"https://example.com/KiroChat.zip.sha256"}]}
        """
        let r = try AppUpdate.parseRelease(Data(json.utf8))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.zipURL.absoluteString, "https://example.com/KiroChat.zip")
        XCTAssertNotNil(r.checksumURL)
        XCTAssertNotNil(r.publishedAt)
        XCTAssertThrowsError(try AppUpdate.parseRelease(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertThrowsError(try AppUpdate.parseRelease(Data(#"{"tag_name":"v0.3.0","assets":[]}"#.utf8)), "sem o zip")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kirochat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let hash = try AppUpdate.sha256(of: file)
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(AppUpdate.expectedChecksum(from: "\(hash.uppercased())  KiroChat.zip\n"), hash)
        XCTAssertNil(AppUpdate.expectedChecksum(from: "não é hash"))
    }

    func testReservedAndEmpty() {
        XCTAssertThrowsError(try store.registerBot("todos"))
        XCTAssertThrowsError(try store.post(sender: "x", text: "   "))
    }
}
