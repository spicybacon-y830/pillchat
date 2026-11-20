import AppKit
import Combine

struct ChatInfo: Identifiable, Equatable {
    let id: Int64
    let guid: String
    let name: String
    let handles: [String]
    let isGroup: Bool
    let image: NSImage?

    var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "#" : letters.uppercased()
    }

    static func == (a: ChatInfo, b: ChatInfo) -> Bool {
        a.id == b.id && a.name == b.name && (a.image == nil) == (b.image == nil)
    }
}

enum Access: Equatable { case unknown, granted, denied }

/// Dernier échange d'une conversation, pour la bulle d'aperçu sur les cercles.
struct ChatPreview: Equatable {
    let excerpt: String
    /// Le dernier message vient de l'autre personne (sinon : pas de bulle, on a déjà répondu).
    let received: Bool
    let unread: Bool
}

/// Surveille chat.db et publie les nouveaux messages. Toute la lecture SQLite se fait sur `queue`.
final class MessagesStore: ObservableObject {
    @Published private(set) var access: Access = .unknown
    /// Conversations récentes (pour la recherche), les plus récentes d'abord.
    @Published private(set) var recents: [ChatInfo] = []
    @Published private(set) var previews: [Int64: ChatPreview] = [:]
    /// Conversations dont le dernier message reçu n'est pas lu (pastille dans la barre des menus).
    @Published private(set) var unreadChats = 0
    /// Nombre de messages non lus (affiché à côté de l'icône de la barre des menus).
    @Published private(set) var unreadTotal = 0
    private var unreadTick = 0

    /// Chaque nouveau message (reçu ou envoyé), sur le thread principal.
    var onMessage: ((Message, ChatInfo) -> Void)?
    /// État à jour du dernier message envoyé dans la conversation ouverte.
    var onReceipt: ((Message) -> Void)?
    /// Réactions à jour de la conversation ouverte (par guid de message).
    var onReactions: ((Int64, [String: [Reaction]]) -> Void)?
    private var lastReactionRow: Int64 = -1
    /// Conversation ouverte à l'écran (lue / écrite uniquement sur `queue`).
    private var watchedChat: Int64?
    private var lastReceipt: (Int64, Bool, Date?)?

    func watch(_ chatID: Int64?) { queue.async { self.watchedChat = chatID; self.lastReceipt = nil } }

    let contacts = ContactBook()
    private let db = MessagesDB()
    private let queue = DispatchQueue(label: "pillchat.db", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastRowID: Int64 = -1
    private var chatCache: [Int64: ChatInfo] = [:] // uniquement sur `queue`

    func start() {
        contacts.load { [weak self] in
            self?.queue.async {
                self?.chatCache.removeAll()
                self?.loadRecents()
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Une requête indexée par seconde : coût négligeable, et pas de fichier à surveiller
        // (le WAL de Messages est recréé régulièrement).
        t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func retryNow() { queue.async { self.tick() } }

    // MARK: Conversations vues dans PillChat

    /// Dernier message vu par conversation (retenu entre les lancements). Uniquement sur `queue`.
    private var seen: [Int64: Int64] = {
        let raw = UserDefaults.standard.dictionary(forKey: "seenUpTo") as? [String: Int64] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int64(k).map { ($0, v) } })
    }()

    /// La conversation a été vue jusqu'à ce message : sa bulle d'aperçu et ses non-lus disparaissent.
    func markSeen(chatID: Int64, upTo messageID: Int64) {
        guard messageID > 0 else { return }
        queue.async {
            guard (self.seen[chatID] ?? 0) < messageID else { return }
            self.seen[chatID] = messageID
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: self.seen.map { (String($0.key), $0.value) }),
                                      forKey: "seenUpTo")
            self.loadRecents()
            if let n = try? self.db.unreadTotal(excluding: self.seen) {
                DispatchQueue.main.async { self.unreadTotal = n }
            }
        }
    }

