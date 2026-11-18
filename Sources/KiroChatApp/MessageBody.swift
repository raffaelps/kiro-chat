import AppKit
import KiroChatCore
import SwiftUI

/// Texto de uma mensagem com Markdown: blocos de código, títulos, listas, citações, tabelas e linhas.
/// Mensagens sem Markdown de bloco continuam sendo um só texto (com Markdown inline e @menções).
struct MessageBody: View {
    let text: String
    let me: String
    var handles: [String: String] = [:]
    /// Dentro do balão roxo (minhas mensagens).
    var onAccent = false

    var body: some View {
        let blocks = Markdown.parse(text)
        if Markdown.isSimple(blocks) {
            inline(text)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
        }
    }

    private var secondary: Color { onAccent ? Color.white.opacity(0.75) : Theme.secondaryText }

    private func inline(_ s: String) -> some View {
        Text(MessageText.render(s, me: me, handles: handles, onAccent: onAccent))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s)
        case .heading(let level, let s):
            inline(s)
                .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: level == 1 ? .bold : .semibold))
                .padding(.top, 2)
        case .code(let language, let code):
            CodeBlock(language: language, code: code, onAccent: onAccent)
        case .listItem(let marker, let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(marker == "•" ? (onAccent ? Color.white : Theme.accent) : secondary)
                    .frame(minWidth: 12, alignment: .trailing)
                inline(s)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(onAccent ? Color.white.opacity(0.6) : Theme.accent.opacity(0.8))
                    .frame(width: 3)
                inline(s).foregroundStyle(secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, me: me, handles: handles, onAccent: onAccent)
        case .rule:
            Rectangle()
                .fill(onAccent ? Color.white.opacity(0.3) : Theme.stroke)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }
}

/// Bloco de código: fonte monoespaçada, fundo escuro, linguagem e botão de copiar.
struct CodeBlock: View {
    let language: String
    let code: String
    var onAccent = false
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "código" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(onAccent ? Color.white.opacity(0.7) : Theme.tertiaryText)
                Spacer(minLength: 12)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(onAccent ? Color.white.opacity(0.8) : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .opacity(hover || copied ? 1 : 0.5)
                .help("Copiar o código")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(onAccent ? 0.08 : 0.03))

            Text(code.isEmpty ? " " : code)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(Color.white.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(onAccent ? 0.28 : 0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
    }
}

/// Tabela Markdown simples.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let me: String
    let handles: [String: String]
    var onAccent = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    cellText(cell).fontWeight(.semibold)
                }
            }
            Rectangle()
                .fill(onAccent ? Color.white.opacity(0.3) : Theme.stroke)
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in cellText(cell) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(onAccent ? 0.15 : 0.2)))
    }

    private func cellText(_ s: String) -> some View {
        Text(MessageText.render(s, me: me, handles: handles, onAccent: onAccent))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
