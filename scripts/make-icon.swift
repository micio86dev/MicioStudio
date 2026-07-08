// Generates app/Assets.xcassets/AppIcon.appiconset from the MicioDev logo with a
// small red webcam badge in the bottom-right. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let logoURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/logo_miciodev.jpg")
let outDir = root.appendingPathComponent("app/Assets.xcassets/AppIcon.appiconset")

guard let logo = NSImage(contentsOf: logoURL) else {
    FileHandle.standardError.write(Data("error: logo not found at \(logoURL.path)\n".utf8)); exit(1)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func renderPNG(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(px)

    // Base: the logo, filling the canvas.
    logo.draw(in: NSRect(x: 0, y: 0, width: s, height: s))

    // Red webcam badge, bottom-right — small but visible.
    let badge = s * 0.36
    let margin = s * 0.05
    let badgeRect = NSRect(x: s - badge - margin, y: margin, width: badge, height: badge)

    // subtle white ring for contrast on any background
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: -badge*0.045, dy: -badge*0.045)).fill()
    NSColor(calibratedRed: 0.86, green: 0.13, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()

    // White webcam glyph centered in the badge.
    let glyph = badge * 0.62
    let gRect = NSRect(x: badgeRect.midX - glyph/2, y: badgeRect.midY - glyph/2, width: glyph, height: glyph)
    let cfg = NSImage.SymbolConfiguration(paletteColors: [.white])
    if let sym = NSImage(systemSymbolName: "web.camera.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) ?? NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let ar = sym.size.width / max(sym.size.height, 1)
        var dr = gRect
        if ar > 1 { dr.size.height = glyph / ar; dr.origin.y = badgeRect.midY - dr.height/2 }
        else { dr.size.width = glyph * ar; dr.origin.x = badgeRect.midX - dr.width/2 }
        sym.draw(in: dr)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS icon set: idiom mac, sizes 16..512 at 1x/2x.
struct Entry { let size: Int; let scale: Int }
let entries = [Entry(size:16,scale:1),Entry(size:16,scale:2),Entry(size:32,scale:1),Entry(size:32,scale:2),
               Entry(size:128,scale:1),Entry(size:128,scale:2),Entry(size:256,scale:1),Entry(size:256,scale:2),
               Entry(size:512,scale:1),Entry(size:512,scale:2)]

var cache: [Int: Data] = [:]
var images: [[String:String]] = []
for e in entries {
    let px = e.size * e.scale
    let data = cache[px] ?? renderPNG(px)
    cache[px] = data
    let name = "icon_\(e.size)x\(e.size)@\(e.scale)x.png"
    try! data.write(to: outDir.appendingPathComponent(name))
    images.append(["idiom":"mac","size":"\(e.size)x\(e.size)","scale":"\(e.scale)x","filename":name])
}

let contents: [String:Any] = ["images": images, "info": ["version":1,"author":"xcode"]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted,.sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons + Contents.json to \(outDir.path)")
