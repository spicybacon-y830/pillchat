import AppKit
import SwiftUI

/// Rendu des écrans avec des données fictives, pour comparer au fichier Paper sans toucher à Messages.
enum Preview {
    @MainActor static func render(to url: URL) {
        let alex = ChatInfo(id: 1, guid: "iMessage;-;+33600000000", name: "Alex Martin", handles: ["+33600000000"],
                            isGroup: false, image: nil)
        let msgs = [
            Message(id: 1, text: "Tu fais quoi ce soir ?", fromMe: true, date: .now, handle: nil, chatID: 1),
            Message(id: 2, text: "Je me tate à lancer Past Lives", fromMe: false, date: .now, handle: nil, chatID: 1),
            Message(id: 3, text: "Je me tate à lancer Past Lives", fromMe: false, date: .now, handle: nil, chatID: 1),
        ]
        let store = MessagesStore()
        var images: [CGImage] = []

        func shot(_ setup: (ChatController, VoiceRecorder) -> Void) {
            let rec = VoiceRecorder()
            let c = ChatController(store: store, recorder: rec, scale: 0.56)
            c.shown = true
            c.chat = alex
            c.history = msgs
            setup(c, rec)
            let view = RootView(c: c, store: store, recorder: rec)
                .frame(width: D.width * 0.56 + RootView.margin * 2, height: D.tallHeight * 0.56 + RootView.margin * 2)
                .background(Color(white: 0.55))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.cgImage { images.append(img) }
        }

        shot { c, _ in c.mode = .conversation; c.transient = true; c.history = [msgs[2]] }
        shot { c, _ in c.mode = .conversation }
        shot { c, r in c.mode = .conversation; r.previewRecording() }
        shot { c, _ in c.mode = .picker }

        // Les bulles seules (la zone défilante ne se dessine pas hors écran).
        let bubbles = VStack(alignment: .leading, spacing: 8 * 0.56) {
            ForEach(Array((msgs + [Message(id: 4, text: "Grave, vas-y 🍿", fromMe: true, date: .now, handle: nil, chatID: 1, pending: true),
                                   Message(id: 5, text: "🤘🏿", fromMe: true, date: .now, handle: nil, chatID: 1)]).enumerated()), id: \.offset) { i, m in
                Bubble(message: m, chat: alex, showAvatar: i == 2, S: 0.56)
            }
        }
        .padding(30).frame(width: 420).background(D.bg)
        let r = ImageRenderer(content: bubbles)
        r.scale = 2
        if let img = r.cgImage { images.append(img) }

        let w = images.map(\.width).reduce(0, +), h = images.map(\.height).max() ?? 1
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        var x = 0
        for img in images {
            ctx.draw(img, in: CGRect(x: x, y: h - img.height, width: img.width, height: img.height))
            x += img.width
        }
        guard let out = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }
}

extension VoiceRecorder {
    /// État « enregistrement en cours » factice pour le rendu.
    func previewRecording() {
        setPreview(phase: .recording, levels: (0..<Self.barCount).map { i in 0.35 + 0.65 * abs(sin(Double(i) * 0.7)) })
    }
}
