import AppKit
import SwiftUI

// MARK: - Racine

struct ContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct RootView: View {
    @ObservedObject var c: ChatController
    @ObservedObject var store: MessagesStore
    @ObservedObject var recorder: VoiceRecorder
    @Namespace private var ns

    static let margin: CGFloat = 40

    var body: some View {
        let S = c.S
        let shape = RoundedRectangle(cornerRadius: D.panelRadius * S, style: .continuous)
        Group {
            if c.mode == .setup {
                SetupView(c: c, ns: ns)
            } else {
                // Une seule pilule pour l'accueil et la conversation : son fond s'étire en douceur vers la
                // hauteur du nouvel écran pendant que les contenus se fondent l'un dans l'autre.
                // Hauteur naturelle de l'écran affiché : SwiftUI anime lui-même le changement de taille
                // (aucune hauteur mesurée à part, donc rien ne peut être rogné).
                ZStack(alignment: .top) {
                    if c.mode == .conversation {
                        ConversationView(c: c, recorder: recorder, ns: ns)
                            .transition(.organic)
                    } else {
                        PickerView(c: c, store: store, ns: ns)
                            .transition(.organic)
                    }
                }
                .clipShape(shape)
                .modifier(PillBackground(S: S))
            }
        }
        .frame(width: D.width * S)
        // Zone visible, en coordonnées de la fenêtre : hors de cette zone, la souris traverse la fenêtre.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { r in
            c.contentRect = r
        }
        // Déplacement : étirement léger dans le sens du mouvement et lévitation discrète.
        .scaleEffect(x: c.squash.width, y: c.squash.height, anchor: .top)
        .scaleEffect(c.isMoving ? 1.015 : 1)
        // Apparition : léger grossissement + flou + fondu.
        .scaleEffect(c.shown ? 1 : 0.88, anchor: .top)
        .blur(radius: c.shown ? 0 : 6)
        .opacity(c.shown ? 1 : 0)
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .coordinateSpace(name: "root")
        // Toujours l'apparence « fenêtre active » : rien ne s'assombrit quand on clique ailleurs.
        .environment(\.controlActiveState, .key)

    }
}

// MARK: - Transition organique entre écrans

/// L'écran sortant se dissout (flou + fondu + très léger recul), l'entrant se condense à sa place.
struct OrganicFade: ViewModifier {
    let progress: Double // 0 = invisible, 1 = visible
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 12)
            .scaleEffect(0.97 + 0.03 * progress, anchor: .top)
    }
}

extension AnyTransition {
    static var organic: AnyTransition {
        .modifier(active: OrganicFade(progress: 0), identity: OrganicFade(progress: 1))
    }
}

// MARK: - Briques

/// Fond gris clair à liseré blanc du design.
struct Surface: View {
    let radius: CGFloat
    let S: CGFloat
    var fill: Color = D.bg
    var shadow = true
    /// Fond semi-transparent avec le flou de ce qu'il y a derrière la fenêtre (bureau, autres apps).
    var translucent = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if translucent {
                WindowBlur().clipShape(shape)
            }
            shape.fill(fill.opacity(translucent ? 0.6 : 1))
        }
        // Contour très discret : juste un liseré de lumière sur le bord.
        .overlay(shape.strokeBorder(.white.opacity(translucent ? 0.12 : 1), lineWidth: translucent ? 0.75 : max(1, 2 * S)))
        // Ombre dessinée seulement à l'extérieur : avec un fond transparent, elle ne doit pas se voir à travers.
        .background(
            shape.fill(.black.opacity(shadow ? 0.15 : 0))
                .blur(radius: 26 * S)
                .offset(y: 10 * S)
                .mask(
                    Rectangle().padding(-120 * S)
                        .overlay(shape.blendMode(.destinationOut))
                        .compositingGroup()
                )
        )
    }
}

/// Flou natif de ce qui se trouve derrière la fenêtre.
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow // le flou système le plus léger
        v.blendingMode = .behindWindow
        v.state = .active // reste flou même quand une autre app est au premier plan
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Pastille de champ (#F9F9F9) avec la très légère ombre du design.
struct FieldSurface: View {
    let S: CGFloat
    var body: some View {
        // Arrondi = moitié de la hauteur d'une ligne : une pilule sur une ligne, un bloc arrondi quand le texte s'allonge.
        let shape = RoundedRectangle(cornerRadius: D.control * S / 2, style: .continuous)
        shape
            .fill(D.field)
            .overlay(shape.strokeBorder(.white, lineWidth: max(1, 2 * S)))
            .shadow(color: .black.opacity(0.04), radius: 27 * S)
    }
}

/// Bouton qui s'écrase à l'appui et gonfle au survol (ressorts de PillMusic).
struct Bouncy: ButtonStyle {
    var pressed: CGFloat = 0.9
    var hovered: CGFloat = 1.04
    private let _hoveringBox = State<Bool>(initialValue: false)
    private var hovering: Bool { get { _hoveringBox.wrappedValue } nonmutating set { _hoveringBox.wrappedValue = newValue } }

    func makeBody(configuration: Configuration) -> some View {
        // Effets volontairement discrets : on garde moins de la moitié de l'écrasement / du gonflement demandés.
        let down = 1 - (1 - pressed) * 0.6, up = 1 + (hovered - 1) * 0.85
        return configuration.label
            .scaleEffect(configuration.isPressed ? down : (hovering ? up : 1))
            .animation(D.press, value: configuration.isPressed)
            .animation(D.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Verre liquide (macOS 26+), avec repli sur le design plat

extension View {
    /// Verre liquide interactif d'Apple : il réagit comme une goutte au survol et à l'appui.
    /// Liquid Glass d'Apple (macOS 26+), interactif. La fenêtre garde toujours son apparence active
    /// (voir ChatPanel), donc le verre ne s'assombrit pas quand on clique ailleurs.
    @ViewBuilder
    func liquidGlass<S: Shape, F: View>(_ shape: S, tint: Color? = nil, @ViewBuilder fallback: () -> F) -> some View {
        if #available(macOS 26.0, *) {
            // Le verre est un fond séparé, posé derrière le contenu : icônes et texte restent
            // parfaitement centrés quand le bouton s'agrandit au survol.
            // Le contenu doit être DANS le verre : macOS dessine le verre sur un calque au-dessus du reste.
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? Glass.regular, in: shape)
        } else {
            self.background(fallback())
        }
    }

    /// Identité de verre : deux formes du même conteneur se fondent l'une dans l'autre (morph).
    @ViewBuilder
    func glassID(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) { self.glassEffectID(id, in: ns) } else { self }
    }
}

/// Conteneur où les formes de verre proches fusionnent et se transforment les unes dans les autres.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Remonte doucement depuis le bas en apparaissant (courbe fluide, sans rebond).
struct RiseIn: ViewModifier {
    let distance: CGFloat
    var delay: Double = 0.05
    private let _shownBox = State<Bool>(initialValue: false)
    private var shown: Bool { get { _shownBox.wrappedValue } nonmutating set { _shownBox.wrappedValue = newValue } }

    func body(content: Content) -> some View {
        content
            .offset(y: shown ? 0 : distance)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(D.smooth.delay(delay)) { shown = true } }
    }
}

