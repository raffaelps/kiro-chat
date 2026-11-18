// Gera o ícone do app (Resources/AppIcon.icns) desenhando em código.
// Uso: swift scripts/make-icon.swift   (depois rode scripts/build-app.sh)
//
// Visual: quadrado arredondado no roxo do app, com dois balões de conversa — os bots conversando.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Balão de conversa com rabinho embaixo (à esquerda ou à direita), que nasce de dentro do canto do balão.
/// Preenche o corpo e o rabinho separadamente: num só caminho, a sobreposição pode virar um furo.
func fillBubble(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, tailLeft: Bool) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.addPath(tail(rect, tailLeft: tailLeft))
    ctx.fillPath()
}

func tail(_ rect: CGRect, tailLeft: Bool) -> CGPath {
    let p = CGMutablePath()
    let w = rect.width, h = rect.height
    // Espelha x para o rabinho da esquerda.
    func X(_ fromRight: CGFloat) -> CGFloat { tailLeft ? rect.minX + fromRight * w : rect.maxX - fromRight * w }
    let a = CGPoint(x: X(0.34), y: rect.minY + h * 0.14)
    let b = CGPoint(x: X(0.10), y: rect.minY + h * 0.16)
    let tip = CGPoint(x: X(0.04), y: rect.minY - h * 0.17)
    p.move(to: a)
    p.addQuadCurve(to: tip, control: CGPoint(x: X(0.16), y: rect.minY - h * 0.02))
    p.addQuadCurve(to: b, control: CGPoint(x: X(0.06), y: rect.minY))
    p.closeSubpath()
    return p
}

/// Desenha o ícone num quadrado de 1024 pontos (a escala é aplicada fora).
func drawIcon(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    // Grade de ícones do macOS: corpo de 824 com margem de 100 e cantos ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Sombra do corpo.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.33, 0.18, 0.78))
    ctx.fillPath()
    ctx.restoreGState()

    // Fundo: degradê roxo (claro em cima, profundo embaixo).
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0.66, 0.47, 1.0), color(0.50, 0.30, 0.96), color(0.29, 0.14, 0.70)] as CFArray,
                              locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: canvas * 0.3, y: body.maxY), end: CGPoint(x: canvas * 0.7, y: body.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Brilho suave no topo.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 360, y: 860), endRadius: 520, options: [])
    ctx.restoreGState()

    // Balão de trás (outro bot): branco translúcido, à esquerda e mais alto.
    let back = CGRect(x: 214, y: 500, width: 430, height: 300)
    ctx.saveGState()
    ctx.setAlpha(0.30)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(1, 1, 1))
    fillBubble(ctx, back, radius: 130, tailLeft: true)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Balão da frente: branco, à direita e mais baixo, com sombra.
    let front = CGRect(x: 372, y: 300, width: 450, height: 310)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0.12, 0.03, 0.35, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(1, 1, 1))
    fillBubble(ctx, front, radius: 135, tailLeft: false)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Três pontos ("digitando") no balão da frente.
    let dot: CGFloat = 54, gap: CGFloat = 34
    let total = dot * 3 + gap * 2
    var x = front.midX - total / 2
    for i in 0..<3 {
        let shade: [CGFloat] = [0.55, 0.42, 0.30]
        ctx.setFillColor(color(shade[i] * 0.95 + 0.05, shade[i] * 0.45, 0.95 - CGFloat(i) * 0.08))
        ctx.fillEllipse(in: CGRect(x: x, y: front.midY - dot / 2, width: dot, height: dot))
        x += dot + gap
    }
}

func png(size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { throw NSError(domain: "icon", code: 1) }
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    gc.flushGraphics()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "icon", code: 2) }
    return data
}

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let out = resources.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil falhou") }
print("✅ \(out.path)")
