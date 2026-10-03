import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (size, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                       (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
                       (512, "512x512"), (1024, "512x512@2x")] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 215, yRadius: 215)
    NSGradient(starting: NSColor(srgbRed: 0.15, green: 0.68, blue: 0.51, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.36, blue: 0.31, alpha: 1))!.draw(in: background, angle: -60)
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 205, y: 488))
    for point in [NSPoint(x: 340, y: 488), NSPoint(x: 416, y: 669), NSPoint(x: 519, y: 344), NSPoint(x: 605, y: 552), NSPoint(x: 661, y: 488), NSPoint(x: 819, y: 488)] { line.line(to: point) }
    line.lineWidth = 53; line.lineJoinStyle = .round; line.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.95).setStroke(); line.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
    try png.write(to: output.appendingPathComponent("icon_\(suffix).png"))
}
