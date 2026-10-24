import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func draw() {
    NSColor(calibratedRed: 0.035, green: 0.08, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984), xRadius: 220, yRadius: 220).fill()
    let mint = NSColor(calibratedRed: 0.16, green: 0.92, blue: 0.72, alpha: 1)
    for (x, y) in [(188.0, 326.0), (422, 326), (656, 326), (188, 560), (422, 560), (656, 560)] {
        let key = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 182, height: 182), xRadius: 36, yRadius: 36)
        NSColor(calibratedWhite: 1, alpha: 0.075).setFill(); key.fill()
        mint.withAlphaComponent(0.8).setStroke(); key.lineWidth = 8; key.stroke()
    }
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: 146, y: 442)); wave.line(to: NSPoint(x: 300, y: 442))
    wave.line(to: NSPoint(x: 376, y: 250)); wave.line(to: NSPoint(x: 492, y: 748))
    wave.line(to: NSPoint(x: 608, y: 302)); wave.line(to: NSPoint(x: 682, y: 442))
    wave.line(to: NSPoint(x: 880, y: 442))
    mint.setStroke(); wave.lineWidth = 35; wave.lineCapStyle = .round; wave.lineJoinStyle = .round; wave.stroke()
}
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
             (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
             (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
}
