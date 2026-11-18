import SwiftUI

/// Visual do app: escuro, com painéis arredondados e roxo como cor de destaque.
enum Theme {
    static let accent = Color(red: 0.56, green: 0.36, blue: 1.0)
    /// Fundo da janela.
    static let background = Color(red: 0.075, green: 0.067, blue: 0.086)
    /// Painéis (barra lateral).
    static let panel = Color(red: 0.106, green: 0.098, blue: 0.122)
    /// Cartões (mensagens dos bots, campo de mensagem).
    static let card = Color(red: 0.137, green: 0.125, blue: 0.157)
    static let cardHover = Color(red: 0.165, green: 0.150, blue: 0.192)
    /// Linha selecionada na barra lateral.
    static let selection = Color(red: 0.20, green: 0.16, blue: 0.27)
    static let stroke = Color.white.opacity(0.07)
    static let secondaryText = Color.white.opacity(0.56)
    static let tertiaryText = Color.white.opacity(0.36)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.24)

    static let radius: CGFloat = 14
    /// Datas relativas ("há 5 minutos") em português, mesmo com o macOS em outro idioma.
    static let locale = Locale(identifier: "pt_BR")
}

extension View {
    /// Cartão arredondado do tema.
    func themeCard(_ fill: Color = Theme.card, radius: CGFloat = Theme.radius, stroke: Color = Theme.stroke) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke))
    }
}

/// Botão só com ícone, discreto, que acende ao passar o mouse.
struct IconButton: View {
    let systemName: String
    var tint: Color = Theme.secondaryText
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hover ? Color.white : tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.cardHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Título de seção da barra lateral ("CANAIS", "BOTS").
struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Contador de não lidas.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Theme.accent))
            .foregroundStyle(.white)
    }
}
