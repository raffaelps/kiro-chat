import CryptoKit
import Foundation

/// Versões do app (X.Y.Z) e a release mais recente publicada no GitHub.
///
/// Cada release (criada pelo GitHub Actions a partir de uma tag `vX.Y.Z`) traz o `KiroChat.zip`
/// e o `KiroChat.zip.sha256`. O app compara a versão dela com a instalada e, se for maior, oferece atualizar.
public enum AppUpdate {
    /// Release mais recente (a API do GitHub ignora rascunhos e pré-releases).
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/raffaelps/kiro-chat/releases/latest")!
    public static let zipName = "KiroChat.zip"
    public static let checksumName = "KiroChat.zip.sha256"

    public struct Release: Equatable, Sendable {
        public let version: String
        public let notes: String
        public let pageURL: URL
        public let zipURL: URL
        public let checksumURL: URL?
        public let publishedAt: Date?

        public init(version: String, notes: String, pageURL: URL, zipURL: URL, checksumURL: URL?, publishedAt: Date?) {
            self.version = version
            self.notes = notes
            self.pageURL = pageURL
            self.zipURL = zipURL
            self.checksumURL = checksumURL
            self.publishedAt = publishedAt
        }
    }

    public enum UpdateError: Error, LocalizedError, Equatable {
        case invalidFeed(String)
        case checksumMismatch
        case invalidPackage(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFeed(let why): return "Não consegui ler a release: \(why)"
            case .checksumMismatch: return "O arquivo baixado não confere com o checksum da release. Nada foi alterado."
            case .invalidPackage(let why): return "O pacote baixado não é válido: \(why)"
            }
        }
    }

    /// "v1.2.3" ou "1.2.3" → [1, 2, 3]. Nil se não for uma versão.
    public static func components(_ version: String) -> [Int]? {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        let nums = parts.compactMap { Int($0) }
        return nums.count == parts.count ? nums : nil
    }

    /// `remote` é uma versão maior que `local`? Versões inválidas nunca são "maiores".
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let r = components(remote), let l = components(local) else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Lê a resposta de `GET /repos/{owner}/{repo}/releases/latest`.
    public static func parseRelease(_ data: Data) throws -> Release {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.invalidFeed("resposta não é JSON")
        }
        guard let tag = json["tag_name"] as? String, let version = components(tag) else {
            throw UpdateError.invalidFeed(json["message"] as? String ?? "sem tag de versão")
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let zip = asset(zipName) else { throw UpdateError.invalidFeed("a release \(tag) não tem o \(zipName)") }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? zip
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: version.map(String.init).joined(separator: "."),
                       notes: json["body"] as? String ?? "",
                       pageURL: page, zipURL: zip, checksumURL: asset(checksumName), publishedAt: published)
    }

    /// SHA-256 (hex) de um arquivo.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash esperado a partir do conteúdo de um `.sha256` ("<hash>  KiroChat.zip").
    public static func expectedChecksum(from text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hash = first.lowercased()
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }
}