struct CircleControl: View {
    let glyph: Glyph
    let S: CGFloat
    var color: Color = D.ink
    var fill: Color = D.field
    /// false : simple rond plein, sans verre ni contour.
    var glass = true
    /// Teinte du verre (ex. vert pour l'appel) ; sans teinte, verre neutre.
    var tint: Color? = nil
    let action: () -> Void
    private let _hoveringBox = State<Bool>(initialValue: false)
    private var hovering: Bool { get { _hoveringBox.wrappedValue } nonmutating set { _hoveringBox.wrappedValue = newValue } }

    var body: some View {
        // Zoom au survol par la vraie taille (+2 pt) et non par un effet d'échelle : le verre est recalculé
        // autour de l'icône, qui reste parfaitement centrée. La place est réservée (les voisins ne bougent pas).
        let side = D.control * S + (hovering ? 2 : 0)
        Button(action: action) {
            GlyphView(glyph: glyph, size: 29 * S, color: color)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .modifier(CircleBackground(glass: glass, fill: fill, S: S, tint: tint))
        }
        .buttonStyle(Bouncy(pressed: 0.95, hovered: 1))
        .frame(width: D.control * S + 2, height: D.control * S + 2)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { hovering = h } }
    }
}

struct CircleBackground: ViewModifier {
    let glass: Bool
    let fill: Color
    let S: CGFloat
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if glass {
            content.liquidGlass(Circle(), tint: tint) {
                Circle().fill(fill)
                    .overlay(Circle().strokeBorder(.white, lineWidth: max(1, 2 * S)))
                    .shadow(color: .black.opacity(0.04), radius: 27 * S)
            }
        } else {
            content.background(Circle().fill(fill).shadow(color: .black.opacity(0.06), radius: 10 * S, y: 3 * S))
        }
    }
}

/// Vignettes des fichiers à envoyer (image ou icône du fichier), avec une croix pour retirer.
struct DraftFilesRow: View {
    @ObservedObject var c: ChatController
    let S: CGFloat

    var body: some View {
        HStack(spacing: 10 * S) {
            ForEach(c.draftFiles, id: \.self) { url in
                ZStack(alignment: .topTrailing) {
                    Group {
                        let kind = Attachment(path: url.path, mime: "", name: url.lastPathComponent).kind
                        if kind == .image, let img = NSImage(contentsOf: url) {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else if kind == .video {
                            DraftVideoThumb(url: url, S: S)
                        } else {
                            VStack(spacing: 2 * S) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40 * S, height: 40 * S)
                                Text(url.lastPathComponent).font(D.font(12 * S)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(D.ink.opacity(0.6))
                            }
                            .padding(4 * S)
                        }
                    }
                    .frame(width: 78 * S, height: 78 * S)
                    .background(D.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18 * S, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 6 * S, y: 2 * S)

                    Button { c.removeFile(url) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26 * S))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(Bouncy(pressed: 0.85, hovered: 1.1))
                    .offset(x: 7 * S, y: -7 * S)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4 * S)
    }
}

struct DraftVideoThumb: View {
    let url: URL
    let S: CGFloat
    private let _thumbBox = State<NSImage?>(initialValue: nil)
    private var thumb: NSImage? { get { _thumbBox.wrappedValue } nonmutating set { _thumbBox.wrappedValue = newValue } }

    var body: some View {
        ZStack {
            if let thumb { Image(nsImage: thumb).resizable().scaledToFill() } else { Rectangle().fill(D.ink.opacity(0.08)) }
            Image(systemName: "play.fill").font(.system(size: 18 * S)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
        .task(id: url) { thumb = await VideoInfo.load(url.path)?.thumb }
    }
}

/// Bouton d'envoi : rond bleu (verre teinté) avec une flèche vers le haut.
struct SendButton: View {
    let S: CGFloat
    var dim = true
    let action: () -> Void
    private let _hoveringBox = State<Bool>(initialValue: false)
    private var hovering: Bool { get { _hoveringBox.wrappedValue } nonmutating set { _hoveringBox.wrappedValue = newValue } }

    var body: some View {
        // Zoom au survol par la vraie taille (+2 pt), pas par un effet d'échelle : le verre est recalculé
        // et la flèche reste parfaitement centrée. La place est réservée pour ne pas bouger les voisins.
        let side = D.control * S + (hovering ? 2 : 0)
        Button(action: action) {
            GlyphView(glyph: .arrowUp, size: 31 * S, color: .white)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .liquidGlass(Circle(), tint: D.blue) {
                    Circle().fill(D.blue)
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: max(1, 2 * S)))
                        .shadow(color: .black.opacity(0.04), radius: 27 * S)
                }
        }
        .buttonStyle(Bouncy(pressed: 0.96, hovered: 1))
        .frame(width: D.control * S + 2, height: D.control * S + 2)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { hovering = h } }
    }
}

struct BlueButton: View {
    let title: String
    let S: CGFloat
    var dim = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(D.font(24 * S))
                .foregroundStyle(.white)
                .fixedSize()
                .padding(.horizontal, 32 * S)
                .frame(height: D.control * S)
                .contentShape(Capsule())
                .liquidGlass(Capsule(), tint: D.blue) {
                    Capsule().fill(D.blue)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: max(1, 2 * S)))
                        .shadow(color: .black.opacity(0.04), radius: 27 * S)
                }
        }
        .buttonStyle(Bouncy(pressed: 0.94, hovered: 1.05))
    }
}

/// Rangée d'emojis : apparition de gauche à droite et loupe au survol, comme le Dock.
struct EmojiRow: View {
    let emojis: [String]
    let size: CGFloat
    let S: CGFloat
    let action: (String) -> Void
    private let _hoveredBox = State<Int?>(initialValue: nil)
    private var hovered: Int? { get { _hoveredBox.wrappedValue } nonmutating set { _hoveredBox.wrappedValue = newValue } }
    private let _appearedBox = State<Bool>(initialValue: false)
    private var appeared: Bool { get { _appearedBox.wrappedValue } nonmutating set { _appearedBox.wrappedValue = newValue } }

    private static let magnify = Animation.spring(response: 0.3, dampingFraction: 0.75)

