import AVFoundation
import AVKit
import AppKit
import ImageIO
import SwiftUI

// MARK: - Miniatures des photos (ImageIO, en arrière-plan, avec cache)

enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    private static var ratios: [String: CGFloat] = [:]

    /// Proportions de la photo lues dans l'en-tête du fichier (instantané) : la place est réservée
    /// avant le chargement, la conversation ne bouge plus quand l'image arrive.
    static func aspect(_ path: String) -> CGFloat? {
        if let r = ratios[path] { return r }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else { return nil }
        // Orientations 5 à 8 : photo tournée de 90°, largeur et hauteur s'échangent.
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        let r = o >= 5 ? h / w : w / h
        ratios[path] = r
        return r
    }

    static func load(_ path: String, maxPixel: Int = 700) async -> NSImage? {
        if let img = cached(path) { return img }
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, // respecte l'orientation des photos iPhone
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: path as NSString) }
        return img
    }
}

struct PhotoAttachment: View {
    let attachment: Attachment
    let S: CGFloat
    private let _imageBox = State<NSImage?>(initialValue: nil)
    private var image: NSImage? { get { _imageBox.wrappedValue } nonmutating set { _imageBox.wrappedValue = newValue } }

    var body: some View {
        let maxW = 330 * S, maxH = 400 * S
        // Taille finale connue d'avance (proportions lues dans le fichier).
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? Thumbnails.aspect(attachment.path) ?? 1
        let w = min(maxW, maxH * ratio)
        Button {
            NSWorkspace.shared.open(attachment.url) // ouvre la photo en grand (Aperçu)
        } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: w, height: w / ratio)
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 40 * S, style: .continuous).fill(D.ink.opacity(0.06))
                        .frame(width: w, height: w / ratio)
                        .overlay(Text(attachment.exists ? "" : "Photo non téléchargée")
                            .font(D.font(18 * S)).foregroundStyle(D.ink.opacity(0.35)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 40 * S, style: .continuous))
        }
        .buttonStyle(Bouncy(pressed: 0.96, hovered: 1.02))
        .task(id: attachment.path) {
            if let img = await Thumbnails.load(attachment.path) {
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
        }
    }
}

// MARK: - Lecture des messages vocaux

/// Un seul vocal à la fois, comme dans Messages.
final class AudioPlayback: ObservableObject {
    static let shared = AudioPlayback()

    @Published private(set) var playingPath: String?
    @Published private(set) var progress: Double = 0

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    private var statusObserver: NSKeyValueObservation?

    func toggle(_ path: String) {
        if playingPath == path { stop(); return }
        stop()
        dlog("vocal : lecture de \(path) (fichier présent : \(FileManager.default.fileExists(atPath: path)))")
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        statusObserver = item.observe(\.status) { item, _ in
            if item.status == .failed { dlog("vocal : échec de lecture — \(item.error?.localizedDescription ?? "?")") }
            if item.status == .readyToPlay { dlog("vocal : prêt (\(item.duration.seconds) s)") }
        }
        let p = AVPlayer(playerItem: item)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            self.progress = min(t.seconds / d, 1)
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
            [weak self] _ in self?.stop()
        }
        player = p
        playingPath = path
        progress = 0
        p.play()
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil; endObserver = nil
        player?.pause(); player = nil
        playingPath = nil
        progress = 0
    }
}

/// Forme d'onde et durée calculées à partir du fichier (en arrière-plan, avec cache).
enum VoiceInfo {
    struct Info { let bars: [CGFloat]; let duration: Double }
    private static var cache: [String: Info] = [:]
    private static let lock = NSLock()

    static func load(_ path: String, bars count: Int = 28) async -> Info? {
        let hit = lock.withLock { cache[path] }
        if let hit { return hit }
        let info: Info? = await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
            let frames = AVAudioFrameCount(file.length)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  (try? file.read(into: buf)) != nil, let data = buf.floatChannelData?[0] else {
                return Info(bars: [], duration: duration)
            }
            let n = Int(buf.frameLength), step = max(n / count, 1)
            var bars: [CGFloat] = []
            for i in 0..<count {
                var peak: Float = 0
                let start = i * step, end = min(start + step, n)
                if start < end { for j in start..<end { peak = max(peak, abs(data[j])) } }
                bars.append(CGFloat(peak))
            }
            let top = max(bars.max() ?? 1, 0.01)
            return Info(bars: bars.map { max($0 / top, 0.12) }, duration: duration)
        }.value
        if let info { lock.withLock { cache[path] = info } }
        return info
    }
}

