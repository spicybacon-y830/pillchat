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

// Vidéos de l'article : PillChat --demo <scène> <fond.jpg> <taille %> <x %> <y %> <sombre 0|1>
if args.count >= 2, args[1] == "--demo" {
    MainActor.assumeIsolated { Demo.run(args: args) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
delegate.applyDockPolicy() // icône dans le Dock (réglable dans le menu de la barre des menus)
app.run()
