import Foundation

/// Markdown das mensagens, dividido em blocos para o app desenhar: blocos de código, títulos,
/// listas, citações, tabelas e linhas. O texto de cada bloco ainda pode ter Markdown inline
/// (**negrito**, *itálico*, `código`, [links](url)), que o app interpreta na hora de mostrar.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, code: String)
    /// Item de lista. `marker` é "•" ou o número ("1."); `indent` é o nível de recuo (0, 1, 2...).
    case listItem(marker: String, text: String, indent: Int)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public enum Markdown {
    /// Texto que diz aos bots o que o chat sabe mostrar.
    public static let botHint = """
    O chat mostra Markdown: **negrito**, *itálico*, `código`, blocos de código com a linguagem (```python), \
    listas, títulos (#), citações (>), tabelas e links. Use quando ajudar a leitura; para respostas curtas, texto simples basta.
    """

    /// Nenhum Markdown de bloco: o app pode desenhar a mensagem como um só texto.
    public static func isSimple(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.allSatisfy { if case .paragraph = $0 { return true } else { return false } }
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            let p = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !p.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.paragraph(p)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Bloco de código: ``` ou ~~~, com a linguagem opcional. Sem fechamento, vai até o fim.
            if let fence = fenceMarker(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence),
                       l.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first }) { break }
                    // Tira o recuo do ``` (blocos dentro de listas).
                    var stripped = Substring(l)
                    var n = 0
                    while n < indent, stripped.first == " " { stripped = stripped.dropFirst(); n += 1 }
                    code.append(String(stripped))
                    i += 1
                }
                blocks.append(.code(language: language.split(separator: " ").first.map(String.init) ?? "",
                                    code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty { flush(); i += 1; continue }

            // Título: "# ", "## "... (até 6).
            if let h = heading(trimmed) {
                flush()
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // Linha horizontal: ---, ***, ___ (3 ou mais, espaços permitidos).
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, let c = compact.first, "-*_".contains(c), compact.allSatisfy({ $0 == c }) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Tabela: linha com | seguida da linha separadora (|---|:--:|).
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, r.contains("|") else { break }
                    var cells = tableCells(r)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(max(header.count, 1))))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Citação: linhas seguidas começando com ">".
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    var rest = q.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Item de lista: "- ", "* ", "+ " ou "1. " / "1) ".
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let indent = min(spaces / 2, 4)
        if let c = body.first, "-*+".contains(c), body.dropFirst().first == " " {
            var text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // Tarefas: "- [ ]" e "- [x]".
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
            return .listItem(marker: marker, text: text, indent: indent)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " {
                return .listItem(marker: String(digits) + ".", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces), indent: indent)
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        let cells = tableCells(t)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.contains("-") && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
