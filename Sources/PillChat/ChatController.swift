import AppKit
import SwiftUI

/// État de l'interface et actions.
/// - Message reçu → conversation compacte (le nouveau message, saisie, micro, emojis), qui se referme après l'envoi.
/// - Retour, ou ouverture de l'app → cercles des derniers échanges → conversation avec l'historique.
final class ChatController: ObservableObject {
    enum Mode: Equatable { case conversation, picker, setup }

    @Published var mode: Mode = .picker
    @Published var shown = false
    @Published var chat: ChatInfo? { didSet { store.watch(chat?.id) } }
    @Published var history: [Message] = []
    /// Change à chaque chargement d'historique (identité de la liste de messages).
    @Published var historyVersion = 0
    /// Ouverte par un message entrant : on n'affiche que les nouveaux messages et on referme après la réponse.
    @Published var transient = false
    @Published var draft = ""
    @Published var query = ""
    /// Incrémenté pour demander le focus du champ de saisie.
    @Published var focusToken = 0

    let store: MessagesStore
    let recorder: VoiceRecorder
    var S: CGFloat
    weak var panel: NSPanel?
    /// Rectangle visible (coordonnées de la fenêtre, origine en haut à gauche) : le reste laisse passer la souris.
    var contentRect: CGRect = .zero
    var pointerInside = false
    var onVisibility: ((Bool) -> Void)?


    static let bubble = Animation.spring(response: 0.4, dampingFraction: 0.88)

    init(store: MessagesStore, recorder: VoiceRecorder, scale: CGFloat) {
        self.store = store
        self.recorder = recorder
        self.S = scale
    }

    /// Toutes les conversations (filtrées par la recherche).
    var results: [ChatInfo] { store.search(query) }

    /// L'utilisateur est en train de faire quelque chose : on ne ferme pas, on ne remplace pas.
    var isBusy: Bool {
        panel?.isKeyWindow == true || !draft.trimmingCharacters(in: .whitespaces).isEmpty || recorder.isActive
    }

    // MARK: Accusés de réception

