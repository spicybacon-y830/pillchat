import AppKit
import Carbon.HIToolbox
import Combine
import CoreText
import ServiceManagement
import SwiftUI

// MARK: - Taille

enum ChatSize: String, CaseIterable {
    case small, medium, large

    /// Facteur appliqué aux mesures du design Paper (727 de large).
    var scale: CGFloat {
        switch self {
        case .small: return 0.4
        case .medium: return 0.47
        case .large: return 0.55
        }
    }

    var label: String {
        switch self {
        case .small: return "Petite"
        case .medium: return "Moyenne"
        case .large: return "Grande"
        }
    }
}

// MARK: - Fenêtre flottante

final class ChatPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = true                   // déplacement natif depuis la poignée uniquement
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    /// La fenêtre déborde (ombre, marges) : on la laisse se placer sous la barre des menus.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// Peut recevoir le clavier sans activer l'app (on ne vole pas le focus à l'app en cours).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Apparence toujours « active » : sans ça, macOS assombrit le Liquid Glass et retire ses ombres
    // dès que la fenêtre n'a plus le clavier. (Méthodes internes d'AppKit, remplacées pour cette fenêtre.)
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
}

final class ChatHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: ((NSEvent) -> Void)?
    /// Renvoie true si le clic a été pris en charge (poignée).
    var onMouseDown: ((CGPoint, NSEvent) -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override func mouseDown(with event: NSEvent) {
        dlog("clic à \(NSStringFromPoint(convert(event.locationInWindow, from: nil))) (fenêtre clé : \(window?.isKeyWindow == true))")
        if onMouseDown?(convert(event.locationInWindow, from: nil), event) == true { return }
        super.mouseDown(with: event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MessagesStore()
    private let recorder = VoiceRecorder()
    private var controller: ChatController!
    private var panel: ChatPanel!
    private var host: ChatHostingView<RootView>!
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    /// Suivi de la souris tant que la fenêtre est visible (les moniteurs d'événements peuvent en rater).
    private var pointerTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard

    private var size: ChatSize {
        get { ChatSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "size") }
    }

    /// Apparence : "system" (suit le Mac), "light" ou "dark".
    private var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "system" }
        set { defaults.set(newValue, forKey: "appearance"); applyAppearance() }
    }

    private func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private var keepMessagesOpen: Bool {
        get { defaults.object(forKey: "keepMessagesOpen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepMessagesOpen") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        dlog(String(format: "lancée (%@)", Bundle.main.bundlePath))
        applyAppearance()

        controller = ChatController(store: store, recorder: recorder, scale: size.scale)
        panel = ChatPanel()
        host = ChatHostingView(rootView: RootView(c: controller, store: store, recorder: recorder))
        host.sizingOptions = []
        host.onRightClick = { [weak self] e in self?.showMenu(e) }
        panel.contentView = host
        controller.panel = panel
        controller.onVisibility = { [weak self] visible in
            guard let self else { return }
            if visible {
                if !self.panel.isVisible { self.panel.orderFrontRegardless() }
                dlog("fenêtre affichée : \(NSStringFromRect(self.panel.frame))")
                if self.pointerTimer == nil {
                    let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updatePassthrough() }
                    RunLoop.main.add(t, forMode: .common)
                    self.pointerTimer = t
                }
            } else {
                self.panel.orderOut(nil)
                self.pointerTimer?.invalidate()
                self.pointerTimer = nil
            }
            self.updatePassthrough()
        }
        // Poignée : glisser = déplacement natif (fluide, géré par macOS), double-clic = fermer.
        host.onMouseDown = { [weak self] point, event in
            guard let self else { return false }
            self.controller.unfoldIfNeeded()
            // Trait du bas : glisser = rallonger / raccourcir la pilule.
            if self.controller.grabberRect.insetBy(dx: -6, dy: -6).contains(point) {
                self.grabberDown(event)
                return true
            }
            // Bords de la pilule : déplacement natif (fluide, géré par macOS).
            let r = self.controller.contentRect
            if self.inDragBand(point) {
                self.panel.performDrag(with: event) // rend la main au relâchement
                self.keepOnScreen()
                return true
            }
            return false
        }
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, NSEvent.pressedMouseButtons & 1 != 0 else { return } // seulement quand on la glisse
                self.userMoved = true
                self.controller.windowMoved(to: self.panel.frame.origin)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Seulement après un déplacement fait à la main (pas quand l'app place elle-même la fenêtre).
                guard self.userMoved else { return }
                self.userMoved = false
                self.savePosition()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.keepOnScreen() } // fin du déplacement
            }
            .store(in: &cancellables)
        layoutWindow()

        store.onMessage = { [weak self] m, chat in self?.controller.incoming(m, in: chat) }
        store.onReceipt = { [weak self] m in self?.controller.receipt(m) }
        store.onReactions = { [weak self] chatID, map in self?.controller.applyReactions(map, chatID: chatID) }
        store.$access.removeDuplicates().sink { [weak self] access in
            guard let self else { return }
            if access == .denied { self.controller.showSetup() }
            if access == .granted, self.controller.mode == .setup { self.controller.hide() }
        }.store(in: &cancellables)
        store.start()

        // Messages doit tourner (masquée) pour recevoir et envoyer.
        if keepMessagesOpen { Sender.ensureMessagesRunning() }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier == Sender.messagesID }
            .delay(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in if self?.keepMessagesOpen == true { Sender.ensureMessagesRunning() } }
            .store(in: &cancellables)

        // Les zones transparentes de la fenêtre laissent passer la souris.
        panel.ignoresMouseEvents = true
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.updatePassthrough()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp], handler: { [weak self] e in
            DispatchQueue.main.async { self?.updatePassthrough() }
            return e
        }) { monitors.append(m) }
        // Échap : annule l'enregistrement, sinon ferme.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.controller.shown else { return e }
            // ⌘V dans une conversation : fichiers ou image du presse-papiers → pièces jointes.
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "v",
               self.controller.mode == .conversation, self.controller.pasteFiles() {
                return nil
            }
            // ⌘W : fermer la pilule.
            // On teste le caractère et non la position de la touche : marche en AZERTY comme en QWERTY.
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "w" {
                self.controller.hide()
                return nil
            }
            guard e.keyCode == UInt16(kVK_Escape) else { return e }
            self.controller.escape()
            return nil
        }) { monitors.append(m) }

        // ⌃⌘R : écrire à quelqu'un depuis n'importe quelle app.
        hotKey = GlobalHotKey(character: "r", modifiers: UInt32(controlKey | cmdKey)) { [weak self] in self?.controller.toggle() }

        VoiceRecorder.cleanOutbox()
        setupStatusItem()

        // Ouverture à la main : on affiche les cercles pour écrire vite. Au démarrage du Mac : rien.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.store.access != .denied, !self.controller.shown else { return }
                self.controller.openPicker(focus: false) // ne pas voler le clavier au lancement
                // Vérification visuelle : ouvre la conversation la plus récente (sans prendre le clavier).
                if CommandLine.arguments.contains("--open-recent") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if let first = self.store.recents.first {
                            self.controller.open(first)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.controller.releaseKeyboard() }
                        }
                    }
                }
            }
        }
    }

    /// Relancer l'app (Spotlight, Applications) ouvre la recherche.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.openPicker()
        return false
    }

    private func updatePassthrough() {
        guard panel.isVisible, controller.shown else { panel.ignoresMouseEvents = true; controller.pointerInside = false; return }
        if NSEvent.pressedMouseButtons & 1 != 0, !panel.ignoresMouseEvents { return } // clic/glisser en cours
        let m = NSEvent.mouseLocation, f = panel.frame
        let local = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        // La fenêtre capte aussi une fine bande autour de la pilule (zone de prise pour la déplacer).
        let inside = controller.contentRect.insetBy(dx: -Self.outerBand, dy: -Self.outerBand).contains(local)
        // Main ouverte sur la zone de prise : on voit où attraper.
        let band = inDragBand(local) && !controller.grabberRect.insetBy(dx: -6, dy: -6).contains(local)
        if band != overBand {
            overBand = band
            if band { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        if controller.pointerInside != inside { controller.pointerChanged(inside: inside) }
        controller.pointerInside = inside
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
            dlog(String(format: "souris %@ (zone %@)", inside ? "dedans" : "dehors", NSStringFromRect(controller.contentRect)))
        }
    }

    // MARK: Position

    /// Trait du bas : glisser vers le bas rallonge la pilule, vers le haut la raccourcit (le haut ne bouge pas).
    /// Suivi exact de la souris, résistance élastique au-delà des limites, petit rebond au lâcher.
    private func grabberDown(_ event: NSEvent) {
        let start = NSEvent.mouseLocation.y
        let startExtra = controller.extraHeight
        // Limites selon ce qui reste visible :
        // - au moins 140 pt de messages au-dessus de la zone de saisie (on ne peut pas tout masquer) ;
        // - le bas de la pilule ne descend pas sous le bas de l'écran (ni sous le Dock).
        let minVisibleMessages: CGFloat = 140
        let lo = minVisibleMessages - ConversationView.maxListHeight * controller.S
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let pillBottom = panel.frame.maxY - controller.contentRect.maxY // en coordonnées écran
        let room = pillBottom - (screen.visibleFrame.minY + 12)
        let hi = max(lo, min(startExtra + room, ChatController.maxExtraHeight))
        controller.isResizing = true
        panel.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { e, stop in
            guard let e else { return }
            let wanted = startExtra + (start - NSEvent.mouseLocation.y)
            // Élastique : au-delà des limites, la pilule ne suit plus qu'au tiers.
            let shown = wanted > hi ? hi + (wanted - hi) * 0.3 : (wanted < lo ? lo + (wanted - lo) * 0.3 : wanted)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { self.controller.extraHeight = shown }
            if e.type == .leftMouseUp {
                stop.pointee = true
                self.controller.isResizing = false
                let final = min(max(wanted, lo), hi)
                UserDefaults.standard.set(Double(final), forKey: "extraHeight")
                // Retour à la limite (si on l'a dépassée) + petit rebond vertical de toute la pilule.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { self.controller.extraHeight = final }
                self.controller.squash = CGSize(width: 0.998, height: 1.008)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    self.controller.squash = CGSize(width: 1, height: 1)
                }
            }
        }
    }

    /// Comme PillMusic : la pilule lâchée trop près d'un bord revient dans l'écran (jusque dans les coins,
    /// jamais au-delà), avec un petit rebond.
    private var userMoved = false

    private func keepOnScreen() {
        // Taille de la pilule pas encore connue : on ne touche à rien.
        guard controller.contentRect.width > 10, controller.contentRect.height > 10 else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var f = panel.frame
        let local = controller.contentRect
        let pill = CGRect(x: f.minX + local.minX, y: f.maxY - local.maxY, width: local.width, height: local.height)
        let e: CGFloat = 8
        var shift = CGPoint.zero
        if pill.minX < visible.minX + e { shift.x = visible.minX + e - pill.minX }
        if pill.maxX > visible.maxX - e { shift.x = visible.maxX - e - pill.maxX }
        if pill.maxY > visible.maxY - e { shift.y = visible.maxY - e - pill.maxY }
        if pill.minY < visible.minY + e { shift.y = visible.minY + e - pill.minY }
        guard shift != .zero else { return }
        f.origin.x += shift.x
        f.origin.y += shift.y
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            panel.animator().setFrame(f, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.savePosition() }
    }

    /// Largeur de la bande, sur le pourtour de la pilule, qui sert à la déplacer.
    static let borderBand: CGFloat = 16
    /// Bande invisible à l'extérieur de la pilule, elle aussi attrapable.
    static let outerBand: CGFloat = 12
    private var overBand = false

    /// Zone de prise : le pourtour de la pilule, à cheval sur son bord (dedans et juste autour).
    private func inDragBand(_ p: CGPoint) -> Bool {
        let r = controller.contentRect
        return r.insetBy(dx: -Self.outerBand, dy: -Self.outerBand).contains(p)
            && !r.insetBy(dx: Self.borderBand, dy: Self.borderBand).contains(p)
    }

    private var windowSize: CGSize {
        let s = size.scale
        // Marges sous la pilule (zone transparente, la souris la traverse) : champ qui s'agrandit
        // et agrandissement par le trait du bas.
        return CGSize(width: D.width * s + RootView.margin * 2,
                      height: (D.tallHeight + 160) * s + ChatController.maxExtraHeight + RootView.margin * 2)
    }

    /// Coin haut droit de l'écran par défaut (comme les notifs), sinon la dernière position.
    private func layoutWindow() {
        let w = windowSize
        // L'écran où se trouve la souris (avec plusieurs écrans, NSScreen.main n'est pas forcément celui qu'on regarde).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var topRight = CGPoint(x: vf.maxX - 12 + RootView.margin, y: vf.maxY - 12 + RootView.margin)
        if defaults.object(forKey: "topRightX") != nil {
            let p = CGPoint(x: defaults.double(forKey: "topRightX"), y: defaults.double(forKey: "topRightY"))
            // Position gardée seulement si la fenêtre reste bien visible sur un écran.
            let card = CGRect(x: p.x - RootView.margin - D.width * size.scale, y: p.y - RootView.margin - 80,
                              width: D.width * size.scale, height: 80)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(card) }) { topRight = p }
        }
        panel.setFrame(NSRect(x: topRight.x - w.width, y: topRight.y - w.height, width: w.width, height: w.height), display: true)
    }

    private func savePosition() {
        defaults.set(Double(panel.frame.maxX), forKey: "topRightX")
        defaults.set(Double(panel.frame.maxY), forKey: "topRightY")
    }

    private func registerFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    // MARK: Menu clic droit

    // MARK: Icône dans la barre des menus

    /// Clic : écrire à quelqu'un (les cercles). Clic droit ou ⌥-clic : le menu.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "PillChat")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "PillChat — écrire à quelqu'un (⌃⌘R)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        statusItem = item
        // Nombre de messages non lus à côté de l'icône.
        store.$unreadTotal.removeDuplicates().sink { [weak self] n in
            guard let button = self?.statusItem?.button else { return }
            button.title = n > 0 ? (n > 99 ? " 99+" : " \(n)") : ""
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }.store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            guard let item = statusItem else { return }
            item.menu = buildMenu()
            item.button?.performClick(nil)
            item.menu = nil // le clic gauche doit rester une action, pas un menu
        } else if controller.shown {
            controller.hide() // clic sur l'icône : masquer la pilule
        } else {
            controller.openPicker()
        }
    }

    private func showMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: host)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let new = ActionItem("Écrire à quelqu'un") { [weak self] in self?.controller.openPicker() }
        let hidePill = ActionItem("Masquer la pilule") { [weak self] in self?.controller.hide() }
        new.keyEquivalent = "r"; new.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(new)
        if controller.shown { menu.addItem(hidePill) }
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for s in ChatSize.allCases {
            let item = ActionItem(s.label) { [weak self] in
                guard let self else { return }
                self.size = s
                self.controller.S = s.scale
                self.defaults.removeObject(forKey: "topRightX")
                self.layoutWindow()
                self.controller.objectWillChange.send()
            }
            item.state = size == s ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Taille", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let lookMenu = NSMenu()
        for (key, label) in [("system", "Comme le Mac"), ("light", "Clair"), ("dark", "Sombre")] {
            let item = ActionItem(label) { [weak self] in self?.appearance = key }
            item.state = appearance == key ? .on : .off
            lookMenu.addItem(item)
        }
        let lookItem = NSMenuItem(title: "Apparence", action: nil, keyEquivalent: "")
        lookItem.submenu = lookMenu
        menu.addItem(lookItem)
        menu.addItem(ActionItem("Remettre en haut à droite") { [weak self] in
            self?.defaults.removeObject(forKey: "topRightX"); self?.layoutWindow()
        })
        menu.addItem(.separator())

        let keep = ActionItem("Garder Messages ouverte") { [weak self] in
            guard let self else { return }
            self.keepMessagesOpen.toggle()
            if self.keepMessagesOpen { Sender.ensureMessagesRunning() }
        }
        keep.state = keepMessagesOpen ? .on : .off
        menu.addItem(keep)
        menu.addItem(ActionItem("Couper les notifs de Messages…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.apple.MobileSMS")!)
        })
        let login = ActionItem("Ouvrir au démarrage") { Self.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quitter PillChat") { NSApp.terminate(nil) })

        return menu
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossible de modifier l'ouverture au démarrage"
            alert.informativeText = "Place PillChat dans le dossier Applications puis réessaie.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
