import AppKit
import KiroChatCore
import SwiftUI

/// Procura versões novas no GitHub e instala dentro do próprio app.
///
/// Instalar = baixar o KiroChat.zip da release, conferir o SHA-256, conferir que é o mesmo app
/// (bundle id e versão), e trocar o .app instalado por ele. A troca é feita por um script pequeno
/// que espera o app fechar, move o app novo para o lugar do antigo e abre de novo.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate.Release)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var showSheet = false
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }
    @Published private(set) var lastChecked: Date?

    /// Release nova encontrada (fica guardada mesmo se o usuário fechar a janela).
    @Published private(set) var available: AppUpdate.Release?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    private var timer: Timer?

    /// Para testes: KIRO_CHAT_UPDATE_URL aponta para outro JSON no formato da API do GitHub.
    private var feedURL: URL {
        ProcessInfo.processInfo.environment["KIRO_CHAT_UPDATE_URL"].flatMap(URL.init(string:)) ?? AppUpdate.latestReleaseURL
    }

    private var installedApp: URL { Bundle.main.bundleURL }

    /// Só dá para se trocar sozinho quando roda de um .app (não via `swift run`).
    var installBlocker: String? {
        guard installedApp.pathExtension == "app" else { return "O app está rodando fora de um .app (swift run)." }
        let parent = installedApp.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return "Sem permissão para escrever em \(parent). Baixe pelo GitHub e substitua o app manualmente."
        }
        return nil
    }

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    /// Verifica ao abrir e depois a cada 6 horas (se a verificação automática estiver ligada).
    func start() {
        guard timer == nil else { return }
        if autoCheck { check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheck else { return }
                self.check(userInitiated: false)
            }
        }
    }

    /// `userInitiated`: mostra o resultado (inclusive "já está na mais recente" e erros).
    func check(userInitiated: Bool) {
        if userInitiated { showSheet = true }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        Task {
            do {
                var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("KiroChat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    throw AppUpdate.UpdateError.invalidFeed("nenhuma versão publicada ainda")
                }
                let release = try AppUpdate.parseRelease(data)
                lastChecked = Date()
                if AppUpdate.isNewer(release.version, than: currentVersion) {
                    available = release
                    state = .available(release)
                } else {
                    available = nil
                    state = .upToDate
                }
            } catch {
                // Verificação automática falhando (sem internet, limite da API) não incomoda ninguém.
                state = userInitiated ? .failed(error.localizedDescription) : (available.map(State.available) ?? .idle)
            }
        }
    }

    func install(_ release: AppUpdate.Release) {
        if let blocker = installBlocker {
            state = .failed(blocker)
            return
        }
        state = .downloading
        Task {
            do {
                let newApp = try await download(release)
                state = .installing
                try relaunch(replacingWith: newApp)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Baixar e conferir

    private func download(_ release: AppUpdate.Release) async throws -> URL {
        // Pasta temporária no mesmo volume do app instalado: a troca final é um `mv`, sem cópia.
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: installedApp, create: true)
        let (tmpZip, _) = try await URLSession.shared.download(from: release.zipURL)
        let zip = staging.appendingPathComponent(AppUpdate.zipName)
        try FileManager.default.moveItem(at: tmpZip, to: zip)

        if let checksumURL = release.checksumURL {
            let (data, _) = try await URLSession.shared.data(from: checksumURL)
            guard let expected = AppUpdate.expectedChecksum(from: String(decoding: data, as: UTF8.self)) else {
                throw AppUpdate.UpdateError.invalidPackage("checksum da release ilegível")
            }
            guard try AppUpdate.sha256(of: zip) == expected else { throw AppUpdate.UpdateError.checksumMismatch }
        }

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        let app = staging.appendingPathComponent("KiroChat.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw AppUpdate.UpdateError.invalidPackage("KiroChat.app não encontrado no zip")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw AppUpdate.UpdateError.invalidPackage("o app do zip não é o Kiro Chat")
        }
        guard info["CFBundleShortVersionString"] as? String == release.version else {
            throw AppUpdate.UpdateError.invalidPackage("a versão do app no zip não é \(release.version)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        return app
    }

    // MARK: - Trocar e reabrir

    private func relaunch(replacingWith newApp: URL) throws {
        let dest = installedApp.path
        // Espera este processo sair, troca o app (com volta atrás se der errado), reinicia o
        // despachante em segundo plano (se instalado) e abre a versão nova.
        let script = """
        PID="$1"; NEW="$2"; DEST="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="$DEST.old-$$"
        mv "$DEST" "$BACKUP" || { open "$DEST"; exit 1; }
        if mv "$NEW" "$DEST"; then rm -rf "$BACKUP"; else mv "$BACKUP" "$DEST"; fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        if [ -f "$HOME/Library/LaunchAgents/\(BackgroundDispatcher.label).plist" ]; then
            launchctl kickstart -k "gui/$(id -u)/\(BackgroundDispatcher.label)" 2>/dev/null
        fi
        open "$DEST"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "kiro-chat-update", "\(getpid())", newApp.path, dest]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        showSheet = false
        // Uma janela aberta pode cancelar o "Sair"; se em 3 s o app não fechou, sai assim mesmo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AppUpdate.UpdateError.invalidPackage("\((tool as NSString).lastPathComponent) falhou: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// MARK: - Telas

/// Janela de atualização: verificando, já atualizado, versão nova (com novidades), baixando, erro.
struct UpdateSheet: View {
    @EnvironmentObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.state {
            case .idle, .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Procurando versões novas…")
                }
            case .upToDate:
                Label("Você está na versão mais recente (\(updater.currentVersion)).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .available(let r):
                available(r)
            case .downloading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Baixando e conferindo a versão nova…")
                }
            case .installing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Instalando. O Kiro Chat vai fechar e abrir de novo.")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = updater.available {
                    Link("Baixar a versão \(r.version) pelo GitHub", destination: r.pageURL)
                }
            }

            HStack {
                Spacer()
                if case .available(let r) = updater.state {
                    Link("Ver no GitHub", destination: r.pageURL)
                    Button("Depois") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Atualizar e reiniciar") { updater.install(r) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(updater.installBlocker != nil)
                } else if case .failed = updater.state {
                    Button("Tentar de novo") { updater.check(userInitiated: true) }
                    Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Fechar") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(updater.state == .downloading || updater.state == .installing)
                }
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    /// Notas da release (markdown do GitHub): títulos em negrito, listas com •, links e negrito inline.
    static func renderNotes(_ md: String) -> AttributedString {
        var out = AttributedString()
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            var heading = false
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                heading = true
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            var piece = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            if heading { piece.font = .system(size: 13, weight: .semibold) }
            if !out.characters.isEmpty { out.append(AttributedString("\n")) }
            out.append(piece)
        }
        return out
    }

    @ViewBuilder private func available(_ r: AppUpdate.Release) -> some View {
        Text("Kiro Chat \(r.version) disponível").font(.title2.bold())
        Text("Você tem a versão \(updater.currentVersion).\(r.publishedAt.map { " Publicada \($0.formatted(.relative(presentation: .named).locale(Theme.locale)))." } ?? "")")
            .foregroundStyle(Theme.secondaryText)
        if !r.notes.isEmpty {
            ScrollView {
                Text(Self.renderNotes(r.notes))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxHeight: 220)
            .themeCard(Theme.card, radius: 10)
        }
        if let blocker = updater.installBlocker {
            Text(blocker).font(.caption).foregroundStyle(Theme.warning)
        } else {
            Text("Suas mensagens, bots e gatilhos não mudam: ficam no banco de dados, fora do app.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// Aviso na barra lateral quando há versão nova.
struct UpdateCard: View {
    @EnvironmentObject var updater: Updater
    @State private var hover = false

    var body: some View {
        if let r = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nova versão \(r.version)").font(.system(size: 12, weight: .semibold))
                    Text("Clique para ver e atualizar").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .themeCard(hover ? Theme.selection : Theme.accent.opacity(0.12), radius: 10, stroke: Theme.accent.opacity(0.35))
            .contentShape(Rectangle())
            .onTapGesture { updater.showSheet = true }
            .onHover { hover = $0 }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}
