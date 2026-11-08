import AppKit

// Renders each SVG given on the command line to a 1024×1024 PNG beside it.
// NSImage reads SVG natively on macOS 11+, so no extra tooling is needed.
let size = 1024
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path) else { print("cannot read \(path)"); exit(1) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let out = (path as NSString).deletingPathExtension + ".png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
