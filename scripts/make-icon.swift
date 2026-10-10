// Draws FinderSearch's icon designs, all in code (no SF Symbols: their license
// excludes app icons). B, "private search", is the app icon.
//
// usage, from anywhere: swift scripts/make-icon.swift  (needs Xcode, for actool)
// writes docs/images/icon-concepts/{A-folder,B-private,C-content,compare}.png,
// the icon source assets/AppIcon.icon, and its compiled forms
// assets/Assets.car and assets/AppIcon.icns, which the build copies.
import AppKit

let S: CGFloat = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("docs/images/icon-concepts")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The macOS icon body: a superellipse in the 824 px square of the 1024 grid.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let (c, s) = (cos(t), sin(t))
        let pt = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c),
                         y: r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func gradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, evenOdd: Bool = false) {
    ctx.saveGState()
    ctx.addPath(path)
    evenOdd ? ctx.clip(using: .evenOdd) : ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func body(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32) -> CGPath {
    let r = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = squircle(r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(rgb(bottom)); ctx.fillPath()
    ctx.restoreGState()
    gradient(ctx, path, [rgb(top), rgb(bottom)], CGPoint(x: 0, y: r.maxY), CGPoint(x: 0, y: r.minY))
    return path
}

func roundRect(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

/// Magnifier: ring centred at `c`, handle toward the bottom right.
func magnifier(_ ctx: CGContext, _ c: CGPoint, r: CGFloat, ring w: CGFloat, handle: CGFloat,
               ringColors: [CGColor], handleColors: [CGColor], glass: [CGColor], inside: ((CGContext, CGPath) -> Void)? = nil) {
    // Handle.
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: -.pi / 4)
    let hw = w * 1.15
    let h = roundRect(CGRect(x: r + w * 0.2, y: -hw / 2, width: handle, height: hw), hw / 2)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.3))
    ctx.addPath(h); ctx.setFillColor(handleColors.last!); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    gradient(ctx, h, handleColors, CGPoint(x: 0, y: hw / 2), CGPoint(x: 0, y: -hw / 2))
    ctx.restoreGState()
    // Glass, then whatever shows through it.
    let lens = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    gradient(ctx, lens, glass, CGPoint(x: c.x - r, y: c.y + r), CGPoint(x: c.x + r, y: c.y - r))
    if let inside { ctx.saveGState(); ctx.addPath(lens); ctx.clip(); inside(ctx, lens); ctx.restoreGState() }
    // Highlight on the glass.
    ctx.saveGState()
    ctx.addPath(lens); ctx.clip()
    let hl = CGMutablePath(); hl.addArc(center: c, radius: r * 0.78, startAngle: .pi * 0.6, endAngle: .pi * 0.95, clockwise: false)
    ctx.addPath(hl); ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(r * 0.09); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
    // Ring.
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: c.x - r - w, y: c.y - r - w, width: 2 * (r + w), height: 2 * (r + w)))
    ring.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x000000, 0.3))
    ctx.addPath(ring); ctx.setFillColor(ringColors.last!); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    gradient(ctx, ring, ringColors, CGPoint(x: c.x - r, y: c.y + r), CGPoint(x: c.x + r, y: c.y - r), evenOdd: true)
}

func folder(_ ctx: CGContext, _ r: CGRect) {
    let tab = roundRect(CGRect(x: r.minX, y: r.maxY - r.height * 0.2, width: r.width * 0.42, height: r.height * 0.24), r.height * 0.06)
    let back = CGMutablePath(); back.addPath(roundRect(r.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: -r.height * 0.02), r.height * 0.08)); back.addPath(tab)
    gradient(ctx, back, [rgb(0x3D8FE8), rgb(0x2470CC)], CGPoint(x: 0, y: r.maxY), CGPoint(x: 0, y: r.minY))
    let front = roundRect(CGRect(x: r.minX, y: r.minY - r.height * 0.02, width: r.width, height: r.height * 0.8), r.height * 0.08)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: rgb(0x0B3D7A, 0.35))
    ctx.addPath(front); ctx.setFillColor(rgb(0x5AA9F8)); ctx.fillPath(); ctx.restoreGState()
    gradient(ctx, front, [rgb(0x7CC0FF), rgb(0x4A9BF0)], CGPoint(x: 0, y: r.minY + r.height * 0.8), CGPoint(x: 0, y: r.minY))
}

