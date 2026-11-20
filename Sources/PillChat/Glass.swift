import AppKit
import LinkPresentation
import SwiftUI

// MARK: - Fondus

/// Dégradé doux (beaucoup d'étapes, courbe smoothstep) pour fondre une couleur ou un masque.
func smoothGradient(_ color: Color, from a: Double, to b: Double, steps: Int = 16) -> Gradient {
    Gradient(stops: (0...steps).map { i in
        let t = Double(i) / Double(steps)
        let e = t * t * (3 - 2 * t)
        return .init(color: color.opacity(a + (b - a) * e), location: t)
    })
}

// MARK: - Liens enrichis, comme dans iMessage

enum LinkMetadataCache {
    private static var cache: [URL: LPLinkMetadata] = [:]
    private static var loading: Set<URL> = []
    private static var waiters: [URL: [(LPLinkMetadata?) -> Void]] = [:]

    /// Récupère titre, image, icône… (sur le thread principal).
    static func fetch(_ url: URL, completion: @escaping (LPLinkMetadata?) -> Void) {
        if let m = cache[url] { completion(m); return }
        waiters[url, default: []].append(completion)
        guard !loading.contains(url) else { return }
        loading.insert(url)
        let provider = LPMetadataProvider()
        provider.timeout = 10
        provider.startFetchingMetadata(for: url) { meta, _ in
            DispatchQueue.main.async {
                loading.remove(url)
                if let meta { cache[url] = meta }
                let list = waiters.removeValue(forKey: url) ?? []
                list.forEach { $0(meta) }
            }
        }
    }

    static func cached(_ url: URL) -> LPLinkMetadata? { cache[url] }
}

/// La carte de lien native d'Apple (LPLinkView) : même rendu que dans Messages
/// (pochette Apple Music, vignette YouTube, image d'article…).
struct LinkCard: NSViewRepresentable {
    let url: URL
    let width: CGFloat
    let metadata: LPLinkMetadata?

    func makeNSView(context: Context) -> LPLinkView {
        let v = LPLinkView(url: url)
        if let metadata { v.metadata = metadata }
        return v
    }

    func updateNSView(_ v: LPLinkView, context: Context) {
        if let metadata, v.metadata !== metadata { v.metadata = metadata }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LPLinkView, context: Context) -> CGSize? {
        // LPLinkView calcule sa hauteur pour une largeur donnée.
        nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
        nsView.layoutSubtreeIfNeeded()
        let h = nsView.intrinsicContentSize.height > 0 ? nsView.intrinsicContentSize.height : nsView.fittingSize.height
        return CGSize(width: width, height: max(h, 40))
    }
}

struct LinkAttachment: View {
    let url: URL
    let S: CGFloat
    private let _metaBox = State<LPLinkMetadata?>(initialValue: nil)
    private var meta: LPLinkMetadata? { get { _metaBox.wrappedValue } nonmutating set { _metaBox.wrappedValue = newValue } }

    var body: some View {
        LinkCard(url: url, width: 340 * S, metadata: meta ?? LinkMetadataCache.cached(url))
            .id(meta == nil ? 0 : 1) // nouvelle vue une fois les infos reçues : la taille est recalculée
            .onAppear {
                guard meta == nil else { return }
                LinkMetadataCache.fetch(url) { m in
                    if let m { withAnimation(.easeOut(duration: 0.2)) { meta = m } }
                }
            }
    }
}

extension String {
    /// Liens http(s) présents dans le texte.
    var links: [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { m in
            guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            return u
        }
    }

    /// Le texte n'est qu'un lien (on affiche alors seulement la carte, comme Messages).
    var isOnlyLink: Bool {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = t.links.first, t.links.count == 1 else { return false }
        return t == u.absoluteString || t == u.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            || !t.contains(" ")
    }
}

// MARK: - Flou progressif en bas de la pilule

/// Flou natif de macOS (il floute ce qui défile dessous), estompé par un masque en dégradé doux :
/// rien en haut, de plus en plus flou vers le bas. Un voile de la couleur de la pilule finit la transition.
struct ProgressiveBlur: View {
    /// Côté où le flou est le plus fort (bas : sous la saisie, haut : sous l'en-tête).
    var edge: VerticalEdge = .bottom

    var body: some View {
        let toward: UnitPoint = edge == .bottom ? .bottom : .top
        let away: UnitPoint = edge == .bottom ? .top : .bottom
        ZStack {
            BackdropBlur()
                .mask(LinearGradient(gradient: smoothGradient(.black, from: 0, to: 1, steps: 32),
                                     startPoint: away, endPoint: UnitPoint(x: 0.5, y: edge == .bottom ? 0.42 : 0.3)))
            LinearGradient(gradient: smoothGradient(D.bg, from: 0, to: 0.2, steps: 32),
                           startPoint: UnitPoint(x: 0.5, y: edge == .bottom ? 0.15 : 0.85), endPoint: toward)
        }
    }
}

struct BackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu // flou plus dépoli derrière la zone de saisie
        v.blendingMode = .withinWindow
        v.state = .active // reste vivant même quand la fenêtre n'est pas au premier plan
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
