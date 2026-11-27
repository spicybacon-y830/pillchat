import AppKit
import AVFoundation
import SwiftUI

// MARK: - Mode démo (vidéos de l'article)
//
// PillChat --demo <scène> <fond d'écran.jpg> <taille %> <x %> <y %> <sombre 0|1>
// Affiche la vraie pilule (vues SwiftUI de l'app, vrai Liquid Glass) avec des données inventées,
// au-dessus d'un faux coin d'écran (fond d'écran, barre des menus, fenêtre en skeleton), et la fait
// jouer toute seule avec un curseur simulé. Rien n'est lu dans Messages, rien n'est envoyé :
// on ne passe jamais par les actions du contrôleur qui touchent la base ou l'envoi.
// La zone filmée fait Demo.region (points, origine en haut à gauche de l'écran principal).

enum Demo {
    static var active = false
    /// Cadres des éléments visés par le curseur (coordonnées de la fenêtre de la pilule).
    static var targets: [String: CGRect] = [:]

    static let region = CGRect(x: 120, y: 120, width: 690, height: 525)
    static let zoom: CGFloat = 1.5 // gros plan : la barre des menus et la fenêtre à 150 %
    static let S: CGFloat = 0.69
    static let pillRight: CGFloat = 690 - 18
    static let pillTop: CGFloat = 52

    @MainActor static func run(args: [String]) {
        active = true
        D.glassPill = true
        let scene = args.count > 2 ? args[2] : "hero"
        let wallpaper = args.count > 3 ? NSImage(contentsOfFile: args[3]) : nil
        let num = { (i: Int, d: CGFloat) in args.count > i ? CGFloat(Double(args[i]) ?? Double(d)) : d }
        let wp = (size: num(4, 200), x: num(5, 50), y: num(6, 50))
        let dark = args.count > 7 && args[7] == "1"

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
            for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }

        let stage = DemoStage(scene: scene, wallpaper: wallpaper, wp: wp, dark: dark)
        stage.setUp()
        Task { @MainActor in
            await stage.play()
            // On reste affiché : c'est l'enregistrement qui arrête la démo (sinon la vidéo montrerait le vrai bureau).
            try? await Task.sleep(for: .seconds(60))
            exit(0)
        }
        app.run()
    }

    /// Rectangle (points, origine en haut à gauche de l'écran) → cadre de fenêtre AppKit.
    static func windowFrame(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 900
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

/// Repère un élément pour le curseur de la démo (sans effet hors démo).
struct DemoTarget: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        if Demo.active {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { Demo.targets[id] = $0 }
        } else {
            content
        }
    }
}

extension View {
    func demoTarget(_ id: String) -> some View { modifier(DemoTarget(id: id)) }
}

// MARK: - Curseur simulé

final class DemoCursor: ObservableObject {
    @Published var pos = CGPoint(x: 160, y: 380)
    @Published var pressed = false
    @Published var ibeam = false
    @Published var visible = true
}

struct DemoCursorView: View {
    @ObservedObject var cursor: DemoCursor
    var body: some View {
        let cur = cursor.ibeam ? NSCursor.iBeam : NSCursor.arrow
        let img = cur.image
        ZStack(alignment: .topLeading) {
            Color.clear
            Image(nsImage: img)
                .scaleEffect(cursor.pressed ? 0.86 : 1, anchor: UnitPoint(x: cur.hotSpot.x / img.size.width, y: cur.hotSpot.y / img.size.height))
                .offset(x: cursor.pos.x - cur.hotSpot.x, y: cursor.pos.y - cur.hotSpot.y)
                .opacity(cursor.visible ? 1 : 0)
        }
        .frame(width: Demo.region.width, height: Demo.region.height)
    }
}

// MARK: - Faux coin d'écran

struct DemoBackdrop: View {
    let wallpaper: NSImage?
    let wp: (size: CGFloat, x: CGFloat, y: CGFloat)
    let dark: Bool