/// Bulle vocale (style du prototype) : pilule claire, bouton lecture rouge, onde rouge de 26 barres
/// qui se remplit pendant l'écoute, durée à droite.
struct VoiceAttachment: View {
    let attachment: Attachment
    let fromMe: Bool
    let S: CGFloat
    @ObservedObject private var playback = AudioPlayback.shared
    private let _infoBox = State<VoiceInfo.Info?>(initialValue: nil)
    private var info: VoiceInfo.Info? { get { _infoBox.wrappedValue } nonmutating set { _infoBox.wrappedValue = newValue } }

    static let barCount = 26
    static let fill = Color.adaptive(light: 0xF4F4F4, dark: 0x3A3A3C, lightAlpha: 0.92, darkAlpha: 0.92)

    var body: some View {
        let playing = playback.playingPath == attachment.path
        let raw = info?.bars.isEmpty == false ? info!.bars
            : (0..<Self.barCount).map { i in 0.3 + 0.5 * abs(sin(Double(i) * 0.9 + Double(attachment.path.count))) }
        let bars = Self.resample(raw, to: Self.barCount)
        HStack(spacing: 18 * S) {
            Button {
                guard attachment.exists else {
                    dlog("vocal introuvable sur le disque (expiré ou pas encore téléchargé) : \(attachment.path)")
                    return
                }
                playback.toggle(attachment.path)
            } label: {
                ZStack {
                    Circle().fill(D.red)
                    if playing {
                        HStack(spacing: 5 * S) {
                            RoundedRectangle(cornerRadius: 1.5 * S).frame(width: 6 * S, height: 20 * S)
                            RoundedRectangle(cornerRadius: 1.5 * S).frame(width: 6 * S, height: 20 * S)
                        }
                        .foregroundStyle(.white)
                    } else {
                        GlyphView(glyph: .play, size: 24 * S, color: .white).offset(x: 1.5 * S)
                    }
                }
                .frame(width: 60 * S, height: 60 * S)
                .contentShape(Circle())
            }
            .buttonStyle(Bouncy(pressed: 0.9, hovered: 1.08))
            .animation(D.press, value: playing)

            HStack(alignment: .center, spacing: 4.5 * S) {
                ForEach(0..<bars.count, id: \.self) { i in
                    let played = playing && Double(i) / Double(bars.count) <= playback.progress
                    Capsule()
                        .fill(D.red.opacity(!playing || played ? 1 : 0.3))
                        .frame(width: 3 * S, height: (4.5 + bars[i] * 28) * S)
                        .animation(.linear(duration: 0.12), value: played)
                }
            }
            .frame(height: 36 * S)

            Text(durationText(playing ? (info?.duration ?? 0) * (1 - playback.progress) : (info?.duration ?? 0)))
                .font(D.font(20 * S, 600)).monospacedDigit()
                .foregroundStyle(D.ink.opacity(0.6))
                .frame(minWidth: 46 * S, alignment: .leading)
        }
        .padding(.leading, 10 * S)
        .padding(.trailing, 28 * S)
        .frame(height: 80 * S)
        .background(Capsule().fill(Self.fill))
        .opacity(attachment.exists ? 1 : 0.5)
        .task(id: attachment.path) { info = await VoiceInfo.load(attachment.path) }
    }

    /// Ramène l'onde à `n` barres (pic de chaque tranche).
    static func resample(_ v: [CGFloat], to n: Int) -> [CGFloat] {
        guard v.count != n, !v.isEmpty else { return v }
        return (0..<n).map { i in
            let a = i * v.count / n, b = max(a + 1, (i + 1) * v.count / n)
            return v[a..<min(b, v.count)].max() ?? 0.2
        }
    }