    private func scale(_ i: Int) -> CGFloat {
        guard let h = hovered else { return 1 }
        switch abs(i - h) {
        case 0: return 1.38
        case 1: return 1.12
        default: return 1
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(emojis.enumerated()), id: \.offset) { i, e in
                EmojiButton(emoji: e, size: size) { action(e) }
                    .demoTarget("emoji\(i)")
                    .scaleEffect(scale(i), anchor: .bottom)
                    .offset(y: hovered == i ? -5 * S : 0)
                    .zIndex(hovered == i ? 2 : 0)
                    .onHover { inside in
                        withAnimation(Self.magnify) {
                            if inside { hovered = i } else if hovered == i { hovered = nil }
                        }
                    }
                    // Apparition de gauche à droite : chaque emoji glisse et se dévoile, un léger temps après le précédent.
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : -14 * S)
                    .blur(radius: appeared ? 0 : 3 * S)
                    .animation(D.smooth.delay(0.15 + Double(i) * 0.045), value: appeared)
            }
        }
        .onAppear { appeared = true }
    }
}

struct EmojiButton: View {
    let emoji: String
    let size: CGFloat
    let action: () -> Void
    private let _popBox = State<Bool>(initialValue: false)
    private var pop: Bool { get { _popBox.wrappedValue } nonmutating set { _popBox.wrappedValue = newValue } }

    var body: some View {
        Button {
            pop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { pop = false }
            action()
        } label: {
            Text(emoji)
                .font(.system(size: size))
                .fixedSize()
                .scaleEffect(pop ? 1.25 : 1)
                .blur(radius: pop ? 0.6 : 0)
                .animation(.spring(response: 0.32, dampingFraction: 0.7), value: pop)
                // Toute la case est cliquable, pas seulement le dessin de l'emoji.
                .frame(maxWidth: .infinity, minHeight: size * 1.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(pressed: 0.82, hovered: 1)) // le zoom au survol est géré par la rangée
    }
}

struct Avatar: View {
    let chat: ChatInfo?
    let size: CGFloat
    var fill: Color = D.card
    var border: CGFloat = 0

    var body: some View {
        ZStack {
            if chat?.image == nil { Circle().fill(fill) }
            if let img = chat?.image {
                // Photo déjà découpée en rond (voir RoundPhoto) : aucun pixel ne dépasse du cercle.
                Image(nsImage: RoundPhoto.make(img)).resizable().interpolation(.high)
            } else if let chat, size > 40 {
                Text(chat.initials)
                    .font(D.font(size * 0.34, 500))
                    .foregroundStyle(D.ink.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: border))
    }
}

/// Photos de profil pré-découpées en disque (remplissage centré), mises en cache.
/// Découper à l'affichage laissait passer une ligne de pixels en haut de chaque photo.
enum RoundPhoto {
    private static let cache = NSCache<NSImage, NSImage>()

    static func make(_ source: NSImage, side: CGFloat = 360) -> NSImage {
        if let hit = cache.object(forKey: source) { return hit }
        let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            let s = source.size
            let k = max(rect.width / max(s.width, 1), rect.height / max(s.height, 1))
            let w = s.width * k, h = s.height * k
            source.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h),
                        from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        cache.setObject(out, forKey: source)
        return out
    }
}

struct Grabber: View {
    @ObservedObject var c: ChatController

    var body: some View {
        let S = c.S
        Capsule().fill(.white)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            .frame(width: 58 * S, height: 6 * S)
            .frame(width: 160 * S, height: 24 * S)
            .contentShape(Rectangle())
            // Le déplacement est fait par macOS (voir ChatHostingView) : on donne juste la zone.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { c.grabberRect = $0 }
            // Barre cachée (notif compacte, changement d'écran) : sa zone ne capte plus les clics.
            .onDisappear { c.grabberRect = .zero }
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }
}

// MARK: - Conversation

struct ConversationView: View {
    @ObservedObject var c: ChatController
    @ObservedObject var recorder: VoiceRecorder
    /// Les 9 emojis choisis (fenêtre « Choisir les emojis… »).
    @ObservedObject private var emojiPrefs = EmojiPrefs.shared
    let ns: Namespace.ID
    @Namespace private var glass
    @FocusState private var focused: Bool
    private let _bottomHeightBox = State<CGFloat>(initialValue: 0)
    /// Hauteur de la zone flottante du bas (saisie + emojis + poignée).
    private var bottomHeight: CGFloat { get { _bottomHeightBox.wrappedValue } nonmutating set { _bottomHeightBox.wrappedValue = newValue } }
    private let _headerHeightBox = State<CGFloat>(initialValue: 0)
    /// Hauteur de l'en-tête flottant (retour, nom, appel).
    private var headerHeight: CGFloat { get { _headerHeightBox.wrappedValue } nonmutating set { _headerHeightBox.wrappedValue = newValue } }

    var body: some View {
        let S = c.S
        VStack(spacing: 0) {
            // (l'en-tête est posé par-dessus, voir l'overlay plus bas)
            // Le chat descend jusqu'en bas de la pilule ; la saisie, les emojis et la poignée flottent par-dessus,
            // sur un flou progressif : les messages se floutent de plus en plus en passant dessous.
            ZStack(alignment: .bottom) {
                // Notif compacte : pas de saisie, la liste épouse les messages. Dépliée : hauteur maximale.
                let inset = c.peek ? 12 * S : bottomHeight
                MessageList(c: c, maxHeight: Self.maxListHeight * S + inset + headerHeight + c.extraHeight,
                            bottomInset: inset, topInset: headerHeight)
                    .demoTarget("list")
                    .padding(.horizontal, 32 * S)

                if !c.peek {
                ProgressiveBlur()
                    .frame(height: bottomHeight + 56 * S)
                    .allowsHitTesting(false)
                    .transition(.opacity)

                VStack(spacing: 22 * S) {
                    // Pièces jointes prêtes à partir (jusqu'à 5), avec une croix pour les retirer.
                    if !c.draftFiles.isEmpty {
                        DraftFilesRow(c: c, S: S)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    GlassGroup(spacing: 16 * S) {
                        HStack(alignment: .bottom, spacing: 16 * S) {
                            if recorder.isActive {
                                RecordBar(recorder: recorder, S: S, c: c)
                                    .glassID("field", in: glass)
                                    .transition(.opacity)
                            } else {
                                input(S)
                                    .glassID("field", in: glass)
                                    .demoTarget("field")
                                    .transition(.opacity)
                                // Clic : lance l'enregistrement (arrêt, réécoute, suppression dans la barre).
                                CircleControl(glyph: .mic, S: S, color: Color(hex: 0x8E8E8E)) {
                                    withAnimation(D.island) { recorder.start() }
                                }
                                .glassID("mic", in: glass)
                                .demoTarget("mic")
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                            SendButton(S: S, dim: !canSend) { c.sendDraft() }
                                .demoTarget("send")
                        }
                    }
                    .modifier(RiseIn(distance: 30 * S))

                    EmojiRow(emojis: emojiPrefs.emojis, size: 40 * S, S: S) { c.insertEmoji($0) }
                        .padding(.horizontal, 38 * S)
                        .padding(.vertical, 2 * S)

                    Grabber(c: c)
                }
                .padding(.horizontal, 32 * S)
                .padding(.bottom, 12 * S - 9 * S) // la poignée a une zone de prise plus haute que le trait
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    dlog("zone du bas : hauteur \(Int(h))")
                    bottomHeight = h
                }
                .onAppear { dlog("zone du bas affichée (compact : \(c.peek))") }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // En-tête flottant : les messages défilent dessous, sur un flou progressif.
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                ProgressiveBlur(edge: .top)
                    .frame(height: headerHeight + 80 * S) // le flou descend bien sous l'en-tête
                    .allowsHitTesting(false)
                header(S)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            }
        }
        .animation(D.island, value: recorder.isActive)
        // Glisser-déposer des fichiers depuis le Finder.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { c.addFiles([url]) } }
                }
            }
            return true
        }
        .onChange(of: c.focusToken) { focused = c.focusToken > 0 }
        .onChange(of: focused) { dlog("champ de message : \(focused ? "actif" : "inactif") (fenêtre clé : \(c.panel?.isKeyWindow == true))") }
        .onAppear {
            dlog("conversation affichée (compact : \(c.peek), transient : \(c.transient))")
        }
    }

