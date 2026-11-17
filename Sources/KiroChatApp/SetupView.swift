import AppKit
import KiroChatCore
import SwiftUI

/// Gera a configuração MCP para conectar um bot do Kiro Crew ao chat.
struct SetupView: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    /// Vazio = configuração compartilhada (sem --bot): cada bot entra com o próprio nome via join_chat.
    @State private var botName = ""
    @State private var botDescription = ""
    @State private var format = Format.kiroMCP
    @State private var copied = false

    enum Format: String, CaseIterable, Identifiable {
        case kiroMCP = "mcp.json (Kiro)"
        case agent = "Agente customizado"
        case steering = "Steering do bot"
        var id: String { rawValue }
    }

    /// Chave (arquivos) e nome de exibição (como o bot aparece no chat: "Planner").
    private var name: String { ChatNames.normalize(botName).isEmpty ? "meu-bot" : ChatNames.normalize(botName) }
    private var display: String {
        let d = ChatNames.displayName(fromRaw: botName).replacingOccurrences(of: "\"", with: "")
        return ChatNames.normalize(d).isEmpty ? "Meu-bot" : d
    }

    private var fixedName: Bool { !ChatNames.normalize(botName).isEmpty }

    private static let autoApprove = ["join_chat", "read_messages", "send_message", "notify_bot",
                                      "check_mentions", "wait_for_mentions", "list_bots", "list_channels",
                                      "create_channel"]

    private var serverJSON: String {
        let desc = botDescription.replacingOccurrences(of: "\"", with: "\\\"")
        let approve = Self.autoApprove.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            "kiro-chat": {
              "command": "\(model.mcpBinaryPath)",
              "args": [\(fixedName ? "\"--bot\", \"\(display)\", \"--description\", \"\(desc)\"" : "")],
              "env": {},
              "disabled": false,
              "autoApprove": [\(approve)]
            }
        """
    }

    private var snippet: String {
        switch format {
        case .kiroMCP:
            return """
            {
              "mcpServers": {
            \(serverJSON)
              }
            }
            """
        case .agent:
            return """
            {
              "name": "\(name)",
              "description": "\(botDescription.replacingOccurrences(of: "\"", with: "\\\""))",
              "mcpServers": {
            \(serverJSON)
              },
              "tools": ["*"],
              "allowedTools": ["@kiro-chat"]
            }
            """
        case .steering:
            return """
            ---
            inclusion: always
            ---
            # Chat entre bots (Kiro Chat)

            \(fixedName ? "Você é o bot **@\(display)**: \(botDescription)" : "No chat, use o seu primeiro nome do Kiro Crew (ex: \"Jon - Chief\" → Jon).")
            Existe um chat aberto compartilhado com os outros bots do Kiro Crew, acessível pelas ferramentas do MCP `kiro-chat`.

            - No início de cada tarefa, chame `read_messages` para ver o que os outros bots disseram.
            - Quando precisar de algo de outro bot, use `send_message` mencionando `@nome` (veja quem existe com `list_bots`).
            - Para avisos urgentes ou para acionar um bot, use `notify_bot`.
            - Se uma resposta de ferramenta mostrar "🔔 menção(ões) não lida(s)", chame `check_mentions` e responda quem te chamou, com `reply_to`.
            - Ao terminar uma tarefa que alguém pediu, avise no chat mencionando quem pediu.
            - Se foi acordado por um gatilho do Kiro Chat, siga o prompt (se a resposta for publicada automaticamente, escreva só o texto dela) e termine.
            - Não crie cron nem script de "escuta" do chat: o Kiro Chat te acorda quando alguém te chama.
            - Só mencione outro bot se precisar que ele faça algo agora (mencionar acorda o bot). Ao terminar a tarefa, inclua [FIM] na mensagem: ela não acorda ninguém.
            """
        }
    }

    private var destination: String {
        switch format {
        case .kiroMCP: return "Cole em .kiro/settings/mcp.json do workspace do bot (ou ~/.kiro/settings/mcp.json). Se já houver um \"mcpServers\", adicione só a entrada \"kiro-chat\"."
        case .agent: return "Para bots definidos como agentes customizados (ex: ~/.kiro/agents/\(name).json ou .kiro/agents/\(name).json). Mescle com a configuração existente do agente."
        case .steering: return "Salve como .kiro/steering/kiro-chat.md no workspace do bot, para ele saber como e quando usar o chat."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Conectar um bot do Kiro Crew").font(.title2.bold())
                Spacer()
            }
            Text("Para os Bots do Kiro Crew, deixe o nome vazio: todos usam a mesma configuração e cada um entra no chat com o próprio nome. Para só colocar um Bot no chat e acordá-lo quando for chamado, use **Adicionar bots** (não precisa disto).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Nome do bot")
                    TextField("vazio = cada bot usa o próprio nome (recomendado)", text: $botName).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("O que ele faz")
                    TextField("descrição", text: $botDescription).textFieldStyle(.roundedBorder).disabled(!fixedName)
                }
            }

            Picker("", selection: $format) {
                ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(destination).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(snippet)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

            Text("Só preencha o nome para uma configuração usada por um único bot. Com --bot, todo bot que usar esse mcp.json entra no chat com esse nome.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Mostrar binário no Finder") {
                    NSWorkspace.shared.selectFile(model.mcpBinaryPath, inFileViewerRootedAtPath: "")
                }
                Spacer()
                Button(copied ? "Copiado ✓" : "Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}
