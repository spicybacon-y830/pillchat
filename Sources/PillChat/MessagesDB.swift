import Foundation
import SQLite3

// MARK: - Modèle

struct Attachment: Equatable, Hashable {
    enum Kind { case image, audio, video, file }
    let path: String
    let mime: String
    let name: String

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var kind: Kind {
        let ext = (name.isEmpty ? path : name).split(separator: ".").last.map { $0.lowercased() } ?? ""
        if mime.hasPrefix("image") || ["heic", "jpg", "jpeg", "png", "gif", "webp"].contains(ext) { return .image }
        if mime.hasPrefix("audio") || ["caf", "m4a", "amr", "mp3", "aac", "wav"].contains(ext) { return .audio }
        if mime.hasPrefix("video") || ["mov", "mp4", "m4v"].contains(ext) { return .video }
        return .file
    }
}

struct Reaction: Equatable, Hashable {
    let emoji: String
    let fromMe: Bool
}

struct Message: Identifiable, Equatable {
    let id: Int64
    let text: String
    let fromMe: Bool
    let date: Date
    let handle: String?
    let chatID: Int64
    /// Envoyé depuis PillChat, pas encore confirmé par la base.
    var pending = false
    var failed = false
    var attachments: [Attachment] = []
    var guid = ""
    /// Identité à l'écran : reste celle de la bulle « en cours d'envoi » quand le vrai message la remplace
    /// (sinon la liste rejoue l'apparition et la bulle clignote).
    var uiID: Int64 = 0
    var listID: Int64 { uiID != 0 ? uiID : id }
    /// Réactions (tapbacks) posées sur ce message.
    var reactions: [Reaction] = []
    /// Accusés de réception (messages envoyés uniquement).
    var delivered = false
    var readAt: Date?

    /// Clé pour rapprocher une bulle « en cours d'envoi » du vrai message arrivé dans la base.
    var matchKey: String { text + "|" + attachments.map { "\($0.kind)" }.joined(separator: ",") }

    /// Texte court pour une notif ou une recherche.
    var summary: String {
        if !text.isEmpty { return text }
        switch attachments.first?.kind {
        case .audio: return "🎤 Message vocal"
        case .image: return "📷 Photo"
        case .video: return "🎬 Vidéo"
        default: return "📎 Pièce jointe"
        }
    }
}

struct ChatRow: Equatable {
    let id: Int64
    let guid: String
    let identifier: String
    let displayName: String?
    let handles: [String]
    let isGroup: Bool
}

enum DBError: Error { case noAccess, failed(String) }

// MARK: - Lecture de ~/Library/Messages/chat.db (lecture seule)

/// Toujours utilisé depuis la même file (voir `MessagesStore`).
final class MessagesDB {
    private var db: OpaquePointer?

    static let path = NSHomeDirectory() + "/Library/Messages/chat.db"

    func open() throws {
        guard db == nil else { return }
        // Sans l'accès complet au disque, macOS refuse jusqu'à la lecture du fichier.
        guard FileManager.default.isReadableFile(atPath: Self.path) else { throw DBError.noAccess }
        var handle: OpaquePointer?
        let uri = "file:\(Self.path)?mode=ro"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw rc == SQLITE_AUTH || rc == SQLITE_CANTOPEN || rc == SQLITE_PERM ? DBError.noAccess : DBError.failed("open \(rc)")
        }
        sqlite3_busy_timeout(handle, 500)
        db = handle
        // Vérifie qu'on lit vraiment (sinon l'erreur n'apparaît qu'à la première requête).
        do { _ = try latestRowID() } catch { close(); throw DBError.noAccess }
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    deinit { close() }

    // MARK: Requêtes

    /// Diagnostic : colonnes de la base qui pourraient porter l'indicateur « en train d'écrire ».
    func logSchemaHints() {
        for table in ["message", "chat"] {
            var cols: [String] = []
            try? query("PRAGMA table_info(\(table))") { s in if let n = Self.string(s, 1) { cols.append(n) } }
            dlog("colonnes \(table) : \(cols.joined(separator: ", "))")
        }
    }

    func latestRowID() throws -> Int64 {
        var id: Int64 = 0
        try query("SELECT IFNULL(MAX(ROWID), 0) FROM message") { id = sqlite3_column_int64($0, 0) }
        return id
    }

    private static let messageColumns = """
        m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date, h.id, cmj.chat_id, m.cache_has_attachments,
        m.is_delivered, m.date_read, m.guid
        """

