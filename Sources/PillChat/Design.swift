import AppKit
import SwiftUI

// MARK: - Design (valeurs exactes du fichier Paper, en unités de design ; multipliées par `S` à l'écran)

enum D {
    static let width: CGFloat = 727
    static let tallHeight: CGFloat = 590

    // Couleurs qui suivent le mode clair / sombre.
    static let bg = Color.adaptive(light: 0xEDEDED, dark: 0x1E1E20)
    static let field = Color.adaptive(light: 0xF9F9F9, dark: 0x2C2C2E)
    static let disc = Color.adaptive(light: 0xF7F7F7, dark: 0x2C2C2E)
    /// Texte et icônes : noir en clair, blanc en sombre.
    static let ink = Color.adaptive(light: 0x000000, dark: 0xFFFFFF)
    /// Petites surfaces opaques (bulle d'aperçu, disque du verrou…).
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x3A3A3C)
    static let blue = Color(hex: 0x007BFF)
    static let orange = Color(hex: 0xFF6500)
    /// Bulles reçues : gris clair, texte foncé.
    static let received = Color.adaptive(light: 0xFFFFFF, dark: 0x3A3A3C, lightAlpha: 0.82, darkAlpha: 0.85)
    static let red = Color(hex: 0xFF3A2C)
    static let stop = Color(hex: 0xFFA8A1)
    static let avatar = Color.adaptive(light: 0xDDDDDD, dark: 0x48484A)
    static let grabber = Color(hex: 0xD3D3D3)
    static let placeholder = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.22, darkAlpha: 0.3)

    /// Fond de la pilule en Liquid Glass (mode démo) au lieu du flou habituel.
    nonisolated(unsafe) static var glassPill = false

    static let control: CGFloat = 76
    static let pillRadius: CGFloat = 61
    static let panelRadius: CGFloat = 72

    /// Réactions de la notif compacte (7) et de la conversation (9).
    static let quickReactions = ["🤘🏿", "🌶️", "💜", "✨", "🤪", "🤔", "👽"]
    static let reactions = ["🤘🏿", "🌶️", "💜", "✨", "🤪", "🤔", "🧟", "👽", "🐤"]

    // Ressorts repris de PillMusic.
    /// Morph notif ↔ conversation ↔ recherche (le même que l'ouverture de la pilule).
    /// Passage accueil ↔ conversation : ressort doux, sans à-coup.
    static let island = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// Courbe douce sans rebond (ease-out « quint ») pour les apparitions.
    static let smooth = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)
    /// Apparition (scale + flou + fondu).
    static let appear = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.8)
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let wobble = Animation.spring(response: 0.3, dampingFraction: 0.65)

    /// SF Pro, la police du Mac. Graisses du design : 400 = normal, 500 = medium.
    static func font(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        .system(size: size, weight: weight >= 600 ? .semibold : (weight >= 500 ? .medium : .regular))
    }
}

extension Color {
    /// Couleur résolue selon l'apparence (clair / sombre) au moment du dessin.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func ns(_ hex: UInt32, _ a: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark, darkAlpha) : ns(light, lightAlpha)
        })
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Glissé + flou + fondu (transitions de texte de PillMusic).
struct SlideBlur: ViewModifier {
    var x: CGFloat = 0
    var y: CGFloat = 0
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.offset(x: x, y: y).blur(radius: blur).opacity(opacity)
    }
}

extension AnyTransition {
    static func slideBlur(x: CGFloat = 0, y: CGFloat = 0, blur: CGFloat = 6) -> AnyTransition {
        .modifier(active: SlideBlur(x: x, y: y, blur: blur, opacity: 0),
                  identity: SlideBlur(x: 0, y: 0, blur: 0, opacity: 1))
    }
}

// MARK: - Icônes Lucide (tracés du fichier Paper, viewBox 24×24)

enum Glyph { case chevronLeft, mic, trash, play, stop, arrowUp, phone }

struct GlyphShape: Shape {
    let glyph: Glyph

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        switch glyph {
        case .chevronLeft:
            path.move(to: p(15, 18)); path.addLine(to: p(9, 12)); path.addLine(to: p(15, 6))
        case .mic:
            path.addRoundedRect(in: CGRect(origin: p(9, 2), size: CGSize(width: 6 * k, height: 13 * k)),
                                cornerSize: CGSize(width: 3 * k, height: 3 * k))
            path.move(to: p(19, 10)); path.addLine(to: p(19, 12))
            path.addArc(center: p(12, 12), radius: 7 * k, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: p(5, 10))
            path.move(to: p(12, 19)); path.addLine(to: p(12, 22))
        case .trash:
            path.move(to: p(3, 6)); path.addLine(to: p(21, 6))
            path.move(to: p(19, 6)); path.addLine(to: p(19, 20))
            path.addArc(tangent1End: p(19, 22), tangent2End: p(17, 22), radius: 2 * k)
            path.addLine(to: p(7, 22))
            path.addArc(tangent1End: p(5, 22), tangent2End: p(5, 20), radius: 2 * k)
            path.addLine(to: p(5, 6))
            path.move(to: p(8, 6)); path.addLine(to: p(8, 4))
            path.addArc(tangent1End: p(8, 2), tangent2End: p(10, 2), radius: 2 * k)
            path.addLine(to: p(14, 2))
            path.addArc(tangent1End: p(16, 2), tangent2End: p(16, 4), radius: 2 * k)
            path.addLine(to: p(16, 6))
            path.move(to: p(10, 11)); path.addLine(to: p(10, 17))
            path.move(to: p(14, 11)); path.addLine(to: p(14, 17))
        case .arrowUp:
            path.move(to: p(5, 12)); path.addLine(to: p(12, 5)); path.addLine(to: p(19, 12))
            path.move(to: p(12, 19)); path.addLine(to: p(12, 5))
        case .phone:
            break // dessiné avec le symbole système (voir GlyphView)
        case .play:
            path.move(to: p(6, 3)); path.addLine(to: p(20, 12)); path.addLine(to: p(6, 21)); path.closeSubpath()
        case .stop:
            path.addRoundedRect(in: CGRect(origin: p(2, 2), size: CGSize(width: 20 * k, height: 20 * k)),
                                cornerSize: CGSize(width: 4 * k, height: 4 * k))
        }
        return path
    }
}

struct GlyphView: View {
    let glyph: Glyph
    let size: CGFloat
    var color: Color = D.ink

    var body: some View {
        Group {
            switch glyph {
            case .phone:
                Image(systemName: "phone.fill")
                    .font(.system(size: size * 0.78, weight: .medium))
                    .foregroundStyle(color)
            case .play, .stop:
                GlyphShape(glyph: glyph).fill(color)
            default:
                GlyphShape(glyph: glyph)
                    .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Journal de débogage (~/Library/Logs/PillChat.log)

private let logQueue = DispatchQueue(label: "pillchat.log")
private let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/PillChat.log")

func dlog(_ message: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