    private func tick() {
        do {
            try db.open()
            if lastRowID < 0 {
                lastRowID = try db.latestRowID() // pas de rattrapage : seulement ce qui arrive après le lancement
                setAccess(.granted)
                db.logSchemaHints()
                loadRecents()
                return
            }
            // « Distribué » / « Lu » changent sans nouveau message : on relit le dernier envoi de la conversation ouverte.
            if let chatID = watchedChat, let out = try db.lastOutgoing(chatID: chatID) {
                let state = (out.id, out.delivered, out.readAt)
                if lastReceipt.map({ $0.0 != state.0 || $0.1 != state.1 || $0.2 != state.2 }) ?? true {
                    lastReceipt = state
                    DispatchQueue.main.async { self.onReceipt?(out) }
                }
            }
            // Compteur de non-lus : toutes les 3 secondes (la lecture sur l'iPhone ou le Mac le fait baisser).
            unreadTick += 1
            if unreadTick % 3 == 1, let n = try? db.unreadTotal(excluding: seen) {
                DispatchQueue.main.async { if self.unreadTotal != n { self.unreadTotal = n } }
            }
            // Nouvelles réactions (tapbacks) : on recharge celles de la conversation ouverte.
            let reactionRow = try db.latestReactionRowID()
            if reactionRow != lastReactionRow {
                if lastReactionRow >= 0, let chatID = watchedChat {
                    let map = try db.reactions(chatID: chatID)
                    DispatchQueue.main.async { self.onReactions?(chatID, map) }
                }
                lastReactionRow = reactionRow
            }
            let fresh = try db.messages(after: lastRowID)
            guard let last = fresh.last else { return }
            lastRowID = max(lastRowID, last.id)
            var touched = false
            for m in fresh {
                guard let chat = chatInfo(m.chatID) else { continue }
                touched = true
                DispatchQueue.main.async { self.onMessage?(m, chat) }
            }
            if touched { loadRecents() }
        } catch DBError.noAccess {
            db.close()
            setAccess(.denied)
        } catch {
            db.close() // réessaie au prochain tour
        }
    }

    private func setAccess(_ a: Access) {
        dlog("accès à chat.db : \(a)")
        DispatchQueue.main.async { if self.access != a { self.access = a } }
    }

    private func loadRecents() {
        guard let ids = try? db.recentChatIDs(limit: 300) else { return }
        let chats = ids.compactMap(chatInfo)
        var previews: [Int64: ChatPreview] = [:]
        for chat in chats.prefix(30) {
            guard let last = (try? db.history(chatID: chat.id, limit: 1))?.last else { continue }
            // Déjà vu dans PillChat : plus de bulle d'aperçu (Messages ne le sait pas, on le retient nous-mêmes).
            let seenHere = (seen[chat.id] ?? 0) >= last.id
            let unread = !last.fromMe && !seenHere && ((try? db.unreadCount(chatID: chat.id)) ?? 0) > 0
            previews[chat.id] = ChatPreview(excerpt: last.summary.replacingOccurrences(of: "\n", with: " "),
                                            received: !last.fromMe && !seenHere, unread: unread)
        }
        let unread = previews.values.filter(\.unread).count
        DispatchQueue.main.async {
            self.recents = chats
            if self.previews != previews { self.previews = previews }
            if self.unreadChats != unread { self.unreadChats = unread }
        }
    }

    private func chatInfo(_ id: Int64) -> ChatInfo? {
        if let c = chatCache[id] { return c }
        guard let row = try? db.chat(id: id) else { return nil }
        let entries = row.handles.map { contacts.lookup($0) }
        let name: String
        if let n = row.displayName {
            name = n
        } else if row.isGroup {
            name = zip(row.handles, entries).map { $1?.name.split(separator: " ").first.map(String.init) ?? ContactBook.pretty($0) }
                .joined(separator: ", ")
        } else {
            name = entries.first??.name ?? ContactBook.pretty(row.handles.first ?? row.identifier)
        }
        let info = ChatInfo(id: row.id, guid: row.guid, name: name, handles: row.handles, isGroup: row.isGroup,
                            image: row.isGroup ? nil : entries.first??.image)
        chatCache[id] = info
        return info
    }

    func history(for chat: ChatInfo, completion: @escaping ([Message]) -> Void) {
        queue.async {
            var msgs = (try? self.db.history(chatID: chat.id)) ?? []
            if let map = try? self.db.reactions(chatID: chat.id) {
                for i in msgs.indices { msgs[i].reactions = map[msgs[i].guid] ?? [] }
            }
            DispatchQueue.main.async { completion(msgs) }
        }
    }

    func search(_ text: String) -> [ChatInfo] {
        let q = text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return recents }
        let digits = q.filter(\.isNumber)
        return recents.filter { c in
            c.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
                || (digits.count >= 3 && c.handles.contains { $0.filter(\.isNumber).contains(digits) })
                || c.handles.contains { $0.lowercased().contains(q) }
        }
    }
}