    /// Nouveaux messages (texte ou pièce jointe), sans les réactions ni les événements de groupe.
    func messages(after rowID: Int64) throws -> [Message] {
        let sql = """
            SELECT \(Self.messageColumns)
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.ROWID > ? AND m.associated_message_type = 0 AND m.item_type = 0
            ORDER BY m.ROWID ASC LIMIT 100
            """
        var out: [Message] = []
        try query(sql, bind: { sqlite3_bind_int64($0, 1, rowID) }) { s in
            if let m = self.message(from: s) { out.append(m) }
        }
        return out
    }

    /// Nombre de messages reçus non lus dans la conversation.
    func unreadCount(chatID: Int64) throws -> Int {
        var n = 0
        try query("""
            SELECT COUNT(*) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ? AND m.is_from_me = 0 AND m.is_read = 0 AND m.item_type = 0 AND m.associated_message_type = 0
            """, bind: { sqlite3_bind_int64($0, 1, chatID) }) { n = Int(sqlite3_column_int($0, 0)) }
        return n
    }

    func history(chatID: Int64, limit: Int = 30) throws -> [Message] {
        let sql = """
            SELECT \(Self.messageColumns)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
            ORDER BY m.date DESC LIMIT ?
            """
        var out: [Message] = []
        try query(sql, bind: { sqlite3_bind_int64($0, 1, chatID); sqlite3_bind_int($0, 2, Int32(limit)) }) { s in
            if let m = self.message(from: s) { out.append(m) }
        }
        return out.reversed()
    }

    /// Dernier message envoyé dans la conversation (pour suivre « Distribué » / « Lu »).
    func lastOutgoing(chatID: Int64) throws -> Message? {
        let sql = """
            SELECT \(Self.messageColumns)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.is_from_me = 1 AND m.associated_message_type = 0 AND m.item_type = 0
            ORDER BY m.date DESC LIMIT 1
            """
        var out: Message?
        try query(sql, bind: { sqlite3_bind_int64($0, 1, chatID) }) { s in out = self.message(from: s) }
        return out
    }

    /// Messages reçus non lus (30 derniers jours), pour le compteur de la barre des menus.
    /// `excluding` : conversations déjà vues dans PillChat (jusqu'à tel message) qui ne comptent plus.
    func unreadTotal(excluding seen: [Int64: Int64] = [:]) throws -> Int {
        let since = Int64((Date().timeIntervalSinceReferenceDate - 30 * 86_400) * 1_000_000_000)
        var n = 0
        try query("""
            SELECT cmj.chat_id, m.ROWID FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.is_from_me = 0 AND m.is_read = 0 AND m.item_type = 0 AND m.associated_message_type = 0 AND m.date > ?
            """, bind: { sqlite3_bind_int64($0, 1, since) }) { s in
            let chat = sqlite3_column_int64(s, 0), id = sqlite3_column_int64(s, 1)
            if id > (seen[chat] ?? 0) { n += 1 }
        }
        return n
    }

    /// Dernière réaction enregistrée (toutes conversations) : sert à repérer les nouvelles.
    func latestReactionRowID() throws -> Int64 {
        var id: Int64 = 0
        try query("SELECT IFNULL(MAX(ROWID), 0) FROM message WHERE associated_message_type BETWEEN 2000 AND 3007") {
            id = sqlite3_column_int64($0, 0)
        }
        return id
    }

    /// Réactions de la conversation, par guid du message visé (ajouts et retraits rejoués dans l'ordre).
    func reactions(chatID: Int64) throws -> [String: [Reaction]] {
        let sql = """
            SELECT m.associated_message_guid, m.associated_message_type, m.is_from_me,
                   IFNULL(m.associated_message_emoji, ''), IFNULL(h.id, '')
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.associated_message_type BETWEEN 2000 AND 3007
            ORDER BY m.date ASC
            """
        // cible → (personne → réaction)
        var state: [String: [String: Reaction]] = [:]
        let classic = [0: "❤️", 1: "👍", 2: "👎", 3: "😂", 4: "‼️", 5: "❓"]
        try query(sql, bind: { sqlite3_bind_int64($0, 1, chatID) }) { s in
            guard var target = Self.string(s, 0) else { return }
            // « p:0/GUID » ou « bp:GUID » → GUID
            if let slash = target.lastIndex(of: "/") { target = String(target[target.index(after: slash)...]) }
            if target.hasPrefix("bp:") { target = String(target.dropFirst(3)) }
            let type = Int(sqlite3_column_int(s, 1))
            let fromMe = sqlite3_column_int(s, 2) != 0
            let who = fromMe ? "moi" : (Self.string(s, 4) ?? "?")
            let kind = type % 1000
            if type >= 3000 { state[target]?[who] = nil; return } // réaction retirée
            let emoji = kind == 6 ? (Self.string(s, 3) ?? "") : (classic[kind] ?? "")
            guard !emoji.isEmpty else { return }
            state[target, default: [:]][who] = Reaction(emoji: emoji, fromMe: fromMe)
        }
        return state.mapValues { Array($0.values).sorted { !$0.fromMe && $1.fromMe } }
    }

