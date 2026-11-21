import AppKit

/// Envoi par AppleScript : Messages.app fait le vrai travail, en arrière-plan.
/// La réception, elle, ne dépend pas de Messages : le service système (imagent) écrit chat.db même app fermée.
enum Sender {
    /// Messages lancée par PillChat juste pour envoyer : on la referme ensuite (sauf « Garder Messages ouverte »).
    static var autoQuit = true
    private static var launchedByUs = false
    private static var quitWork: DispatchWorkItem?
    /// Délai après le dernier envoi avant de refermer Messages (le temps que le message parte vraiment).
    static let quitDelay: TimeInterval = 20

    private static let queue = DispatchQueue(label: "pillchat.applescript", qos: .userInitiated)
    static let messagesID = "com.apple.MobileSMS"

    static func send(text: String, to chat: ChatInfo, completion: @escaping (Bool) -> Void) {
        let body = escape(text)
        var scripts = ["tell application \"Messages\" to send \"\(body)\" to chat id \"\(escape(chat.guid))\""]
        if !chat.isGroup, let handle = chat.handles.first {
            // Si l'identifiant de conversation n'est pas reconnu, on passe par le destinataire.
            scripts.append("""
                tell application "Messages"
                    set s to 1st account whose service type = iMessage
                    send "\(body)" to participant "\(escape(handle))" of s
                end tell
                """)
        }
        run(scripts, completion: completion)
    }

    static func send(file: URL, to chat: ChatInfo, completion: @escaping (Bool) -> Void) {
        let script = """
            set f to (POSIX file "\(escape(file.path))") as alias
            tell application "Messages" to send f to chat id "\(escape(chat.guid))"
            """
        run([script], completion: completion)
    }

    private static func run(_ sources: [String], completion: @escaping (Bool) -> Void) {
        quitWork?.cancel()
        let wasRunning = messagesRunning
        if !wasRunning { launchedByUs = true }
        ensureMessagesRunning()
        queue.async {
            // Messages fermée : on attend qu'elle ait fini de s'ouvrir (masquée) avant le script.
            // Sinon « tell application "Messages" » la lance lui-même, au premier plan, fenêtre ouverte.
            if !wasRunning { waitForMessages() }
            var ok = false
            for source in sources {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if error == nil { ok = true; dlog("envoyé"); break }
                dlog("échec d'envoi \(String(describing: error?[NSAppleScript.errorNumber])) \(String(describing: error?[NSAppleScript.errorMessage]))")
            }
            DispatchQueue.main.async {
                if launchedByUs { hideMessages() } // au cas où sa fenêtre serait apparue quand même
                completion(ok); scheduleQuit()
            }
        }
    }

    /// Referme Messages un peu après le dernier envoi, si c'est PillChat qui l'a ouverte
    /// et que tu ne l'utilises pas (pas au premier plan).
    private static func scheduleQuit() {
        quitWork?.cancel()
        guard autoQuit, launchedByUs else { return }
        let work = DispatchWorkItem {
            guard autoQuit, launchedByUs else { return }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: messagesID)
            if apps.contains(where: \.isActive) { launchedByUs = false; return } // tu t'en sers : on n'y touche pas
            dlog("fermeture de Messages (ouverte pour l'envoi)")
            launchedByUs = false
            apps.forEach { $0.terminate() }
        }
        quitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quitDelay, execute: work)
    }

    /// Chaîne AppleScript : seuls `\` et `"` doivent être échappés.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static var messagesRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: messagesID).isEmpty
    }

    /// Attend (au plus 10 s) que Messages ait fini de s'ouvrir, puis la masque.
    private static func waitForMessages() {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: messagesID).first,
               app.isFinishedLaunching { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        DispatchQueue.main.sync { hideMessages() }
        Thread.sleep(forTimeInterval: 0.5) // le temps que Messages accepte les commandes AppleScript
    }

    /// Masque Messages sans la fermer (ouverte par PillChat : même si elle s'est mise au premier plan).
    private static func hideMessages() {
        NSRunningApplication.runningApplications(withBundleIdentifier: messagesID).forEach { $0.hide() }
    }

    /// Lance Messages masquée si elle est fermée : sans elle, rien ne part.
    static func ensureMessagesRunning() {
        guard !messagesRunning,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
