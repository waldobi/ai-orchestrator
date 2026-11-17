// Draws the iPhone app icon (light, dark and tinted 1024 px PNGs) with the same mark as the Mac app
// (make-icon.swift): the layered flame on a glass tile. iOS masks the corners itself, so these are full-bleed.
//   swift make-phone-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// The Mac's flame, in unit coordinates (0…1, y up), mapped into `r`.
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

enum Variant { case light, dark, tinted }

func render(_ v: Variant) -> Data? {
    let px = 1024, s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let tile = NSRect(x: 0, y: 0, width: s, height: s)

    switch v {
    case .light:
        // Pale neutral glass, a faint warm glow under the flame, sheen at the top.
        NSGradient(colors: [rgb(0.86, 0.85, 0.84), rgb(0.94, 0.93, 0.92), rgb(0.99, 0.99, 0.98)])?.draw(in: tile, angle: 90)
        NSGradient(colors: [rgb(1.0, 0.55, 0.30, 0.16), rgb(1.0, 0.55, 0.30, 0.0)])?
            .draw(fromCenter: NSPoint(x: s / 2, y: s * 0.36), radius: 0, toCenter: NSPoint(x: s / 2, y: s * 0.36), radius: s * 0.5, options: [])
    case .dark:
        // The Mac tile: charcoal glass with the fire's glow.
        NSGradient(colors: [rgb(0.035, 0.03, 0.03), rgb(0.09, 0.08, 0.075), rgb(0.15, 0.13, 0.125)])?.draw(in: tile, angle: 90)
        NSGradient(colors: [rgb(1.0, 0.38, 0.10, 0.22), rgb(1.0, 0.30, 0.08, 0.0)])?
            .draw(fromCenter: NSPoint(x: s / 2, y: s * 0.36), radius: 0, toCenter: NSPoint(x: s / 2, y: s * 0.36), radius: s * 0.48, options: [])
        NSGradient(colors: [rgb(1, 1, 1, 0.0), rgb(1, 1, 1, 0.07)])?.draw(in: NSRect(x: 0, y: s / 2, width: s, height: s / 2), angle: 90)
    case .tinted:
        // iOS tints a grayscale mark on black; keep the two flame layers as two greys.
        rgb(0, 0, 0).setFill(); tile.fill()
    }

    let fw = s * 0.60
    let fr = NSRect(x: s / 2 - fw / 2, y: s * 0.17, width: fw, height: fw * 1.14)
    let outer = flame(in: fr, inner: false), inner = flame(in: fr, inner: true)
    if v == .tinted {
        rgb(0.62, 0.62, 0.62).setFill(); outer.fill()
        rgb(1, 1, 1).setFill(); inner.fill()
    } else {
        NSGraphicsContext.saveGraphicsState()
        cg.setShadow(offset: .zero, blur: s * 0.06, color: rgb(1.0, 0.36, 0.06, v == .dark ? 0.7 : 0.35).cgColor)
        rgb(0.95, 0.30, 0.08).setFill(); outer.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outer.addClip()
        NSGradient(colors: [rgb(0.62, 0.07, 0.05), rgb(0.93, 0.24, 0.07), rgb(1.0, 0.47, 0.12), rgb(1.0, 0.72, 0.24)],
                   atLocations: [0, 0.35, 0.7, 1], colorSpace: .sRGB)?.draw(in: fr, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        cg.setShadow(offset: .zero, blur: s * 0.03, color: rgb(1.0, 0.85, 0.4, 0.9).cgColor)
        inner.addClip()
        NSGradient(colors: [rgb(1.0, 0.98, 0.86), rgb(1.0, 0.86, 0.42), rgb(1.0, 0.62, 0.18)],
                   atLocations: [0, 0.45, 1], colorSpace: .sRGB)?.draw(in: fr, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (v, name) in [(Variant.light, "icon-light.png"), (.dark, "icon-dark.png"), (.tinted, "icon-tinted.png")] {
    try? render(v)?.write(to: out.appendingPathComponent(name))
}