    var body: some View {
        let Z = Demo.zoom, W = Demo.region.width, H = Demo.region.height
        ZStack(alignment: .topLeading) {
            Color.black
            if let wallpaper {
                let iw = W * wp.size / 100, ih = iw * wallpaper.size.height / wallpaper.size.width
                Image(nsImage: wallpaper).resizable().frame(width: iw, height: ih)
                    .offset(x: (W - iw) * wp.x / 100, y: (H - ih) * wp.y / 100)
            }
            window(Z)
                .offset(x: W - 200 * Z - 900 * Z, y: 42 * Z)
            menubar(Z)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .clipped()
    }

    private func menubar(_ Z: CGFloat) -> some View {
        HStack(spacing: 17 * Z) {
            Spacer()
            Image(systemName: "battery.100percent").font(.system(size: 15 * Z))
            Image(systemName: "wifi").font(.system(size: 13 * Z, weight: .semibold))
            Image(systemName: "magnifyingglass").font(.system(size: 13 * Z, weight: .semibold))
            Image(systemName: "switch.2").font(.system(size: 13 * Z, weight: .semibold))
            Text("Fri 27 Nov  9:41").font(.system(size: 13 * Z, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12 * Z)
        .frame(width: Demo.region.width, height: 24 * Z)
        .background(.black.opacity(0.12))
    }

    private func window(_ Z: CGFloat) -> some View {
        let ink = dark ? Color.white : Color.black
        let bar = { (w: CGFloat, h: CGFloat, o: Double) in
            RoundedRectangle(cornerRadius: h / 2 * Z).fill(ink.opacity(o)).frame(width: w * Z, height: h * Z)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 18 * Z) {
                RoundedRectangle(cornerRadius: 9 * Z).fill(ink.opacity(0.06)).frame(height: 30 * Z)
                ForEach(["square.and.arrow.up", "plus", "square.on.square"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 15 * Z)).foregroundStyle(ink.opacity(0.5))
                }
            }
            .padding(.trailing, 18 * Z)
            .frame(height: 52 * Z)
            .background(dark ? Color(white: 0.17) : Color(white: 0.96))
            .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.08)).frame(height: 1) }
            HStack(alignment: .top, spacing: 26 * Z) {
                VStack(alignment: .trailing, spacing: 11 * Z) {
                    bar(380, 16, 0.14).padding(.bottom, 6 * Z)
                    bar(600, 8, 0.085); bar(560, 8, 0.085); bar(620, 8, 0.085); bar(400, 8, 0.085)
                    RoundedRectangle(cornerRadius: 12 * Z).fill(ink.opacity(0.055)).frame(height: 150 * Z).padding(.vertical, 6 * Z)
                    bar(590, 8, 0.085); bar(540, 8, 0.085); bar(610, 8, 0.085); bar(460, 8, 0.085)
                }
                VStack(alignment: .leading, spacing: 14 * Z) {
                    bar(90, 8, 0.085)
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12 * Z).fill(ink.opacity(0.05)).frame(width: 150 * Z, height: 92 * Z)
                    }
                }
            }
            .padding(.top, 30 * Z)
            .padding(.trailing, 34 * Z)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 900 * Z, height: 700 * Z)
        .background(dark ? Color(white: 0.12) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 12 * Z, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }
}

// MARK: - Mise en scène

@MainActor
final class DemoStage {
    let scene: String
    let wallpaper: NSImage?
    let wp: (size: CGFloat, x: CGFloat, y: CGFloat)
    let dark: Bool

    let store = MessagesStore()
    let recorder = VoiceRecorder()
    lazy var c = ChatController(store: store, recorder: recorder, scale: Demo.S)
    let cursor = DemoCursor()
    var windows: [NSWindow] = []
    var pillOrigin = CGPoint.zero // coin haut gauche de la fenêtre de la pilule, dans la zone filmée

