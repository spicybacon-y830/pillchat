import AppKit
import Contacts

/// Noms et photos des contacts, retrouvés à partir des numéros / adresses de chat.db.
final class ContactBook {
    struct Entry {
        let name: String
        let image: NSImage?
    }

    private var byPhone: [String: Entry] = [:]
    private var byEmail: [String: Entry] = [:]
    private let lock = NSLock()

    func load(completion: @escaping () -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else { completion(); return }
            DispatchQueue.global(qos: .utility).async {
                self.build(store)
                completion()
            }
        }
    }

    private func build(_ store: CNContactStore) {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactNicknameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey,
        ].map { $0 as CNKeyDescriptor }
        var phones: [String: Entry] = [:], emails: [String: Entry] = [:]
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = !full.isEmpty ? full : (!c.nickname.isEmpty ? c.nickname : c.organizationName)
            guard !name.isEmpty else { return }
            let entry = Entry(name: name, image: c.thumbnailImageData.flatMap(NSImage.init(data:)))
            for p in c.phoneNumbers { phones[Self.phoneKey(p.value.stringValue)] = entry }
            for e in c.emailAddresses { emails[(e.value as String).lowercased()] = entry }
        }
        lock.lock(); byPhone = phones; byEmail = emails; lock.unlock()
    }

    func lookup(_ handle: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        if handle.contains("@") { return byEmail[handle.lowercased()] }
        return byPhone[Self.phoneKey(handle)]
    }

    /// Les 9 derniers chiffres : +33 6 12 34 56 78 et 06 12 34 56 78 donnent la même clé.
    static func phoneKey(_ raw: String) -> String {
        String(raw.filter(\.isNumber).suffix(9))
    }

    static func pretty(_ handle: String) -> String {
        guard !handle.contains("@") else { return handle }
        let digits = handle.filter(\.isNumber)
        if handle.hasPrefix("+33"), digits.count == 11 {
            let local = "0" + digits.dropFirst(2)
            return stride(from: 0, to: 10, by: 2).map { i in
                String(local[local.index(local.startIndex, offsetBy: i)..<local.index(local.startIndex, offsetBy: i + 2)])
            }.joined(separator: " ")
        }
        return handle
    }
}