    private func header(_ S: CGFloat) -> some View {
        HStack(spacing: 16 * S) {
            CircleControl(glyph: .chevronLeft, S: S, glass: false) { c.openPicker() }
                .demoTarget("back")
            Text(c.chat?.name ?? "")
                .font(D.font(32 * S, 500))
                .foregroundStyle(D.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Appel FaceTime audio direct (pas pour les groupes).
            if c.chat?.isGroup == false {
                // Verre transparent comme les autres boutons ronds, icône blanche.
                CircleControl(glyph: .phone, S: S, color: .white) { c.call() }
                    .help("Appel FaceTime audio")
            }
        }
        .padding(.horizontal, 32 * S)
        .padding(.top, 32 * S)
        .padding(.bottom, 18 * S) // de l'air sous le nom et le bouton d'appel
    }

    /// Hauteur max de la liste : la maquette fait 590 de haut, dont 305 pour l'en-tête, la saisie, les emojis et la poignée.
    static let maxListHeight: CGFloat = D.tallHeight - 305

    private var canSend: Bool {
        recorder.phase == .recorded || recorder.phase == .playing || !c.draftFiles.isEmpty
            || !c.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func input(_ S: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 12 * S) {
        // Trombone : ouvre le Finder (jusqu'à 5 fichiers).
        Button { c.chooseFiles() } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 26 * S, weight: .medium))
                .foregroundStyle(D.ink.opacity(0.45))
                .frame(width: 34 * S, height: 34 * S)
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(pressed: 0.9, hovered: 1.1))
        .help("Joindre des fichiers (jusqu'à 5)")
        ZStack(alignment: .leading) {
            if c.draft.isEmpty {
                Text("Entrez votre message")
                    .font(D.font(26 * S))
                    .foregroundStyle(D.placeholder)
                    .allowsHitTesting(false)
            }
            // Le champ s'agrandit vers le haut avec le texte (jusqu'à 5 lignes). Entrée envoie, ⌥ Entrée va à la ligne.
            TextField("", text: $c.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(D.font(26 * S))
                .lineLimit(1...5)
                .foregroundStyle(D.ink)
                .focused($focused)
                .onSubmit { c.sendDraft() }
        }
        }
        .padding(.leading, 20 * S)
        .padding(.trailing, 32 * S)
        .padding(.vertical, 18 * S)
        .frame(maxWidth: .infinity)
        .frame(minHeight: D.control * S)
        .liquidGlass(RoundedRectangle(cornerRadius: D.control * S / 2, style: .continuous)) { FieldSurface(S: S) }
    }
}

struct MessageList: View {
    @ObservedObject var c: ChatController
    let maxHeight: CGFloat
    /// Hauteur du champ flottant posé sur le bas de la liste.
    var bottomInset: CGFloat = 0
    /// Hauteur de l'en-tête flottant posé sur le haut de la liste.
    var topInset: CGFloat = 0
    private let _contentHeightBox = State<CGFloat>(initialValue: 0)
    private var contentHeight: CGFloat { get { _contentHeightBox.wrappedValue } nonmutating set { _contentHeightBox.wrappedValue = newValue } }

    /// Hauteur max des messages dans une notif compacte (sous l'en-tête).
    static let peekHeight: CGFloat = 200

    var body: some View {
        let S = c.S
        let msgs = c.history
        let lastOut = msgs.lastIndex(where: \.fromMe)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8 * S) {
                    ForEach(Array(msgs.enumerated()), id: \.element.listID) { i, m in
                        let lastOfRun = i == msgs.count - 1 || msgs[i + 1].fromMe != m.fromMe
                        VStack(alignment: .trailing, spacing: 6 * S) {
                            Bubble(message: m, chat: c.chat, showAvatar: !m.fromMe && lastOfRun, S: S, compact: c.peek,
                                   onReact: m.pending ? nil : { c.react($0) },
                                   onLanded: { c.addLocalReaction($0, to: m.listID) })
                                .zIndex(1)
                            // Sous ton dernier message : Envoi… / Distribué / Lu à 14:32, comme iMessage.
                            if i == lastOut, !m.failed {
                                Text(Self.status(m))
                                    .font(D.font(17 * S, 500))
                                    .foregroundStyle(D.ink.opacity(0.4))
                                    .padding(.trailing, 8 * S)
                                    .id(Self.status(m))
                                    .transition(.opacity)
                            }
                        }
                            .id(m.listID)
                            .padding(.top, i > 0 && msgs[i - 1].fromMe != m.fromMe ? 10 * S : 0)
                            .transition(.asymmetric(
                                // Envoi (comme iMessage) : la bulle part de la zone de saisie, monte en grandissant
                                // depuis le coin bas droit. Réception : simple glissé en fondu.
                                insertion: m.pending
                                    ? .modifier(active: SendFlight(progress: 0, S: S), identity: SendFlight(progress: 1, S: S))
                                    : .scale(scale: 0.96, anchor: m.fromMe ? .bottomTrailing : .bottomLeading)
                                        .combined(with: .slideBlur(y: 10 * S, blur: 0)),
                                removal: .opacity))
                    }
                }
                .padding(.horizontal, 20 * S)
                .padding(.top, 12 * S + topInset)
                .padding(.bottom, 16 * S + bottomInset) // la dernière bulle s'arrête au-dessus du champ flottant
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    if c.isResizing { contentHeight = h } else { withAnimation(D.island) { contentHeight = h } }
                }
                // Repère tout en bas (après la marge du champ flottant) : on fait défiler jusqu'ici,
                // pas jusqu'à la bulle, sinon elle finirait cachée derrière la saisie.
                Color.clear.frame(height: 1).id(Self.end)
            }
            // La fenêtre épouse le contenu : un message reçu = une fenêtre courte, comme dans la maquette.
            // Rallongée avec le trait du bas : toute la hauteur choisie, même si la conversation est courte.
            // Notif compacte : la hauteur suit la longueur des messages, plafonnée bas (2-3 bulles,
            // les derniers messages en bas). Le survol déplie la pilule pour voir le reste.
            // Sinon : hauteur choisie avec le trait du bas, ou maximale quand la notif est dépliée.
            .frame(height: c.peek ? min(max(contentHeight, 80 * S), maxHeight, topInset + Self.peekHeight * S)
                   : ((c.extraHeight != 0 || c.unfolded) ? maxHeight : min(max(contentHeight, 80 * S), maxHeight)))
            .defaultScrollAnchor(.bottom)
            // Nouvelle liste à chaque conversation chargée : elle s'ouvre en bas, sans défilement visible.
            .id(c.historyVersion)
            .modifier(StickToBottom())
            // Fondus progressifs (courbe smoothstep, sans marche) : les bulles se dissolvent
            // doucement sous l'en-tête et au-dessus de la zone de saisie.
            .mask(VStack(spacing: 0) {
                LinearGradient(gradient: smoothGradient(.black, from: 0, to: 1, steps: 24), startPoint: .top, endPoint: .bottom)
                    .frame(height: 14 * S)
                Color.black
            })
            // Conversation ouverte : on arrive directement en bas, sans défilement visible.
            .onAppear { jump(proxy, msgs) }
            // Rallonger / raccourcir la pilule : la conversation reste calée en bas, le dernier message
            // reste juste au-dessus de la zone de saisie.
            .onChange(of: c.extraHeight) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .onChange(of: msgs.first?.id) { jump(proxy, msgs) }
            .onChange(of: msgs.last?.id) {
                // Nouveau message : la conversation remonte pour l'afficher en entier.
                withAnimation(D.smooth) { proxy.scrollTo(Self.end, anchor: .bottom) }
                // Encore une fois une fois la bulle mise en page (accusé de réception, photo, lien…).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(D.smooth) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }
}

