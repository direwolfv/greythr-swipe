import AppKit

func render(_ px: Int, to url: URL) {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: art sits inset with a ~22.37% corner radius
    let inset = s * 0.085
    let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237)
    let bg = NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.53, blue: 0.96, alpha: 1),
                        ending:   NSColor(srgbRed: 0.10, green: 0.33, blue: 0.80, alpha: 1))
    bg?.draw(in: squircle, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = sym.size
        let box = NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height)
        sym.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),
                   ("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),
                   ("512x512",512),("512x512@2x",1024)] {
    render(px, to: out.appendingPathComponent("icon_\(name).png"))
}
print("rendered 10 sizes")
