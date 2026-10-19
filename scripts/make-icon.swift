// Renders the 👁️ app icon into AppIcon.iconset (run by build.sh).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded square with a navy glow gradient, inset like standard macOS icons.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.10, blue: 0.30, alpha: 1),
                        NSColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1)])!.draw(in: path, angle: 90)

    let font = NSFont.systemFont(ofSize: rect.width * 0.62)
    let eye = NSAttributedString(string: "👁️", attributes: [.font: font])
    let size = eye.size()
    eye.draw(at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
