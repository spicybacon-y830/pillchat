// Fabrique l'icône macOS (gabarit Apple : carré arrondi 824/1024, centré) à partir d'une image carrée.
// Usage : swift icon/make-icon.swift icon/source.png sortie-1024.png
import AppKit

let args = CommandLine.arguments
guard let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let size = 1024, body: CGFloat = 824, radius: CGFloat = 185
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: (CGFloat(size) - body) / 2, y: (CGFloat(size) - body) / 2 + 10, width: body, height: body)
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
// Ombre portée discrète, comme les icônes système.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(shape); ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(src, in: rect)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