    private func durationText(_ t: Double) -> String {
        guard t > 0 else { return "0:00" }
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Vidéos

/// Vignette (première image), proportions et durée d'une vidéo, calculées en arrière-plan et mises en cache.
enum VideoInfo {
    struct Info { let thumb: NSImage?; let ratio: CGFloat; let duration: Double }
    private static var cache: [String: Info] = [:]
    private static let lock = NSLock()

    static func cached(_ path: String) -> Info? { lock.withLock { cache[path] } }

    static func load(_ path: String) async -> Info? {
        if let hit = cached(path) { return hit }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        var ratio: CGFloat = 16.0 / 9
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            if r.height > 0 { ratio = abs(r.width) / abs(r.height) }
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true // vidéos iPhone tournées dans le bon sens
        generator.maximumSize = CGSize(width: 700, height: 700)
        var thumb: NSImage?
        if let (cg, _) = try? await generator.image(at: CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)) {
            thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        let info = Info(thumb: thumb, ratio: ratio, duration: duration.isFinite ? duration : 0)
        lock.withLock { cache[path] = info }
        return info
    }
}

/// Vidéo dans la conversation : vignette + ▶︎ + durée ; un clic la lit dans la bulle.
struct VideoAttachment: View {
    let attachment: Attachment
    let S: CGFloat
    private let _infoBox = State<VideoInfo.Info?>(initialValue: nil)
    private var info: VideoInfo.Info? { get { _infoBox.wrappedValue } nonmutating set { _infoBox.wrappedValue = newValue } }
    private let _playerBox = State<AVPlayer?>(initialValue: nil)
    private var player: AVPlayer? { get { _playerBox.wrappedValue } nonmutating set { _playerBox.wrappedValue = newValue } }

    var body: some View {
        let maxW = 330 * S, maxH = 400 * S
        let current = info ?? VideoInfo.cached(attachment.path)
        let ratio = current?.ratio ?? 16.0 / 9
        let w = min(maxW, maxH * ratio)
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                if let thumb = current?.thumb {
                    Image(nsImage: thumb).resizable().interpolation(.high).scaledToFill()
                } else {
                    Rectangle().fill(D.ink.opacity(0.08))
                }
                // Bouton lecture au centre.
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                    GlyphView(glyph: .play, size: 26 * S, color: .white).offset(x: 2 * S)
                }
                .frame(width: 64 * S, height: 64 * S)
                // Durée en bas à droite.
                if let d = current?.duration, d > 0 {
                    Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
                        .font(D.font(16 * S, 600)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8 * S).padding(.vertical, 3 * S)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .padding(10 * S)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if !attachment.exists {
                    Text("Vidéo non téléchargée").font(D.font(16 * S)).foregroundStyle(.white)
                        .padding(8 * S).background(Capsule().fill(.black.opacity(0.45)))
                }
            }
        }
        .frame(width: w, height: w / ratio)
        .clipShape(RoundedRectangle(cornerRadius: 40 * S, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 40 * S, style: .continuous))
        .onTapGesture {
            guard player == nil, attachment.exists else { return }
            let p = AVPlayer(url: attachment.url)
            withAnimation(.easeOut(duration: 0.2)) { player = p }
            p.play()
        }
        .contextMenu {
            Button("Ouvrir dans QuickTime") { NSWorkspace.shared.open(attachment.url) }
            if player != nil { Button("Revenir à l'aperçu") { player?.pause(); player = nil } }
        }
        .task(id: attachment.path) { info = await VideoInfo.load(attachment.path) }
    }
}

/// Vidéo ou fichier : une pastille qui ouvre la pièce jointe.
struct FileAttachment: View {
    let attachment: Attachment
    let fromMe: Bool
    let S: CGFloat

    var body: some View {
        let ink: Color = fromMe ? .white : D.ink.opacity(0.8)
        Button { NSWorkspace.shared.open(attachment.url) } label: {
            HStack(spacing: 12 * S) {
                Image(systemName: attachment.kind == .video ? "play.rectangle.fill" : "doc.fill")
                    .font(.system(size: 22 * S, weight: .medium))
                Text(attachment.name.isEmpty ? attachment.url.lastPathComponent : attachment.name)
                    .font(D.font(22 * S)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(ink)
            .padding(.vertical, 25 * S)
            .padding(.horizontal, 32 * S)
            .background(RoundedRectangle(cornerRadius: 40 * S, style: .continuous).fill(fromMe ? D.blue : D.received))
            .opacity(attachment.exists ? 1 : 0.5)
        }
        .buttonStyle(Bouncy(pressed: 0.96, hovered: 1.02))
    }
}
