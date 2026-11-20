import AVFoundation
import AppKit
import Combine

/// Enregistrement d'un message vocal, avec niveaux en direct pour la forme d'onde, puis réécoute.
final class VoiceRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable { case idle, recording, recorded, playing }

    static let barCount = 42

    @Published private(set) var phase: Phase = .idle
    /// Hauteurs des barres, 0…1.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0.12, count: barCount)
    /// Avancement de la réécoute, 0…1.
    @Published private(set) var progress: Double = 0
    /// Durée enregistrée (secondes), pour le minuteur.
    @Published private(set) var elapsed: Double = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var samples: [CGFloat] = []
    private(set) var fileURL: URL?

    var isActive: Bool { phase != .idle }

    /// Les fichiers à envoyer vont dans le dossier des pièces jointes de Messages :
    /// c'est l'endroit d'où Messages accepte d'envoyer par AppleScript.
    static var outbox: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Messages/Attachments/PillChat", isDirectory: true)
    }

    func start() {
        guard phase == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.begin() } }
            }
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    private func begin() {
        let dir = Self.outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Opus en .caf : le format des messages vocaux iMessage. AAC en secours.
        let attempts: [(String, [String: Any])] = [
            // Même format et même nom que les messages vocaux de Messages : Opus mono 24 kHz, « Audio Message.caf ».
            ("Audio Message.caf", [AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1]),
            ("Audio Message.caf", [AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]),
            ("Audio Message.m4a", [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                   AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]),
        ]
        for (name, settings) in attempts {
            let url = dir.appendingPathComponent(name)
            guard let r = try? AVAudioRecorder(url: url, settings: settings), r.prepareToRecord() else { continue }
            r.isMeteringEnabled = true
            guard r.record() else { continue }
            recorder = r
            fileURL = url
            samples = []
            elapsed = 0
            levels = Array(repeating: 0.12, count: Self.barCount)
            phase = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.meter() }
            return
        }
        dlog("impossible de démarrer l'enregistrement")
    }

    private func meter() {
        guard let r = recorder else { return }
        r.updateMeters()
        // dB → amplitude, avec un peu de gain pour que la voix remplisse la barre.
        let amp = CGFloat(pow(10, Double(r.averagePower(forChannel: 0)) / 20))
        let level = min(max(pow(amp, 0.6) * 1.6, 0.12), 1)
        samples.append(level)
        elapsed = Double(samples.count) / 20
        levels = Array((Array(repeating: CGFloat(0.12), count: Self.barCount) + samples).suffix(Self.barCount))
    }

    func stop() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        // Forme d'onde finale : tout l'enregistrement ramené à la largeur de la barre.
        if samples.count > Self.barCount {
            let step = Double(samples.count) / Double(Self.barCount)
            levels = (0..<Self.barCount).map { i in
                let slice = samples[Int(Double(i) * step)..<min(Int(Double(i + 1) * step), samples.count)]
                return slice.max() ?? 0.12
            }
        }
        phase = .recorded
    }

    func togglePlay() {
        switch phase {
        case .recorded:
            guard let url = fileURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.delegate = self
            p.play()
            player = p
            phase = .playing
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        case .playing:
            stopPlayback()
        default: break
        }
    }

    private func stopPlayback() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        progress = 0
        if phase == .playing { phase = .recorded }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stopPlayback() }
    }

    /// Termine l'enregistrement et rend le fichier à envoyer (l'appelant le supprimera plus tard).
    func finish() -> URL? {
        if phase == .recording { stop() }
        stopPlayback()
        let url = fileURL
        fileURL = nil
        phase = .idle
        return url
    }

    func discard() {
        if phase == .recording { stop() }
        stopPlayback()
        if let url = fileURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        fileURL = nil
        phase = .idle
    }

    func setPreview(phase: Phase, levels: [CGFloat]) {
        self.phase = phase
        self.levels = levels
    }

    /// Ménage des anciens envois (Messages a déjà copié les fichiers).
    static func cleanOutbox(olderThan age: TimeInterval = 600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? fm.removeItem(at: item) }
        }
    }
}