    func receipt(_ m: Message) {
        guard m.chatID == chat?.id, let i = history.firstIndex(where: { $0.id == m.id }) else { return }
        guard history[i].delivered != m.delivered || history[i].readAt != m.readAt else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            history[i].delivered = m.delivered
            history[i].readAt = m.readAt
        }
    }

    // MARK: Messages entrants

    func incoming(_ m: Message, in c: ChatInfo) {
        if m.fromMe {
            guard c.id == chat?.id, shown else { return }
            if let i = history.firstIndex(where: { $0.pending && $0.matchKey == m.matchKey }) {
                var confirmed = m
                confirmed.uiID = history[i].listID
                history[i] = confirmed
            } else if !history.contains(where: { $0.id == m.id }) {
                withAnimation(Self.bubble) { history.append(m) }
            }
            return
        }
        if shown, mode == .conversation, c.id == chat?.id {
            withAnimation(Self.bubble) { history.append(m) }
            if !peek { markSeen() }
            return
        }
        // On ne coupe pas quelqu'un qui est en train d'écrire ou de chercher.
        if shown, isBusy || mode == .picker { return }
        // Inutile de notifier si Messages est au premier plan.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Sender.messagesID { return }
        notify(c, m)
    }

    func notify(_ c: ChatInfo, _ m: Message) {
        dlog("notif de \(c.name) (mode \(mode), affichée : \(shown))")
        recorder.discard()
        withAnimation(shown ? D.island : nil) {
            chat = c; history = [m]; draft = ""; mode = .conversation; transient = true
            // Notif compacte (nom + messages, la saisie apparaît au survol)… sauf si la souris est déjà
            // sur la pilule : rien ne la redéplierait.
            peek = !pointerInside
        }
        // Pas de focus automatique : on ne vole pas le clavier à l'app en cours.
        // Un clic dans le champ (ou ⌃⌘R) suffit pour écrire.
        show()
        fromNotification = true
        if !pointerInside { scheduleNotifHide() }
    }

    // MARK: Disparition quand la souris sort

    private var leaveWork: DispatchWorkItem?
    /// Fenêtre du Finder ouverte (trombone) : la souris sort forcément, on ne ferme pas.
    var choosingFiles = false

    /// Quelque chose est en cours : message commencé, pièces jointes, vocal, recherche tapée…
    private var hasWorkInProgress: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftFiles.isEmpty
            || recorder.isActive || !query.trimmingCharacters(in: .whitespaces).isEmpty || choosingFiles
            || isTyping // curseur dans le champ : on peut écrire souris hors de la pilule
    }

    private func scheduleLeaveHide() {
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shown, !self.pointerInside, !self.hasWorkInProgress, self.mode != .setup else { return }
            self.fromNotification = false
            self.hide()
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: Disparition façon notification

    /// Pilule ouverte par un message reçu : elle disparaît seule si on ne la survole pas.
    private var fromNotification = false
    private var notifHideWork: DispatchWorkItem?
    static let notifDelay: TimeInterval = 5

    private func scheduleNotifHide() {
        notifHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fromNotification, self.shown, !self.pointerInside else { return }
            // En train d'écrire, d'enregistrer, ou le champ a le clavier : on laisse la pilule.
            if self.isBusy { return }
            self.fromNotification = false
            self.hide()
        }
        notifHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notifDelay, execute: work)
    }

    private func cancelNotifHide(forget: Bool) {
        notifHideWork?.cancel()
        if forget { fromNotification = false }
    }

    // MARK: Notif compacte (« peek »)

    /// Notif reçue : seulement le nom et les messages. Au survol, la saisie et les emojis apparaissent
    /// et la pilule prend sa hauteur maximale ; elle se rétracte quand la souris s'en va (si rien n'est en cours).
    @Published var peek = false { didSet { if peek != oldValue { dlog("mode compact : \(peek) (survol : \(pointerInside))") } } }
    /// Pilule dépliée depuis une notif (pour savoir qu'on peut la rétracter).
    private var peekable = false
    /// Notif dépliée au survol : la pilule prend sa hauteur maximale.
    var unfolded: Bool { peekable && !peek }
    private var collapseWork: DispatchWorkItem?

    /// La conversation affichée est vue : sa bulle d'aperçu et ses non-lus disparaissent.
    func markSeen() {
        guard let c = chat, let last = history.last(where: { $0.id > 0 }) else { return }
        store.markSeen(chatID: c.id, upTo: last.id)
    }

    /// Clic dans une pilule compacte : elle se déplie tout de suite.
    func unfoldIfNeeded() {
        guard peek, mode == .conversation else { return }
        peekable = true
        withAnimation(D.island) { peek = false }
        if transient { transient = false; loadHistory() }
        focus(field: true) // clic dans la notif : curseur prêt
    }

    func pointerChanged(inside: Bool) {
        // Partout : la souris sort de la pilule → elle disparaît (sauf si quelque chose est en cours).
        if inside { leaveWork?.cancel() } else if shown { scheduleLeaveHide() }
        // Notif : survol = elle reste.
        if fromNotification, shown, inside { cancelNotifHide(forget: false) }
        guard mode == .conversation, shown else { return }
        if inside {
            collapseWork?.cancel()
            guard peek else { return }
            if transient { peekable = true } // notif dépliée : hauteur maximale
            withAnimation(D.island) { peek = false }
            if transient { transient = false; loadHistory() } // le contexte de la conversation arrive
        } else if !peek {
            // Curseur hors de la pilule : la zone de saisie se replie (le brouillon est gardé).
            collapseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.pointerInside, self.mode == .conversation,
                      !self.recorder.isActive, !self.choosingFiles, !self.isTyping else { return }
                withAnimation(D.island) { self.peek = true }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    // MARK: Vocal « tenir pour parler »

    @Published var holdRecording = false
    private var holdStart = Date()
    /// Glissé vers la gauche pendant l'enregistrement maintenu (≤ 0).
    @Published var holdDrag: CGFloat = 0
    /// Assez loin à gauche : relâcher supprime le vocal.
    @Published var cancelArmed = false

    // MARK: Appel

    /// Lance un appel FaceTime audio vers la personne de la conversation.
    func call() {
        guard let c = chat, !c.isGroup, let handle = c.handles.first else { return }
        let target = handle.contains("@") ? handle : handle.filter { $0.isNumber || $0 == "+" }
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "facetime-audio://\(encoded)") else { return }
        dlog("appel FaceTime audio vers \(c.name)")
        NSWorkspace.shared.open(url)
    }

    // MARK: Réactions

    func applyReactions(_ map: [String: [Reaction]], chatID: Int64) {
        guard chatID == chat?.id else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            for i in history.indices where !history[i].guid.isEmpty {
                let r = map[history[i].guid] ?? []
                if history[i].reactions != r { history[i].reactions = r }
            }
        }
    }

    // MARK: Navigation

    func open(_ c: ChatInfo) {
        dlog(String(format: "ouverture de la conversation %@", c.name))
        cancelNotifHide(forget: true) // ouverte à la main : plus de disparition automatique
        recorder.discard()
        peekable = false
        let switching = c.id != chat?.id || transient
        withAnimation(D.island) {
            chat = c; draft = ""; mode = .conversation; transient = false; peek = false
            if switching { history = [] }
        }
        loadHistory()
        focus(field: true) // conversation ouverte : curseur prêt, on tape tout de suite
    }

    /// `focus` : prendre le clavier (seulement sur demande explicite : raccourci, icône, retour).
    func openPicker(focus wantsFocus: Bool = true) {
        cancelNotifHide(forget: true)
        recorder.discard()
        peek = false
        query = ""
        if shown {
            withAnimation(D.island) { mode = .picker; transient = false }
        } else {
            mode = .picker
            transient = false
            show()
        }
        if wantsFocus { focus() }
    }

    /// « Rechercher » / Entrée : rien ne se passe tant que la recherche est vide.
    func openFirstResult() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let c = results.first else { return }
        open(c)
    }

    func showSetup() {
        mode = .setup
        show()
    }

    /// Raccourci global / icône de la barre des menus : ouvre les cercles, ou donne le clavier à la pilule affichée.
    /// La pilule ne se ferme que par un double-clic sur sa poignée.
    func toggle() {
        if shown { focus() } else { openPicker() }
    }

    /// Échap : annule le vocal en cours, sinon rend le clavier à l'app d'avant (la pilule reste affichée).
    func escape() {
        if recorder.isActive { withAnimation(D.island) { recorder.discard() }; return }
        releaseKeyboard()
    }

    /// Le curseur quitte la pilule : l'app au premier plan (jamais PillChat, la fenêtre ne l'active pas)
    /// reprend le clavier.
    func releaseKeyboard() {
        guard panel?.isKeyWindow == true else { return }
        focusToken = -abs(focusToken) - 1 // signal négatif : les champs perdent le focus
        // Retirer puis remettre la fenêtre (sans la rendre « clé ») : macOS rend le clavier
        // à la fenêtre de l'app au premier plan. La pilule ne disparaît pas à l'écran.
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        // Souris déjà dehors : la pilule peut maintenant disparaître comme d'habitude.
        if !pointerInside, shown { scheduleLeaveHide() }
    }


    private func loadHistory() {
        guard let c = chat else { return }
        store.history(for: c) { [weak self] msgs in
            guard let self, self.chat?.id == c.id, !self.transient else { return }
            let pending = self.history.filter(\.pending)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                self.history = msgs + pending
                self.historyVersion += 1 // la liste est recréée : elle démarre directement en bas
            }
            self.markSeen()
        }
    }

    /// Donne le clavier à la pilule. Par défaut sans activer le champ de saisie : le curseur n'apparaît
    /// qu'au clic dans le champ, et la touche @ ferme la pilule tant qu'on n'écrit pas.
    /// `field: true` : activer aussi le champ (on était déjà en train d'écrire : envoi, pièce jointe).
    func focus(field: Bool = false) {
        panel?.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if field {
                self.focusToken = abs(self.focusToken) + 1
                // macOS sélectionne tout le texte d'un champ qui prend le focus : on place le curseur à la fin,
                // sinon la prochaine touche effacerait le message en cours.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let tv = self.panel?.firstResponder as? NSTextView {
                        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    }
                }
            } else {
                self.focusToken = -abs(self.focusToken) - 1
                self.panel?.makeFirstResponder(nil)
            }
        }
    }

    /// Le champ de saisie (message ou recherche) a le curseur.
    var isTyping: Bool { panel?.isKeyWindow == true && panel?.firstResponder is NSTextView }

    // MARK: Apparition

    func show() {
        onVisibility?(true)
        DispatchQueue.main.async {
            withAnimation(D.appear) { self.shown = true }
        }
    }

    func hide() {
        recorder.discard()
        withAnimation(.easeIn(duration: 0.22)) { shown = false }
        store.watch(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !self.shown else { return }
            self.onVisibility?(false)
            self.draft = ""
        }
    }

    // MARK: Envoi

    /// Bouton « Répondre » / touche Entrée.
    func sendDraft() {
        guard let c = chat else { return }
        if recorder.isActive { sendVoice(to: c); return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = draftFiles
        guard !text.isEmpty || !files.isEmpty else { focus(field: true); return }
        draft = ""
        withAnimation(D.island) { draftFiles = [] }
        for url in files { sendFile(url, to: c) }
        if !text.isEmpty { sendText(text, to: c) }
    }

    // MARK: Pièces jointes à envoyer

    static let maxFiles = 5
    /// Fichiers ajoutés au message (trombone, ⌘V, glisser-déposer), envoyés avec « Envoyer ».
    @Published var draftFiles: [URL] = []

    func addFiles(_ urls: [URL]) {
        let room = Self.maxFiles - draftFiles.count
        guard room > 0 else { NSSound.beep(); return }
        let fresh = urls.filter { u in !draftFiles.contains(u) }.prefix(room)
        if urls.count > room { NSSound.beep() } // au-delà de 5 fichiers
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { draftFiles += fresh }
        focus(field: true)
    }

    func removeFile(_ url: URL) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { draftFiles.removeAll { $0 == url } }
    }

    /// ⌘V : fichiers copiés (Finder) ou image du presse-papiers. Renvoie false s'il n'y a que du texte.
    func pasteFiles() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addFiles(urls)
            return true
        }
        // Du texte (un lien copié, par exemple) : collé tel quel dans le champ, même si une image l'accompagne.
        if let text = pb.string(forType: .string), !text.isEmpty { return false }
        // Image sans fichier (capture copiée, image copiée depuis le web…) : on l'enregistre en PNG.
        if pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PillChat-coller", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Image \(Int(Date().timeIntervalSince1970)).png")
            guard (try? png.write(to: url)) != nil else { return false }
            addFiles([url])
            return true
        }
        return false
    }

    /// Trombone : choisir jusqu'à 5 fichiers dans le Finder.
    func chooseFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.canChooseFiles = true
        open.message = "Choisis jusqu'à \(Self.maxFiles) fichiers à envoyer"
        open.prompt = "Ajouter"
        NSApp.activate(ignoringOtherApps: true) // la fenêtre de choix doit passer devant
        choosingFiles = true
        open.begin { [weak self] response in
            self?.choosingFiles = false
            guard response == .OK else { return }
            self?.addFiles(open.urls)
        }
    }

    /// Envoi d'un fichier : copié dans le dossier des pièces jointes de Messages (seul endroit
    /// d'où Messages accepte d'envoyer par AppleScript), puis envoyé.
    private func sendFile(_ url: URL, to c: ChatInfo) {
        let dir = VoiceRecorder.outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: copy) } catch {
            dlog("pièce jointe impossible à copier : \(error.localizedDescription)")
            return
        }
        let att = Attachment(path: copy.path, mime: "", name: url.lastPathComponent)
        let id = appendPending("", to: c, attachments: [att])
        Sender.send(file: copy, to: c) { [weak self] ok in
            self?.settle(id, ok: ok)
            VoiceRecorder.cleanOutbox()
        }
    }

    /// Réaction choisie sur une bulle : affichée sur la bulle (et envoyée en emoji).
    func addLocalReaction(_ emoji: String, to listID: Int64) {
        guard let i = history.firstIndex(where: { $0.listID == listID }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            history[i].reactions.removeAll { $0.fromMe }
            history[i].reactions.append(Reaction(emoji: emoji, fromMe: true))
        }
    }

    /// Emoji de la rangée du bas : ajouté au message en cours (rien ne part avant Entrée).
    func insertEmoji(_ emoji: String) {
        dlog("emoji \(emoji) ajouté au brouillon")
        draft += emoji
        focus(field: true)
    }

    func react(_ emoji: String) {
        dlog("emoji \(emoji) pour \(chat?.name ?? "personne")")
        guard let c = chat else { return }
        sendText(emoji, to: c)
    }

    private func sendText(_ text: String, to c: ChatInfo) {
        let id = appendPending(text, to: c)
        Sender.send(text: text, to: c) { [weak self] ok in self?.settle(id, ok: ok) }
    }

    private func sendVoice(to c: ChatInfo) {
        guard let url = withAnimation(D.island, { recorder.finish() }) else { return }
        let id = appendPending("", to: c, attachments: [Attachment(path: url.path, mime: "audio/x-caf", name: url.lastPathComponent)])
        Sender.send(file: url, to: c) { [weak self] ok in
            self?.settle(id, ok: ok)
            VoiceRecorder.cleanOutbox()
        }
    }

    private func appendPending(_ text: String, to c: ChatInfo, attachments: [Attachment] = []) -> Int64 {
        let id = -Int64(Date().timeIntervalSince1970 * 1000)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.74)) {
            history.append(Message(id: id, text: text, fromMe: true, date: Date(), handle: nil, chatID: c.id, pending: true,
                                   attachments: attachments))
        }
        return id
    }

    private func settle(_ id: Int64, ok: Bool) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        if !ok {
            withAnimation(.easeOut(duration: 0.2)) { history[i].failed = true }
            return
        }
    }

    // MARK: Poignée

    /// Zone de la poignée (coordonnées de la fenêtre) : on y déplace la fenêtre nativement, double-clic = fermer.
    var grabberRect: CGRect = .zero
    /// Hauteur ajoutée (ou retirée) à la conversation en tirant le trait du bas, gardée d'une fois sur l'autre.
    @Published var extraHeight: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "extraHeight"))
    /// Plafond absolu (la vraie limite dépend de l'écran, calculée pendant le redimensionnement).
    static let maxExtraHeight: CGFloat = 900
    /// Hauteur actuelle de la pilule (accueil ou conversation) : animée pour que le fond s'étire en douceur.
    @Published private(set) var panelHeight: CGFloat = 0

    /// Redimensionnement en cours avec le trait du bas : tout suit la souris, sans animation.
    @Published var isResizing = false

    func setPanelHeight(_ h: CGFloat) {
        guard abs(h - panelHeight) > 0.5 else { return }
        // Premier affichage ou redimensionnement à la main : pas d'animation (sinon le fond traîne derrière).
        if panelHeight == 0 || !shown || isResizing {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { panelHeight = h }
            return
        }
        withAnimation(D.island) { panelHeight = h }
    }
    /// Déplacement en cours : légère lévitation + étirement dans le sens du mouvement (version douce de PillMusic).
    @Published var isMoving = false
    @Published var squash = CGSize(width: 1, height: 1)
    private var lastMove: (origin: NSPoint, time: TimeInterval)?
    private var moveEnd: DispatchWorkItem?

    /// Appelé à chaque déplacement de la fenêtre pendant un glisser.
    func windowMoved(to origin: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastMove = (origin, now) }
        if !isMoving { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isMoving = true } }
        if let last = lastMove, now - last.time < 0.2 {
            let dt = max(now - last.time, 1.0 / 240)
            let vx = abs(origin.x - last.origin.x) / dt, vy = abs(origin.y - last.origin.y) / dt
            let sx = min(vx / 9000, 0.035), sy = min(vy / 9000, 0.035)
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.75)) {
                squash = CGSize(width: 1 + sx - sy * 0.5, height: 1 + sy - sx * 0.5)
            }
        }
        // Plus de mouvement depuis un instant : on lâche, avec un petit rebond.
        moveEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastMove = nil
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                self.isMoving = false
                self.squash = CGSize(width: 1, height: 1)
            }
        }
        moveEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: end)
    }
}
