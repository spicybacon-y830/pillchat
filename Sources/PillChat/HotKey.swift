import Carbon.HIToolbox
import Foundation

/// Raccourci clavier global (fonctionne quelle que soit l'app active, sans autorisation d'accessibilité).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// `character` est cherché dans la disposition du clavier actuelle (AZERTY, QWERTY…).
    init?(character: Character, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        guard let code = Self.keyCode(for: character) else { return nil }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)

        let id = EventHotKeyID(signature: OSType(0x50434854), id: 1) // 'PCHT'
        guard RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static func keyCode(for ch: Character) -> UInt16? {
        let target = String(ch).lowercased()
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return target == "r" ? UInt16(kVK_ANSI_R) : nil
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return UInt16(code)
                }
            }
            return nil
        }
    }
}