/// Trajet de la bulle envoyée : depuis le champ de saisie (plus bas, plus petite) jusqu'à sa place.
struct SendFlight: ViewModifier {
    let progress: Double
    let S: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(0.55 + 0.45 * progress, anchor: .bottomTrailing)
            .offset(x: (1 - progress) * -40 * S, y: (1 - progress) * 110 * S)
            .opacity(min(1, 0.2 + progress * 1.6))
    }
}

/// Apparition du badge de réaction : il tourne et grossit avec un rebond (comme le prototype).
struct BadgePop: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1 : 0.01).rotationEffect(.degrees(on ? 0 : -25)).opacity(on ? 1 : 0)
    }
}

/// Trajet en arc de l'emoji de réaction : il monte un peu, file vers la bulle et rétrécit en se posant.
struct FlyArc: ViewModifier, Animatable {
    var progress: Double
    let from: CGPoint
    let to: CGPoint
    let lift: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = CGFloat(progress)
        let x = from.x + (to.x - from.x) * t
        let y = from.y + (to.y - from.y) * t - sin(.pi * t) * lift
        content
            .scaleEffect(1.45 - 0.6 * t)
            .position(x: x, y: y)
    }
}

/// Garde le bas en vue quand une photo ou un lien finit de charger (macOS 15+).
struct StickToBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}

extension MessageList {
    static func status(_ m: Message) -> String {
        if m.pending { return "Envoi…" }
        if let read = m.readAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = Calendar.current.isDateInToday(read) ? "HH:mm" : "d MMM"
            return Calendar.current.isDateInToday(read) ? "Lu à \(f.string(from: read))" : "Lu le \(f.string(from: read))"
        }
        return m.delivered ? "Distribué" : "Envoyé"
    }

    static let end = "fin-de-conversation"

    func jump(_ proxy: ScrollViewProxy, _ msgs: [Message]) {
        guard !msgs.isEmpty else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { proxy.scrollTo(Self.end, anchor: .bottom) }
        // Puis quelques recalages pendant que bulles, photos et liens finissent de se mettre en page.
        for delay in [0.0, 0.05, 0.15, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withTransaction(t) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }
}

struct Bubble: View {
    let message: Message
    let chat: ChatInfo?
    let showAvatar: Bool
    let S: CGFloat
    /// Notif compacte : texte coupé à 2 lignes, pas de cartes de liens.
    var compact = false
    /// Réaction choisie au survol (envoyée comme emoji : AppleScript ne permet pas les vrais tapbacks).
    var onReact: ((String) -> Void)? = nil
    private let _pickerBox = State<Bool>(initialValue: false)
    private var picker: Bool { get { _pickerBox.wrappedValue } nonmutating set { _pickerBox.wrappedValue = newValue } }
    private let _pressBox = State<Date?>(initialValue: nil)
    private var pressedAt: Date? { get { _pressBox.wrappedValue } nonmutating set { _pressBox.wrappedValue = newValue } }
    private let _highlightBox = State<Int?>(initialValue: nil)
    private var highlighted: Int? { get { _highlightBox.wrappedValue } nonmutating set { _highlightBox.wrappedValue = newValue } }
    private let _framesBox = State<[Int: CGRect]>(initialValue: [:])
    private var itemFrames: [Int: CGRect] { get { _framesBox.wrappedValue } nonmutating set { _framesBox.wrappedValue = newValue } }

    /// Réaction posée : l'emoji atterrit sur la bulle (affichage local).
    var onLanded: ((String) -> Void)? = nil
    private let _flyBox = State<(emoji: String, from: CGPoint)?>(initialValue: nil)
    private var fly: (emoji: String, from: CGPoint)? { get { _flyBox.wrappedValue } nonmutating set { _flyBox.wrappedValue = newValue } }
    private let _flyProgressBox = State<Double>(initialValue: 0)
    private var flyProgress: Double { get { _flyProgressBox.wrappedValue } nonmutating set { _flyProgressBox.wrappedValue = newValue } }
    private let _sizeBox = State<CGSize>(initialValue: .zero)
    private var contentSize: CGSize { get { _sizeBox.wrappedValue } nonmutating set { _sizeBox.wrappedValue = newValue } }

    static let tapbacks = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
    private var space: String { "bulle-\(message.listID)" }

    /// Coin où se pose la réaction (là où s'affiche le badge).
    private var landingPoint: CGPoint {
        CGPoint(x: message.fromMe ? 6 * S : contentSize.width - 6 * S, y: -4 * S)
    }

