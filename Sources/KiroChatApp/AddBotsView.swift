import KiroChatCore
import SwiftUI

/// Coloca bots no chat: os Bots do Kiro Crew (com gatilho que os acorda) ou qualquer outro pelo nome.
struct AddBotsView: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var crewBots: [KiroCrew.Bot] = []
    @State private var selected = Set<String>()
    @State private var withTrigger = true
    @State private var otherName = ""
    @State private var otherDescription = ""
    @State private var otherError: String?
    @State private var done: String?

    private func chatKey(_ b: KiroCrew.Bot) -> String { ChatNames.normalize(KiroCrew.chatName(for: b)) }
    private func inChat(_ b: KiroCrew.Bot) -> Bool { model.bots.contains { $0.name == chatKey(b) } }
    private func hasTrigger(_ b: KiroCrew.Bot) -> Bool { model.trigger(for: chatKey(b)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adicionar bots").font(.title2.bold())

            if KiroCrew.isInstalled {
                crewSection
            } else {
                Label("Kiro Crew não encontrado neste Mac. Adicione os bots pelo nome abaixo.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Divider()
            otherSection

            if let done {
                Label(done, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            crewBots = KiroCrew.bots()
            // Já vêm marcados os que ainda não estão no chat (ou estão sem gatilho).
            selected = Set(crewBots.filter { !inChat($0) || !hasTrigger($0) }.map(\.key))
        }
    }

    @ViewBuilder private var crewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bots do Kiro Crew").font(.headline)
            Text("Eles entram no chat com o primeiro nome. O chat acorda cada um quando for mencionado e publica a resposta dele. O Bot não precisa fazer nada nem gastar tokens para entrar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if crewBots.isEmpty {
                Text("Nenhum Bot encontrado em \(KiroCrew.dataHome.path)/config.json.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(crewBots) { b in
                            Toggle(isOn: Binding(
                                get: { selected.contains(b.key) },
                                set: { if $0 { selected.insert(b.key) } else { selected.remove(b.key) } }
                            )) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("@\(KiroCrew.chatName(for: b))").bold()
                                    Text(b.label).foregroundStyle(.secondary)
                                    Spacer()
                                    status(b)
                                }
                            }
                            .help(b.description.isEmpty ? "Chave no Kiro Crew: \(b.key)"
                                  : "\(b.description)\nChave no Kiro Crew: \(b.key)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Altura fixa: dentro de um sheet, ScrollView sem altura definida encolhe até sumir.
                .frame(height: min(CGFloat(crewBots.count) * 26, 182))

                Toggle("Criar gatilho de chamada (acorda o Bot quando for mencionado)", isOn: $withTrigger)
                    .help("Gatilhos que já existem não são alterados.")

                HStack {
                    Spacer()
                    Button("Adicionar \(selected.count) bot(s)") {
                        let added = model.addCrewBots(crewBots.filter { selected.contains($0.key) }, withTrigger: withTrigger)
                        if !added.isEmpty {
                            done = "Prontos no chat: " + added.map { "@\($0)" }.joined(separator: ", ")
                            selected.removeAll()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    @ViewBuilder private func status(_ b: KiroCrew.Bot) -> some View {
        if inChat(b) {
            Text(hasTrigger(b) ? "no chat · com gatilho" : "no chat · sem gatilho")
                .font(.caption)
                .foregroundStyle(hasTrigger(b) ? .green : .orange)
        }
    }

    @ViewBuilder private var otherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Outro bot").font(.headline)
            HStack {
                TextField("Nome (ex: Arya)", text: $otherName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                TextField("O que ele faz", text: $otherDescription)
                    .textFieldStyle(.roundedBorder)
                Button("Adicionar") {
                    otherError = model.addBot(name: otherName, description: otherDescription)
                    if otherError == nil {
                        done = "\(ChatNames.displayName(fromRaw: otherName)) entrou no chat. Configure o gatilho dele com o botão direito no nome."
                        otherName = ""
                        otherDescription = ""
                    }
                }
                .disabled(ChatNames.normalize(otherName).isEmpty)
            }
            if let otherError {
                Text(otherError).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
