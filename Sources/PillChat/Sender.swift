import AppKit

/// Envoi par AppleScript : Messages.app fait le vrai travail, en arrière-plan.
enum Sender {
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
        ensureMessagesRunning()
        queue.async {
            var ok = false
            for source in sources {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if error == nil { ok = true; dlog("envoyé"); break }
                dlog("échec d'envoi \(String(describing: error?[NSAppleScript.errorNumber])) \(String(describing: error?[NSAppleScript.errorMessage]))")
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Chaîne AppleScript : seuls `\` et `"` doivent être échappés.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static var messagesRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: messagesID).isEmpty
    }

    /// Lance Messages masquée si elle est fermée : sans elle, rien n'arrive et rien ne part.
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