    /// L'emoji choisi s'envole de la barre et se pose sur le coin de la bulle, comme sur iMessage.
    private func launch(_ i: Int) {
        let emoji = Self.tapbacks[i]
        let start = itemFrames[i].map { CGPoint(x: $0.midX, y: $0.midY) } ?? landingPoint
        fly = (emoji, start)
        flyProgress = 0
        withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.45)) { flyProgress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.43) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onLanded?(emoji)
            fly = nil
        }
        onReact?(emoji)
    }

    /// Appui maintenu sur la bulle → la barre apparaît ; on glisse sur un emoji, on relâche pour réagir.
    private var reactGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                guard onReact != nil else { return }
                if pressedAt == nil {
                    let now = Date()
                    pressedAt = now
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard pressedAt == now, !picker else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { picker = true }
                    }
                }
                guard picker else { return }
                // Emoji sous le curseur (marge verticale généreuse pour glisser sans viser au pixel près).
                let hit = itemFrames.first { $0.value.insetBy(dx: -2, dy: -30).contains(v.location) }?.key
                if hit != highlighted {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { highlighted = hit }
                }
            }
            .onEnded { _ in
                pressedAt = nil
                if picker, let i = highlighted { launch(i) }
                withAnimation(.easeOut(duration: 0.18)) { picker = false; highlighted = nil }
            }
    }

    /// Un à trois emojis seuls : affichés en grand, sans bulle (comme iMessage).
    private var bigEmoji: Bool {
        let t = message.text
        return t.count <= 3 && !t.isEmpty && t.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF || $0.value == 0xFE0F || $0.value == 0x200D || (0x1F3FB...0x1F3FF).contains($0.value) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12 * S) {
            if message.fromMe { Spacer(minLength: 90 * S) } else {
                Avatar(chat: chat, size: 48 * S, fill: D.avatar)
                    .opacity(showAvatar ? 1 : 0)
            }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 6 * S) {
                ForEach(message.attachments, id: \.self) { a in
                    switch a.kind {
                    case .image: PhotoAttachment(attachment: a, S: S)
                    case .audio: VoiceAttachment(attachment: a, fromMe: message.fromMe, S: S)
                    case .video: VideoAttachment(attachment: a, S: S)
                    default: FileAttachment(attachment: a, fromMe: message.fromMe, S: S)
                    }
                }
                if bigEmoji {
                    Text(message.text).font(.system(size: 56 * S)).padding(.horizontal, 6 * S)
                } else if !message.text.isEmpty, !message.text.isOnlyLink {
                    Text(message.text)
                        .lineLimit(compact ? 2 : nil)
                        .truncationMode(.tail)
                        .font(D.font(24 * S))
                        .foregroundStyle(message.fromMe || message.failed ? Color.white.opacity(0.85) : D.ink.opacity(0.85))
                        .lineSpacing(4 * S)
                        .padding(.vertical, 25 * S)
                        .padding(.horizontal, 32 * S)
                        .background(
                            RoundedRectangle(cornerRadius: 40 * S, style: .continuous)
                                .fill(message.failed ? D.red : (message.fromMe ? D.blue : D.received))
                        )
                }
                // Cartes de liens (Apple Music, YouTube, articles…), rendu natif de Messages.
                ForEach(Array(message.text.links.prefix(compact ? 0 : 2)), id: \.self) { url in
                    LinkAttachment(url: url, S: S)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if message.failed {
                    Text("Non envoyé").font(D.font(16 * S, 500)).foregroundStyle(D.red)
                        .offset(y: 22 * S)
                }
            }
            // Réactions posées sur le message (❤️ 😂…), en badge sur le coin haut, comme iMessage.
            .overlay(alignment: message.fromMe ? .topLeading : .topTrailing) {
                if !message.reactions.isEmpty {
                    HStack(spacing: 2 * S) {
                        ForEach(Array(message.reactions.prefix(4).enumerated()), id: \.offset) { _, r in
                            Text(r.emoji).font(.system(size: 20 * S))
                        }
                    }
                    .padding(.horizontal, 9 * S)
                    .padding(.vertical, 5 * S)
                    .background(Capsule().fill(D.card).shadow(color: .black.opacity(0.12), radius: 6 * S, y: 2 * S))
                    .offset(x: (message.fromMe ? -14 : 14) * S, y: -18 * S)
                    .transition(.modifier(active: BadgePop(on: false), identity: BadgePop(on: true)))
                }
            }
            // Barre de réactions : appui maintenu sur la bulle, puis glisser jusqu'à l'emoji et relâcher.
            .overlay(alignment: message.fromMe ? .topTrailing : .topLeading) {
                if picker, onReact != nil {
                    HStack(spacing: 4 * S) {
                        ForEach(Array(Self.tapbacks.enumerated()), id: \.offset) { i, e in
                            Text(e).font(.system(size: 24 * S))
                                .frame(width: 40 * S, height: 40 * S)
                                .scaleEffect(highlighted == i ? 1.45 : 1, anchor: .bottom)
                                .offset(y: highlighted == i ? -8 * S : 0)
                                .zIndex(highlighted == i ? 1 : 0)
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(space)) }) { itemFrames[i] = $0 }
                        }
                    }
                    .padding(.horizontal, 8 * S)
                    .padding(.vertical, 4 * S)
                    // Fond plein et opaque (bien lisible au-dessus des messages).
                    .background(Capsule().fill(D.card).shadow(color: .black.opacity(0.18), radius: 10 * S, y: 3 * S))
                    .offset(y: -50 * S)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.8, anchor: message.fromMe ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
                }
            }
            // Emoji en vol vers le coin de la bulle.
            .overlay(alignment: .topLeading) {
                if let fly {
                    Text(fly.emoji)
                        .font(.system(size: 24 * S))
                        .modifier(FlyArc(progress: flyProgress, from: fly.from, to: landingPoint, lift: 34 * S))
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0 }
            .coordinateSpace(name: space)
            .simultaneousGesture(reactGesture)
            if !message.fromMe { Spacer(minLength: 90 * S) }
        }
        .padding(.top, message.reactions.isEmpty ? 0 : 16 * S)
        .padding(.bottom, message.failed ? 22 * S : 0)
    }
}

// MARK: - Barre d'enregistrement vocal

/// Pilule d'enregistrement (inspirée du prototype web) : poubelle à gauche, onde en direct au centre,
/// minuteur ou lecture à droite. Glisser à gauche en tenant : la pilule passe au rouge, relâcher supprime.
struct RecordBar: View {
    @ObservedObject var recorder: VoiceRecorder
    let S: CGFloat
    @ObservedObject var c: ChatController

    static let dangerFill = Color(hex: 0xFFDBD5)
    static let dangerInk = Color(hex: 0xC70000)