func padlock(_ ctx: CGContext, _ c: CGPoint, _ s: CGFloat, _ color: CGColor) {
    let bodyR = CGRect(x: c.x - s * 0.5, y: c.y - s * 0.55, width: s, height: s * 0.78)
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: c.x - s * 0.3, y: bodyR.maxY - s * 0.05))
    shackle.addLine(to: CGPoint(x: c.x - s * 0.3, y: bodyR.maxY + s * 0.12))
    shackle.addArc(center: CGPoint(x: c.x, y: bodyR.maxY + s * 0.12), radius: s * 0.3, startAngle: .pi, endAngle: 0, clockwise: true)
    shackle.addLine(to: CGPoint(x: c.x + s * 0.3, y: bodyR.maxY - s * 0.05))
    ctx.addPath(shackle); ctx.setStrokeColor(color); ctx.setLineWidth(s * 0.14); ctx.setLineCap(.round); ctx.strokePath()
    ctx.addPath(roundRect(bodyR, s * 0.14)); ctx.setFillColor(color); ctx.fillPath()
    let hole = CGMutablePath()
    hole.addEllipse(in: CGRect(x: c.x - s * 0.08, y: bodyR.midY - s * 0.02, width: s * 0.16, height: s * 0.16))
    hole.addRect(CGRect(x: c.x - s * 0.035, y: bodyR.midY - s * 0.2, width: s * 0.07, height: s * 0.22))
    ctx.addPath(hole); ctx.setFillColor(rgb(0x14213A)); ctx.fillPath()
}

func textLines(_ ctx: CGContext, _ r: CGRect, scale: CGFloat, color: CGColor, about: CGPoint) {
    let widths: [CGFloat] = [0.92, 0.7, 0.85, 0.55, 0.88, 0.76, 0.6, 0.9]
    // Laid out at scale 1, then magnified about `about`, so the lines in the
    // lens continue the ones around it.
    for (i, w) in widths.enumerated() {
        let base = CGRect(x: r.minX, y: r.maxY - 60 - CGFloat(i) * 70, width: r.width * w, height: 34)
        let rect = CGRect(x: about.x + (base.minX - about.x) * scale, y: about.y + (base.minY - about.y) * scale,
                          width: base.width * scale, height: base.height * scale)
        ctx.addPath(roundRect(rect, rect.height / 2)); ctx.setFillColor(color); ctx.fillPath()
    }
}

/// Draw on the 1024 grid, rendered at `size` pixels (vector, so small sizes stay crisp).
func render(_ size: Int = 1024, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / S, y: CGFloat(size) / S)
    draw(ctx)
    return ctx.makeImage()!
}

let graphite = [rgb(0x5B626D), rgb(0x23272E)], silver = [rgb(0xF4F6F9), rgb(0xA9B1BC)], blue = [rgb(0x4C95FF), rgb(0x1A5ED6)]

let drawA: (CGContext) -> Void = { ctx in
    _ = body(ctx, 0xF3F8FE, 0xD5E6F8)
    folder(ctx, CGRect(x: 205, y: 300, width: 560, height: 430))
    magnifier(ctx, CGPoint(x: 600, y: 445), r: 150, ring: 42, handle: 210, ringColors: graphite, handleColors: graphite,
              glass: [rgb(0xFFFFFF, 0.55), rgb(0xD7ECFF, 0.25)])
}
let drawB: (CGContext) -> Void = { ctx in
    _ = body(ctx, 0x24375E, 0x0E1730)
    magnifier(ctx, CGPoint(x: 460, y: 560), r: 205, ring: 48, handle: 250, ringColors: silver, handleColors: silver,
              glass: [rgb(0x3E5D92, 0.9), rgb(0x1B2B4D, 0.9)]) { ctx, _ in
        padlock(ctx, CGPoint(x: 460, y: 555), 165, rgb(0xFFFFFF))
    }
}
let drawC: (CGContext) -> Void = { ctx in
    _ = body(ctx, 0xFFFFFF, 0xE4E7EC)
    let page = CGRect(x: 230, y: 210, width: 520, height: 620)
    textLines(ctx, page, scale: 1, color: rgb(0xB9C0CA), about: .zero)
    let center = CGPoint(x: 560, y: 520)
    magnifier(ctx, center, r: 175, ring: 44, handle: 220, ringColors: blue, handleColors: graphite,
              glass: [rgb(0xFFFFFF, 0.95), rgb(0xEEF4FF, 0.95)]) { ctx, _ in
        textLines(ctx, page, scale: 1.6, color: rgb(0x2F6FE0), about: center)
    }
}

