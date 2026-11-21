import AppKit
import SwiftUI

/// Les 9 emojis du bas de la conversation, choisis par l'utilisateur (gardés dans les réglages).
final class EmojiPrefs: ObservableObject {
    static let shared = EmojiPrefs()
    static let count = 9
    private static let key = "quickEmojis"

    @Published var emojis: [String] {
        didSet { UserDefaults.standard.set(emojis, forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        emojis = saved.count == Self.count ? saved : D.reactions
    }

    func reset() { emojis = D.reactions }
}

extension Character {
    /// Un vrai emoji (pas un chiffre ni un # qui ont aussi la propriété « emoji » en Unicode).
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

// MARK: - Petite fenêtre de choix

/// Ouvre (ou ramène devant) la fenêtre « Choisir les emojis ».
final class EmojiSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 370),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Emojis de la conversation"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EmojiSettingsView(prefs: .shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true) // sinon on ne peut pas taper d'emoji dans la fenêtre
        window?.makeKeyAndOrderFront(nil)
    }
}

struct EmojiSettingsView: View {
    @ObservedObject var prefs: EmojiPrefs
    // (pas de @State : les macros SwiftUI ne sont pas dispo sans Xcode — même astuce que le reste de l'app)
    private let _selectedBox = State<Int>(initialValue: 0)
    private var selected: Int { get { _selectedBox.wrappedValue } nonmutating set { _selectedBox.wrappedValue = newValue } }
    private let _typedBox = State<String>(initialValue: "")
    private var typed: String { get { _typedBox.wrappedValue } nonmutating set { _typedBox.wrappedValue = newValue } }
    @FocusState private var typing: Bool

    /// Suggestions à cliquer (en plus de tous les emojis du clavier de macOS).
    private static let suggestions: [String] = [
        "😂", "🥹", "😍", "🥰", "😘", "😎", "🤩", "😭", "😅", "🙃", "😏", "🤪",
        "🤔", "🫠", "😴", "🤯", "😡", "🥶", "🤮", "💀", "👻", "👽", "🤖", "🧟",
        "❤️", "💜", "💙", "🖤", "💔", "🔥", "✨", "⭐️", "🌶️", "🍿", "🍕", "🍻",
        "👍", "👎", "👏", "🙏", "💪", "🤘🏿", "✌️", "👀", "🫶", "🤝", "💯", "🎉",
        "🐤", "🐶", "🐱", "🦄", "🐸", "🙈", "🌈", "☀️", "🌙", "⚡️", "🎶", "🚀",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clique une case, puis choisis son emoji.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Les 9 emojis actuels, dans l'ordre de la pilule.
            HStack(spacing: 8) {
                ForEach(0..<EmojiPrefs.count, id: \.self) { i in
                    Button { selected = i } label: {
                        Text(prefs.emojis[i])
                            .font(.system(size: 26))
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected == i ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(selected == i ? Color.accentColor : .clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Suggestions : un clic remplace la case choisie et passe à la suivante.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 12), spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { e in
                    Button { put(e) } label: {
                        Text(e).font(.system(size: 22)).frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // N'importe quel autre emoji : le taper ou le prendre dans le visualiseur de macOS.
            HStack(spacing: 8) {
                TextField("Ou tape / colle un emoji", text: _typedBox.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .frame(width: 190)
                    .onChange(of: typed) {
                        if let e = typed.last(where: \.isEmoji) { put(String(e)) }
                        if !typed.isEmpty { typed = "" }
                    }
                Button("Tous les emojis…") {
                    typing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.orderFrontCharacterPalette(nil) }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Remettre ceux d'origine") { prefs.reset(); selected = 0 }
                Spacer()
                Button("OK") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 370)
    }

    private func put(_ emoji: String) {
        var list = prefs.emojis
        list[selected] = emoji
        prefs.emojis = list
        selected = (selected + 1) % EmojiPrefs.count
    }
}