    var body: some View {
        let danger = c.holdRecording && c.cancelArmed
        let shape = RoundedRectangle(cornerRadius: D.control * S / 2, style: .continuous)
        HStack(spacing: 16 * S) {
            Button { withAnimation(D.island) { recorder.discard() } } label: {
                GlyphView(glyph: .trash, size: 31 * S, color: danger ? Self.dangerInk : D.red)
                    .scaleEffect(danger ? 1.18 : 1)
                    // Petit tremblement quand la suppression s'arme.
                    .keyframeAnimator(initialValue: 0.0, trigger: danger) { content, angle in
                        content.rotationEffect(.degrees(angle))
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(danger ? -12 : 0, duration: 0.1)
                            LinearKeyframe(danger ? 10 : 0, duration: 0.1)
                            LinearKeyframe(danger ? -6 : 0, duration: 0.1)
                            LinearKeyframe(0, duration: 0.1)
                        }
                    }
                    .frame(width: 32 * S, height: 32 * S)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Bouncy(pressed: 0.88, hovered: 1.12))
            .transition(.modifier(active: SlideBlur(x: 40 * S, blur: 4, opacity: 0), identity: SlideBlur(x: 0, blur: 0, opacity: 1)))

            Waveform(levels: recorder.levels, progress: recorder.progress, playing: recorder.phase == .playing, S: S,
                     color: danger ? Self.dangerInk : D.red)
                .frame(maxWidth: .infinity)
                // L'onde défile de droite à gauche et s'efface sur le bord gauche.
                .mask(LinearGradient(gradient: smoothGradient(.black, from: 0, to: 1, steps: 16),
                                     startPoint: .leading, endPoint: UnitPoint(x: 0.18, y: 0.5)))
                .opacity(danger ? 0.35 : 1)

            if c.holdRecording {
                Text(Self.clock(recorder.elapsed))
                    .font(D.font(20 * S, 600)).monospacedDigit()
                    .foregroundStyle(danger ? Self.dangerInk : D.ink.opacity(0.6))
                    .frame(minWidth: 52 * S, alignment: .trailing)
            } else {
                Button {
                    if recorder.phase == .recording { recorder.stop() } else { recorder.togglePlay() }
                } label: {
                    ZStack {
                        switch recorder.phase {
                        case .recording:
                            RoundedRectangle(cornerRadius: 4 * S).fill(D.red).frame(width: 18 * S, height: 18 * S)
                                .modifier(Pulse())
                        case .playing:
                            HStack(spacing: 5 * S) {
                                RoundedRectangle(cornerRadius: 2 * S).frame(width: 6 * S, height: 20 * S)
                                RoundedRectangle(cornerRadius: 2 * S).frame(width: 6 * S, height: 20 * S)
                            }
                            .foregroundStyle(D.red)
                        default:
                            GlyphView(glyph: .play, size: 29 * S, color: D.red)
                        }
                    }
                    .frame(width: 32 * S, height: 32 * S)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Bouncy(pressed: 0.88, hovered: 1.12))
                .demoTarget("stop")
                .transition(.modifier(active: SlideBlur(x: -40 * S, blur: 4, opacity: 0), identity: SlideBlur(x: 0, blur: 0, opacity: 1)))
            }
        }
        .padding(.horizontal, 22 * S)
        .frame(maxWidth: .infinity)
        .frame(height: D.control * S)
        // La couleur de suppression remplit la pilule depuis la droite en suivant le glissé vers la gauche.
        .background(
            GeometryReader { g in
                let progress = min(1, max(0, -c.holdDrag) / (80 * S))
                Rectangle()
                    .fill(LinearGradient(colors: [Self.dangerFill, Self.dangerFill.opacity(danger ? 1 : 0.85)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * progress)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(c.holdRecording ? 1 : 0)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.85), value: progress)
            }
            .clipShape(shape)
        )
        .liquidGlass(shape) { FieldSurface(S: S) }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: danger)
        // Petit rebond vertical à l'apparition (comme le prototype : 1 → 0,93 → 1,015 → 1).
        .keyframeAnimator(initialValue: 1.0, trigger: c.holdRecording) { content, sy in
            content.scaleEffect(x: 1, y: sy)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.93, duration: 0.15)
                CubicKeyframe(1.015, duration: 0.2)
                CubicKeyframe(1.0, duration: 0.15)
            }
        }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Pulse: ViewModifier {
    private let _onBox = State<Bool>(initialValue: false)
    private var on: Bool { get { _onBox.wrappedValue } nonmutating set { _onBox.wrappedValue = newValue } }
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.55 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

struct Waveform: View {
    let levels: [CGFloat]
    let progress: Double
    let playing: Bool
    let S: CGFloat
    var color: Color = D.red

    var body: some View {
        GeometryReader { g in
            let n = levels.count
            let barW = max(2 * S, 1)
            let gap = n > 1 ? (g.size.width - CGFloat(n) * barW) / CGFloat(n - 1) : 0
            HStack(alignment: .center, spacing: max(gap, 1)) {
                ForEach(0..<n, id: \.self) { i in
                    let played = !playing || Double(i) / Double(n) <= progress
                    Capsule()
                        .fill(color.opacity(played ? 1 : 0.3))
                        .frame(width: barW, height: max(4 * S, 23 * S * levels[i]))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .animation(.easeOut(duration: 0.1), value: levels)
        }
        .frame(height: 29 * S)
    }
}

// MARK: - Cercles des derniers échanges

struct PickerView: View {
    @ObservedObject var c: ChatController
    @ObservedObject var store: MessagesStore
    let ns: Namespace.ID
    @FocusState private var focused: Bool
    private let _searchHeightBox = State<CGFloat>(initialValue: 0)
    /// Hauteur de la zone de recherche flottante (champ + poignée).
    private var searchHeight: CGFloat { get { _searchHeightBox.wrappedValue } nonmutating set { _searchHeightBox.wrappedValue = newValue } }

    var body: some View {
        let S = c.S
        let results = c.results
        // Comme dans la conversation : la grille défile sous la recherche, sur le même flou progressif.
        ZStack(alignment: .bottom) {
            // Toutes les conversations, en grille de 3, à faire défiler. La recherche filtre la grille.
            ScrollView(.vertical, showsIndicators: false) {
                // Espace vertical généreux : la bulle d'aperçu d'une photo ne touche pas le prénom au-dessus.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20 * S, alignment: .top), count: 3),
                          spacing: 40 * S) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, chat in
                        ContactDisc(chat: chat, preview: store.previews[chat.id], S: S) { c.open($0) }
                            .zIndex(Double(1000 - i)) // la bulle d'aperçu passe au-dessus du cercle voisin
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.horizontal, 48 * S)
                .padding(.top, 40 * S)
                .padding(.bottom, 20 * S + searchHeight)
            }
            .overlay {
                if results.isEmpty {
                    Text(c.query.isEmpty ? "Aucune conversation" : "Personne ne s'appelle « \(c.query) »")
                        .font(D.font(22 * S)).foregroundStyle(D.ink.opacity(0.4))
                }
            }
            // Fondu doux en haut de la grille.
            .mask(VStack(spacing: 0) {
                LinearGradient(gradient: smoothGradient(.black, from: 0, to: 1, steps: 24), startPoint: .top, endPoint: .bottom)
                    .frame(height: 28 * S)
                Color.black
            })
            .frame(maxHeight: .infinity)

            ProgressiveBlur()
                .frame(height: searchHeight + 56 * S)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
            HStack(spacing: 16 * S) {
                ZStack(alignment: .leading) {
                    if c.query.isEmpty {
                        Text("Rechercher")
                            .font(D.font(24 * S))
                            .foregroundStyle(D.placeholder)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $c.query)
                        .textFieldStyle(.plain)
                        .font(D.font(24 * S))
                        .foregroundStyle(D.ink)
                        .focused($focused)
                        .onSubmit { c.openFirstResult() }
                }
                .padding(.horizontal, 32 * S)
                .frame(maxWidth: .infinity)
                .frame(height: D.control * S)
                .liquidGlass(RoundedRectangle(cornerRadius: D.control * S / 2, style: .continuous)) { FieldSurface(S: S) }

                BlueButton(title: "Rechercher", S: S, dim: results.isEmpty) { c.openFirstResult() }
            }
            .modifier(RiseIn(distance: 30 * S))
            .padding(.horizontal, 48 * S)
            .padding(.top, 14 * S)
            Grabber(c: c).padding(.top, 22 * S - 9 * S)
            }
            .padding(.bottom, 12 * S - 9 * S)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { searchHeight = $0 }
        }
        // La barre du bas rallonge / raccourcit aussi l'accueil (même hauteur choisie que la conversation).
        .frame(height: D.tallHeight * S + c.extraHeight)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: results.map(\.id))
        .onChange(of: c.focusToken) { focused = c.focusToken > 0 }
    }

}