    func chat(id: Int64) throws -> ChatRow? {
        var row: ChatRow?
        try query("SELECT ROWID, guid, chat_identifier, display_name, style FROM chat WHERE ROWID = ?",
                  bind: { sqlite3_bind_int64($0, 1, id) }) { s in
            row = ChatRow(id: sqlite3_column_int64(s, 0), guid: Self.string(s, 1) ?? "", identifier: Self.string(s, 2) ?? "",
                          displayName: Self.string(s, 3).flatMap { $0.isEmpty ? nil : $0 }, handles: [],
                          isGroup: sqlite3_column_int(s, 4) == 43)
        }
        guard let r = row else { return nil }
        var handles: [String] = []
        try query("SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = ?",
                  bind: { sqlite3_bind_int64($0, 1, id) }) { s in
            if let h = Self.string(s, 0) { handles.append(h) }
        }
        return ChatRow(id: r.id, guid: r.guid, identifier: r.identifier, displayName: r.displayName,
                       handles: handles.isEmpty ? [r.identifier] : handles, isGroup: r.isGroup)
    }

    /// Conversations les plus récentes d'abord.
    func recentChatIDs(limit: Int) throws -> [Int64] {
        let sql = """
            SELECT cmj.chat_id FROM chat_message_join cmj
            GROUP BY cmj.chat_id ORDER BY MAX(cmj.message_date) DESC LIMIT ?
            """
        var ids: [Int64] = []
        try query(sql, bind: { sqlite3_bind_int($0, 1, Int32(limit)) }) { ids.append(sqlite3_column_int64($0, 0)) }
        return ids
    }

    // MARK: Aides

    private func message(from s: OpaquePointer) -> Message? {
        let id = sqlite3_column_int64(s, 0)
        var text = Self.string(s, 1) ?? ""
        if text.isEmpty, let blob = Self.blob(s, 2) { text = Self.decodeAttributedBody(blob) ?? "" }
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = sqlite3_column_int(s, 7) != 0 ? attachments(messageID: id) : []
        guard !text.isEmpty || !atts.isEmpty else { return nil }
        return Message(id: id, text: text, fromMe: sqlite3_column_int(s, 3) != 0,
                       date: Self.date(sqlite3_column_int64(s, 4)), handle: Self.string(s, 5),
                       chatID: sqlite3_column_int64(s, 6), attachments: atts,
                       guid: Self.string(s, 10) ?? "",
                       delivered: sqlite3_column_int(s, 8) != 0,
                       readAt: sqlite3_column_int64(s, 9) > 0 ? Self.date(sqlite3_column_int64(s, 9)) : nil)
    }

    private func attachments(messageID: Int64) -> [Attachment] {
        var out: [Attachment] = []
        try? query("""
            SELECT IFNULL(a.filename, ''), IFNULL(a.mime_type, ''), IFNULL(a.transfer_name, '') FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID WHERE maj.message_id = ?
            """, bind: { sqlite3_bind_int64($0, 1, messageID) }) { s in
            let raw = Self.string(s, 0) ?? ""
            let name = Self.string(s, 2) ?? ""
            guard !raw.isEmpty, !raw.hasSuffix("pluginPayloadAttachment"), !name.hasSuffix("pluginPayloadAttachment") else { return }
            out.append(Attachment(path: (raw as NSString).expandingTildeInPath, mime: Self.string(s, 1) ?? "", name: name))
        }
        return out
    }

    private func query(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil, row: (OpaquePointer) -> Void) throws {
        guard let db else { throw DBError.noAccess }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw msg.contains("authorization") ? DBError.noAccess : DBError.failed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw DBError.failed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func string(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }

    /// Dates Apple : depuis 2001, en nanosecondes depuis macOS 10.13 (en secondes avant).
    static func date(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Les macOS récents ne remplissent plus `text` : le contenu est dans `attributedBody`,
    /// une NSAttributedString archivée (format « typedstream »). On extrait la chaîne
    /// à la main plutôt que de désarchiver des objets.
    static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count,
              let start = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<$0 + marker.count]) == marker })
        else { return nil }
        // Après la classe viennent quelques octets de type, puis '+' et la longueur.
        var i = start + marker.count
        let limit = min(i + 12, bytes.count)
        while i < limit, bytes[i] != 0x2B { i += 1 }
        guard i < limit else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i]); i += 1
        if length == 0x81 {
            guard i + 2 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
        } else if length == 0x82 {
            guard i + 4 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24; i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<i + length], encoding: .utf8)
    }
}
