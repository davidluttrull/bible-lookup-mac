// Draws the app icon (the site's open-book mark on the header's charcoal) and writes
// Resources/AppIcon.icns.   Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func draw(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    // macOS icon grid: an 824 pt rounded square centred on a 1024 canvas, with a soft shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    color(0x5E5653).setFill()
    shape.fill()
    ctx.restoreGState()
    ctx.saveGState()
    shape.addClip()
    NSGradient(starting: color(0x6E6562), ending: color(0x4A4341))!.draw(in: body, angle: -90)
    // the header's taupe underline, as a band near the bottom
    color(0xAB978C).setFill()
    NSBezierPath(rect: CGRect(x: 100, y: 214, width: 824, height: 22)).fill()
    ctx.restoreGState()

    // the favicon's book, from its 32-unit SVG path (y flipped for Core Graphics)
    let s: CGFloat = 24, ox: CGFloat = 512 - 16 * s, oy: CGFloat = 572 + 15.75 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy - y * s) }
    let book = NSBezierPath()
    book.move(to: p(16, 9))
    book.curve(to: p(8, 7.5), controlPoint1: p(13.5, 7.4), controlPoint2: p(10.5, 7))
    book.line(to: p(8, 22.5))
    book.curve(to: p(16, 24), controlPoint1: p(10.5, 22), controlPoint2: p(13.5, 22.4))
    book.curve(to: p(24, 22.5), controlPoint1: p(18.5, 22.4), controlPoint2: p(21.5, 22))
    book.line(to: p(24, 7.5))
    book.curve(to: p(16, 9), controlPoint1: p(21.5, 7), controlPoint2: p(18.5, 7.4))
    book.close()
    book.move(to: p(16, 9))
    book.line(to: p(16, 24))
    book.lineWidth = 1.6 * s
    book.lineJoinStyle = .round
    book.lineCapStyle = .round
    NSColor.white.setStroke()
    book.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
try! draw(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
