import AppKit
import CoreText
import SwiftUI

let args = CommandLine.arguments

// Rendu de contrôle des écrans (données fictives) : PillChat --render sortie.png
if args.count >= 3, args[1] == "--render" {
    MainActor.assumeIsolated {
        if let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
            for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        Preview.render(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular) // icône dans le Dock (un clic ouvre la recherche)
app.run()