func save(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let (a, b, c) = (render(1024, drawA), render(1024, drawB), render(1024, drawC))
save(a, out.appendingPathComponent("A-folder.png"))
save(b, out.appendingPathComponent("B-private.png"))
save(c, out.appendingPathComponent("C-content.png"))

// Comparison sheet: each concept at 256, 64, 32 and 16 px, on light and dark.
let names = ["A  Folder + magnifier", "B  Private search", "C  Search inside files"]
let col: CGFloat = 400, W = col * 3, rowH: CGFloat = 420, H = rowH * 2
let sheet = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.interpolationQuality = .high
for (row, bg, ink) in [(1, rgb(0xECECEC), NSColor.black), (0, rgb(0x1E1E1E), NSColor.white)] {
    sheet.setFillColor(bg); sheet.fill(CGRect(x: 0, y: CGFloat(row) * rowH, width: W, height: rowH))
    for (i, img) in [a, b, c].enumerated() {
        let x0 = CGFloat(i) * col, y0 = CGFloat(row) * rowH
        sheet.draw(img, in: CGRect(x: x0 + 72, y: y0 + 120, width: 256, height: 256))
        var x = x0 + 90
        for s in [64, 32, 16] as [CGFloat] { sheet.draw(img, in: CGRect(x: x, y: y0 + 40, width: s, height: s)); x += s + 40 }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
        (names[i] as NSString).draw(at: CGPoint(x: x0 + 72, y: y0 + 386), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: ink])
    }
}
save(sheet.makeImage()!, out.appendingPathComponent("compare.png"))

// The app icon: B as an Icon Composer icon (assets/AppIcon.icon), the format
// current macOS expects; an older-style icon is set on a grey plate. A navy
// fill and two layers, magnifier and padlock, drawn edge to edge: macOS adds
// the rounded shape, shadows and glass. actool compiles it into
// assets/Assets.car and, for older macOS, assets/AppIcon.icns; the build
// copies those, so it doesn't need actool.
let iconDir = root.appendingPathComponent("assets/AppIcon.icon")
let layers = iconDir.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: iconDir)
try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
// B was drawn in the 824 px body at (100, 100); a layer fills the whole square.
func layer(_ draw: @escaping (CGContext) -> Void) -> CGImage {
    render(1024) { ctx in ctx.scaleBy(x: S / 824, y: S / 824); ctx.translateBy(x: -100, y: -100); draw(ctx) }
}
save(layer { ctx in
    magnifier(ctx, CGPoint(x: 460, y: 560), r: 205, ring: 48, handle: 250, ringColors: silver, handleColors: silver,
              glass: [rgb(0x3E5D92, 0.9), rgb(0x1B2B4D, 0.9)])
}, layers.appendingPathComponent("magnifier.png"))
save(layer { ctx in padlock(ctx, CGPoint(x: 460, y: 555), 165, rgb(0xFFFFFF)) }, layers.appendingPathComponent("padlock.png"))
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "extended-srgb:0.14118,0.21569,0.36863,1.00000",
      "extended-srgb:0.05490,0.09020,0.18824,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [ { "image-name" : "padlock.png", "name" : "padlock" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 }
    },
    {
      "layers" : [ { "image-name" : "magnifier.png", "name" : "magnifier" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 }
    }
  ],
  "supported-platforms" : {
    "circles" : [ "watchOS" ],
    "squares" : "shared"
  }
}
"""
try iconJSON.write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

let assets = root.appendingPathComponent("assets")
let partial = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid())-partial.plist")
defer { try? FileManager.default.removeItem(at: partial) }
let actool = Process()
actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
actool.arguments = ["actool", iconDir.path, "--compile", assets.path, "--platform", "macosx",
                    "--minimum-deployment-target", "15.0", "--app-icon", "AppIcon",
                    "--output-partial-info-plist", partial.path, "--errors", "--warnings"]
try actool.run(); actool.waitUntilExit()
guard actool.terminationStatus == 0 else { fatalError("actool failed (it needs Xcode, not just the command line tools)") }
print("wrote", out.path, "and", assets.path)