struct ContactDisc: View {
    let chat: ChatInfo?
    let preview: ChatPreview?
    let S: CGFloat
    let action: (ChatInfo) -> Void
    private let _hoveringBox = State<Bool>(initialValue: false)
    private var hovering: Bool { get { _hoveringBox.wrappedValue } nonmutating set { _hoveringBox.wrappedValue = newValue } }

    static let size: CGFloat = 146

    private var firstName: String {
        guard let name = chat?.name else { return " " }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    var body: some View {
        let size = Self.size * S
        Button {
            dlog(String(format: "cercle cliqué (%@)", chat?.name ?? "vide"))
            if let chat { action(chat) }
        } label: {
            VStack(spacing: 8 * S) {
                ZStack {
                    // Disque gris seulement sans photo : sinon son bord dépasse en liseré autour de l'image.
                    if chat?.image == nil { Circle().fill(D.disc) }
                    if let chat {
                        Avatar(chat: chat, size: size, fill: chat.image == nil ? D.disc : .clear)
                            .id(chat.id)
                            .transition(.opacity)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .demoTarget("disc-\(firstName)")
                .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: 27 * S, y: hovering ? 4 * S : 0)
                // Bulle d'aperçu : même largeur que la photo, posée en haut, à cheval sur son bord.
                .overlay(alignment: .top) {
                    if let preview, preview.received {
                        PreviewBubble(preview: preview, S: S, width: size)
                            .offset(y: -14 * S)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    }
                }

                Text(firstName)
                    .font(D.font(27 * S, 500))
                    .foregroundStyle(D.ink.opacity(chat == nil ? 0 : 0.72))
                    .lineLimit(1)
                    .frame(width: size + 30 * S)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(pressed: 0.95, hovered: chat == nil ? 1 : 1.07))
        .disabled(chat == nil)
        .onHover { hovering = $0 && chat != nil }
        .animation(D.hover, value: hovering)
        .animation(.easeOut(duration: 0.25), value: preview)
    }
}

/// Petite bulle sur le cercle : extrait du dernier message reçu, point bleu s'il n'est pas lu.
struct PreviewBubble: View {
    let preview: ChatPreview
    let S: CGFloat
    /// Largeur fixe : celle de la photo. Le texte trop long est coupé avec « … ».
    let width: CGFloat

    var body: some View {
        HStack(spacing: 9 * S) {
            if preview.unread {
                Circle().fill(D.blue).frame(width: 14 * S, height: 14 * S)
            }
            Text(preview.excerpt)
                .font(D.font(22 * S, preview.unread ? 600 : 500))
                .foregroundStyle(D.ink.opacity(preview.unread ? 0.9 : 0.65))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16 * S)
        .padding(.vertical, 10 * S)
        .frame(width: width)
        .background(
            Capsule().fill(D.card)
                .shadow(color: .black.opacity(0.1), radius: 10 * S, y: 3 * S)
        )
    }
}

// MARK: - Premier lancement : accès complet au disque

struct SetupView: View {
    @ObservedObject var c: ChatController
    let ns: Namespace.ID

    var body: some View {
        let S = c.S
        VStack(spacing: 16 * S) {
            HStack(spacing: 16 * S) {
                ZStack {
                    Circle().fill(D.card)
                    Image(systemName: "lock.fill").font(.system(size: 40 * S, weight: .medium)).foregroundStyle(D.ink.opacity(0.3))
                }
                .frame(width: 111 * S, height: 111 * S)
                VStack(alignment: .leading, spacing: 8 * S) {
                    Text("Accès à tes messages").font(D.font(40 * S, 500)).foregroundStyle(D.ink)
                    Text("Autorise PillChat dans « Accès complet au disque », puis reviens ici.")
                        .font(D.font(28 * S)).foregroundStyle(D.ink.opacity(0.77))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(32 * S)
            .background(Surface(radius: D.pillRadius * S, S: S).matchedGeometryEffect(id: "surface", in: ns))

            HStack(spacing: 16 * S) {
                Spacer()
                Button { c.hide() } label: {
                    Text("Plus tard").font(D.font(24 * S)).foregroundStyle(D.ink.opacity(0.5))
                        .padding(.horizontal, 32 * S).frame(height: D.control * S)
                        .background(Surface(radius: D.control * S / 2, S: S))
                }
                .buttonStyle(Bouncy())
                BlueButton(title: "Ouvrir les réglages", S: S, dim: false) {
                    // Lien des Réglages récents, puis l'ancien en secours ; on montre aussi l'app à glisser.
                    let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
                    if !urls.contains(where: { NSWorkspace.shared.open(URL(string: $0)!) }) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .shadow(color: .black.opacity(0.1), radius: 20 * S, y: 8 * S)
            }
        }
    }
}

/// Fond de la pilule : verre de macOS 26 si demandé (vidéos de l'article), sinon le fond flouté habituel.
struct PillBackground: ViewModifier {
    let S: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: D.panelRadius * S, style: .continuous)
        if D.glassPill, #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(Surface(radius: D.panelRadius * S, S: S, translucent: true))
        }
    }
}