    init(scene: String, wallpaper: NSImage?, wp: (size: CGFloat, x: CGFloat, y: CGFloat), dark: Bool) {
        self.scene = scene; self.wallpaper = wallpaper; self.wp = wp; self.dark = dark
    }

    // Contacts et messages inventés ; « photos » : dégradés peints, aucun visage.
    lazy var nora = chat(1, "Nora", photo: [0xFF7A2F, 0xC2185B, 0xFFD678, 0x7828A0])
    lazy var sam = chat(2, "Sam", photo: nil)
    lazy var jules = chat(3, "Jules", photo: [0x1D4FD8, 0x22C1C3, 0xAAF0FF, 0x141E78])
    lazy var maya = chat(4, "Maya", photo: nil)
    lazy var theo = chat(5, "Théo", photo: [0x0F9B6C, 0xCDDC39, 0xFAFFAA, 0x00505A])
    lazy var ines = chat(6, "Inès", photo: [0x7B2FF7, 0xF107A3, 0xFFAADC, 0x3C148C])

    private func chat(_ id: Int64, _ name: String, photo: [UInt32]?) -> ChatInfo {
        ChatInfo(id: 900_000 + id, guid: "demo;-;\(id)", name: name, handles: ["+3360000000\(id)"], isGroup: false,
                 image: photo.map(Self.paint))
    }

    private var nextID: Int64 = 1
    private func msg(_ text: String, me: Bool = false, in chat: ChatInfo, voice: String? = nil) -> Message {
        nextID += 1
        var m = Message(id: nextID, text: text, fromMe: me, date: .now, handle: nil, chatID: chat.id)
        if let voice { m.attachments = [Attachment(path: voice, mime: "audio/x-caf", name: "vocal.caf")] }
        return m
    }

