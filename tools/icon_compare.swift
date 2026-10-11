// Shows how macOS draws app icons, to check FinderSearch's against Apple's.
// For each app: the 1024 px icon as Finder/Dock render it, the bounding box of
// its body, and all of them side by side in OUT.png with the standard 824 px
// body outlined. Look at the picture: an icon in an outdated format is shrunk
// onto a grey plate that fills the same box, so the numbers alone can match.
//
// usage: swift tools/icon_compare.swift OUT.png APP... e.g.
//   swift tools/icon_compare.swift /tmp/icons.png /System/Applications/Preview.app /Applications/FinderSearch.app
import AppKit

let args = CommandLine.arguments
guard args.count > 2 else { print("usage: icon_compare OUT.png APP..."); exit(2) }
let size = 1024
var images: [NSImage] = []
for app in args.dropFirst(2) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSWorkspace.shared.icon(forFile: app).draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    var (x0, y0, x1, y1) = (size, size, -1, -1)
    for y in 0..<size {
        for x in 0..<size where rep.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    print("\((app as NSString).lastPathComponent): body x \(x0)-\(x1), y \(y0)-\(y1) (\(x1 - x0 + 1) x \(y1 - y0 + 1); Apple's grid: 100-923)")
    let image = NSImage(size: NSSize(width: size, height: size)); image.addRepresentation(rep); images.append(image)
}
let cell: CGFloat = 320, out = NSImage(size: NSSize(width: cell * CGFloat(images.count), height: cell))
out.lockFocus()
NSColor(white: 0.93, alpha: 1).setFill(); NSRect(origin: .zero, size: out.size).fill()
for (i, image) in images.enumerated() {
    let x = 10 + CGFloat(i) * cell
    image.draw(in: NSRect(x: x, y: 10, width: 300, height: 300))
    NSColor.red.withAlphaComponent(0.7).setStroke()
    let grid = NSBezierPath(rect: NSRect(x: x + 300 * 100 / 1024, y: 10 + 300 * 100 / 1024, width: 300 * 824 / 1024, height: 300 * 824 / 1024))
    grid.lineWidth = 1; grid.stroke()
}
out.unlockFocus()
try NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
print("wrote", args[1])
