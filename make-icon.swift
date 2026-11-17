// Draws the Burn Rate app icon into an .iconset folder for `iconutil`: a layered flame (deep red →
// ember → gold, with a white-hot core) glowing on a dark glass tile. Run by "Install Burn Rate.command":
//   swift make-icon.swift <out.iconset> [preview.png]
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// The flame in unit coordinates (0…1, y up), mapped into `r`.
func flame(in r: NSRect, inner: Bool) -> NSBezierPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    let b = NSBezierPath()
    if !inner {
        b.move(to: p(0.50, 0.04))
        b.curve(to: p(0.16, 0.36), controlPoint1: p(0.29, 0.04), controlPoint2: p(0.16, 0.18))
        b.curve(to: p(0.33, 0.70), controlPoint1: p(0.16, 0.52), controlPoint2: p(0.25, 0.61))
        b.curve(to: p(0.36, 0.86), controlPoint1: p(0.36, 0.75), controlPoint2: p(0.37, 0.80))
        b.curve(to: p(0.47, 0.72), controlPoint1: p(0.43, 0.83), controlPoint2: p(0.46, 0.78))
        b.curve(to: p(0.56, 0.98), controlPoint1: p(0.50, 0.84), controlPoint2: p(0.53, 0.92))
        b.curve(to: p(0.70, 0.62), controlPoint1: p(0.66, 0.88), controlPoint2: p(0.70, 0.74))
        b.curve(to: p(0.76, 0.70), controlPoint1: p(0.72, 0.64), controlPoint2: p(0.75, 0.66))
        b.curve(to: p(0.84, 0.36), controlPoint1: p(0.84, 0.60), controlPoint2: p(0.86, 0.47))
        b.curve(to: p(0.50, 0.04), controlPoint1: p(0.82, 0.16), controlPoint2: p(0.68, 0.04))
    } else {
        b.move(to: p(0.50, 0.09))
        b.curve(to: p(0.35, 0.28), controlPoint1: p(0.41, 0.09), controlPoint2: p(0.35, 0.17))
        b.curve(to: p(0.47, 0.50), controlPoint1: p(0.35, 0.38), controlPoint2: p(0.42, 0.44))
        b.curve(to: p(0.54, 0.68), controlPoint1: p(0.51, 0.55), controlPoint2: p(0.54, 0.61))
        b.curve(to: p(0.63, 0.40), controlPoint1: p(0.60, 0.59), controlPoint2: p(0.63, 0.49))
        b.curve(to: p(0.65, 0.27), controlPoint1: p(0.64, 0.35), controlPoint2: p(0.65, 0.31))
        b.curve(to: p(0.50, 0.09), controlPoint1: p(0.65, 0.16), controlPoint2: p(0.59, 0.09))
    }
    b.close()
    return b
}

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // macOS icon grid: the tile is ~80% of the canvas, with a soft drop shadow.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset * 1.15, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0, 0, 0, 0.45); shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    rgb(0.07, 0.06, 0.06).setFill(); tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Dark glass tile: charcoal gradient, a warm glow from the fire, and a sheen along the top.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [rgb(0.035, 0.03, 0.03), rgb(0.09, 0.08, 0.075), rgb(0.15, 0.13, 0.125)])?.draw(in: tile, angle: 90)
    NSGradient(colors: [rgb(1.0, 0.38, 0.10, 0.22), rgb(1.0, 0.30, 0.08, 0.0)])?
        .draw(fromCenter: NSPoint(x: tile.midX, y: tile.minY + tile.height * 0.34), radius: 0,
              toCenter: NSPoint(x: tile.midX, y: tile.minY + tile.height * 0.34), radius: tile.width * 0.48, options: [])
    let sheen = NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2)
    NSGradient(colors: [rgb(1, 1, 1, 0.0), rgb(1, 1, 1, 0.07)])?.draw(in: sheen, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    // Hairline rim, brighter at the top, like a glass edge.
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.002, dy: s * 0.002), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, s * 0.004)
    NSGraphicsContext.saveGraphicsState()
    rim.addClip()
    NSGradient(colors: [rgb(1, 1, 1, 0.05), rgb(1, 1, 1, 0.28)])?.draw(in: tile, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    rgb(1, 1, 1, 0.10).setStroke(); rim.stroke()

    // Flame: a glow, the outer flame, then the hot core.
    let fw = tile.width * 0.62
    let fr = NSRect(x: tile.midX - fw / 2, y: tile.minY + tile.height * 0.14, width: fw, height: fw * 1.14)
    let outer = flame(in: fr, inner: false)
    NSGraphicsContext.saveGraphicsState()
    cg.setShadow(offset: .zero, blur: s * 0.06, color: rgb(1.0, 0.36, 0.06, 0.7).cgColor)
    rgb(0.95, 0.30, 0.08).setFill(); outer.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    outer.addClip()
    NSGradient(colors: [rgb(0.62, 0.07, 0.05), rgb(0.93, 0.24, 0.07), rgb(1.0, 0.47, 0.12), rgb(1.0, 0.72, 0.24)],
               atLocations: [0, 0.35, 0.7, 1], colorSpace: .sRGB)?.draw(in: fr, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    let inner = flame(in: fr, inner: true)
    NSGraphicsContext.saveGraphicsState()
    cg.setShadow(offset: .zero, blur: s * 0.03, color: rgb(1.0, 0.85, 0.4, 0.9).cgColor)
    inner.addClip()
    NSGradient(colors: [rgb(1.0, 0.98, 0.86), rgb(1.0, 0.86, 0.42), rgb(1.0, 0.62, 0.18)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)?.draw(in: fr, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try? render(base * scale)?.write(to: out.appendingPathComponent(name))
    }
}
if args.count > 2 { try? render(512)?.write(to: URL(fileURLWithPath: args[2])) }