    static func paint(_ c: [UInt32]) -> NSImage {
        let size = 240
        let rgb = { (h: UInt32, a: CGFloat) in
            CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
        }
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let space = CGColorSpaceCreateDeviceRGB()
        let lin = CGGradient(colorsSpace: space, colors: [rgb(c[0], 1), rgb(c[1], 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(lin, start: CGPoint(x: 0, y: 240), end: CGPoint(x: 240, y: 0), options: [])
        for (p, r, col) in [(CGPoint(x: 150, y: 148), 120.0, rgb(c[2], 0.95)), (CGPoint(x: 70, y: 50), 110.0, rgb(c[3], 0.7))] {
            let g = CGGradient(colorsSpace: space, colors: [col, col.copy(alpha: 0)!] as CFArray, locations: nil)!
            ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
        }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: size, height: size))
    }

    // MARK: Fenêtres

    func setUp() {
        c.extraHeight = 0
        store.demoLoad([nora, sam, jules, maya, theo, ines], previews: [
            nora.id: ChatPreview(excerpt: "Tu passes à quelle heure ce soir ?", received: true, unread: false),
            jules.id: ChatPreview(excerpt: "Trop bien 😂", received: true, unread: true),
        ])
        let R = Demo.region

        let back = NSWindow(contentRect: Demo.windowFrame(R), styleMask: .borderless, backing: .buffered, defer: false)
        back.level = .floating
        back.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        back.ignoresMouseEvents = true
        back.contentView = NSHostingView(rootView: DemoBackdrop(wallpaper: wallpaper, wp: wp, dark: dark))
        back.orderFrontRegardless()

        let S = Demo.S
        let pw = D.width * S + RootView.margin * 2, ph = D.tallHeight * S + RootView.margin * 2 + 60
        pillOrigin = CGPoint(x: Demo.pillRight + RootView.margin - pw, y: Demo.pillTop - RootView.margin)
        let panel = ChatPanel()
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.setFrame(Demo.windowFrame(CGRect(x: R.minX + pillOrigin.x, y: R.minY + pillOrigin.y, width: pw, height: ph)), display: false)
        let host = NSHostingView(rootView: RootView(c: c, store: store, recorder: recorder))
        host.sizingOptions = []
        panel.contentView = host
        c.panel = panel
        panel.orderFrontRegardless()

        let top = NSWindow(contentRect: Demo.windowFrame(R), styleMask: .borderless, backing: .buffered, defer: false)
        top.level = .floating
        top.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        top.isOpaque = false
        top.backgroundColor = .clear
        top.ignoresMouseEvents = true
        top.contentView = NSHostingView(rootView: DemoCursorView(cursor: cursor))
        top.orderFrontRegardless()
        // L'ordre des fenêtres au même niveau : fond, pilule, curseur.
        panel.order(.above, relativeTo: back.windowNumber)
        top.order(.above, relativeTo: panel.windowNumber)
        windows = [back, panel, top]
    }

    // MARK: Gestes

    func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    func point(_ id: String, _ fx: CGFloat = 0.5, _ fy: CGFloat = 0.5) -> CGPoint {
        guard let r = Demo.targets[id] else { dlog("démo : cible \(id) introuvable"); return cursor.pos }
        return CGPoint(x: pillOrigin.x + r.minX + r.width * fx, y: pillOrigin.y + r.minY + r.height * fy)
    }

    func move(to p: CGPoint, _ d: Double? = nil) async {
        let dist = hypot(p.x - cursor.pos.x, p.y - cursor.pos.y)
        let t = d ?? min(1.0, max(0.45, Double(dist) / 450))
        withAnimation(.timingCurve(0.45, 0, 0.1, 1, duration: t)) { cursor.pos = p }
        await sleep(t)
    }

    func click() async {
        withAnimation(.easeOut(duration: 0.08)) { cursor.pressed = true }
        await sleep(0.13)
        withAnimation(.easeOut(duration: 0.12)) { cursor.pressed = false }
        await sleep(0.06)
    }

    func type(_ text: String) async {
        for ch in text {
            c.draft.append(ch)
            await sleep(ch == " " ? 0.13 : 0.07)
        }
    }

    func send(_ m: Message) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.74)) { c.history.append(m) }
    }

    func appear() { withAnimation(D.appear) { c.shown = true } }
    func disappear() { withAnimation(.easeIn(duration: 0.22)) { c.shown = false } }

    // MARK: Scènes

    func play() async {
        await sleep(2.0) // le temps de lancer l'enregistrement
        switch scene {
        case "still": await still()
        case "emoji": await emoji()
        case "voice": await voice()
        default: await hero()
        }
        await sleep(0.4)
    }

    /// La notif arrive, s'ouvre au survol, retour à l'accueil, une autre conversation.
    func hero() async {
        c.chat = nora
        c.history = [msg("Coucou !", in: nora), msg("Tu passes à quelle heure ce soir ?", in: nora)]
        c.mode = .conversation; c.transient = true; c.peek = true
        cursor.pos = CGPoint(x: 150, y: 380)
        await sleep(0.6)
        appear()                                                   // la notif arrive, compacte
        await sleep(1.9)
        await move(to: point("list", 0.5, 0.6))                    // survol : toute la pilule s'ouvre
        withAnimation(D.island) { c.peek = false; c.transient = false }
        await sleep(1.6)
        await move(to: point("back"), 0.7)                         // retour à l'accueil
        await click()
        withAnimation(D.island) { c.mode = .picker }
        await sleep(1.3)
        await move(to: point("disc-Jules", 0.5, 0.62), 0.8)        // on choisit une conversation
        await sleep(0.35)
        await click()
        withAnimation(D.island) {
            c.chat = jules
            c.history = [msg("Regarde la vidéo que je t’ai envoyée", me: true, in: jules), msg("Trop bien 😂", in: jules)]
            c.mode = .conversation; c.peek = false
        }
        await sleep(2.8)
        await move(to: CGPoint(x: 150, y: 400), 0.9)               // la souris s'en va : elle se replie et part
        await sleep(0.3)
        withAnimation(D.island) { c.peek = true }
        await sleep(0.9)
        disappear()
        await sleep(0.6)
    }

    /// Image fixe : la conversation ouverte.
    func still() async {
        cursor.visible = false
        c.chat = nora
        c.history = [msg("Tu passes à quelle heure ce soir ?", in: nora), msg("J’arrive vers 20h 🍰", me: true, in: nora)]
        c.mode = .conversation; c.peek = false
        appear()
        await sleep(3)
    }

    /// Un message tapé, deux emojis ajoutés au texte, envoyé.
    func emoji() async {
        c.chat = nora
        c.history = [msg("Ce soir chez moi ?", in: nora), msg("Tu ramènes quoi ?", in: nora)]
        c.mode = .conversation; c.peek = false
        cursor.pos = CGPoint(x: 120, y: 430)
        await sleep(0.3)
        appear()
        await sleep(1.2)
        await move(to: point("field", 0.4, 0.5))
        cursor.ibeam = true
        await click()
        await sleep(0.3)
        await type("Des chips ")
        cursor.ibeam = false
        let emojis = EmojiPrefs.shared.emojis
        var text = "Des chips "
        for i in [1, 4] {
            await move(to: point("emoji\(i)", 0.5, 0.55), 0.65)
            await sleep(0.25)
            await click()
            text += emojis[i]
            c.draft = text                                         // dans le champ, pas envoyé
            await sleep(0.45)
        }
        await sleep(0.4)
        await move(to: point("send"), 0.6)
        await click()
        dlog("démo : envoi de « \(text) » (brouillon : « \(c.draft) »)")
        c.draft = ""
        send(msg(text, me: true, in: nora))
        await sleep(2.8)
        await move(to: CGPoint(x: 120, y: 440), 0.9)
        await sleep(0.4)
        disappear()
        await sleep(0.6)
    }

    /// Un vocal : micro, arrêt, envoi.
    func voice() async {
        let file = Self.makeVoiceFile()
        c.chat = maya
        c.history = [msg("Tu me racontes ?", in: maya)]
        c.mode = .conversation; c.peek = false
        cursor.pos = CGPoint(x: 120, y: 430)
        await sleep(0.3)
        appear()
        await sleep(1.2)
        await move(to: point("mic"))
        await click()
        var levels = Array(repeating: CGFloat(0.12), count: VoiceRecorder.barCount)
        withAnimation(D.island) { recorder.setPreview(phase: .recording, levels: levels) }
        var t = 0.0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                t += 1
                levels.removeFirst()
                levels.append(0.2 + 0.8 * abs(sin(t * 0.9) * cos(t * 0.37)))
                self.recorder.setPreview(phase: .recording, levels: levels)
            }
        }
        await sleep(0.5)
        await move(to: point("stop"), 0.8)
        await sleep(2.4)
        await click()
        timer.invalidate()
        recorder.setPreview(phase: .recorded, levels: levels)       // arrêté : on peut réécouter
        await sleep(0.9)
        await move(to: point("send"), 0.5)
        await click()
        withAnimation(D.island) { recorder.setPreview(phase: .idle, levels: levels) }
        send(msg("", me: true, in: maya, voice: file))              // le vocal part
        await sleep(3)
        await move(to: CGPoint(x: 120, y: 440), 0.9)
        await sleep(0.4)
        disappear()
        await sleep(0.6)
    }

    /// Un petit son de 4 s (voix imitée) pour que le vocal ait une vraie forme d'onde et une durée.
    static func makeVoiceFile() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pillchat-demo-voice.caf")
        try? FileManager.default.removeItem(at: url)
        let rate = 22050.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * 4.2)) else { return url.path }
        buf.frameLength = buf.frameCapacity
        let d = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) {
            let s = Double(i) / rate
            let env = abs(sin(s * 2.1) * sin(s * 5.3 + 1)) * (0.4 + 0.6 * abs(sin(s * 0.8)))
            d[i] = Float(env * sin(2 * .pi * 180 * s) * 0.6)
        }
        try? file.write(from: buf)
        return url.path
    }
}
