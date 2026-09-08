import AppKit

// Renders a simple water-sort app icon: three glass tubes with colored
// water on a blue gradient. Usage: swift make_icon.swift <output.png>

let size = 1024.0
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no bitmap rep") }
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// Background gradient
let colors = [
    NSColor(red: 0.05, green: 0.22, blue: 0.55, alpha: 1).cgColor,
    NSColor(red: 0.00, green: 0.68, blue: 0.82, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
let full = CGRect(x: 0, y: 0, width: size, height: size)
let clip = NSBezierPath(roundedRect: full, xRadius: 230, yRadius: 230)
clip.addClip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Soft glow blobs
func blob(at center: CGPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
    color.setFill()
    path.fill()
}
blob(at: CGPoint(x: 180, y: 860), radius: 260, color: NSColor.white.withAlphaComponent(0.08))
blob(at: CGPoint(x: 900, y: 120), radius: 320, color: NSColor.white.withAlphaComponent(0.06))

// A glass tube with water segments (bottom-up)
func tube(at centerX: CGFloat, bottom: CGFloat, segments: [(color: NSColor, height: CGFloat)]) {
    let width = 200.0
    let height = 580.0
    let x = centerX - width / 2

    // Glass body
    let body = NSBezierPath(roundedRect: CGRect(x: x, y: bottom, width: width, height: height),
                            xRadius: 40, yRadius: 40)
    NSColor.white.withAlphaComponent(0.9).setStroke()
    body.lineWidth = 16
    body.stroke()

    // Water segments
    var y = bottom
    for segment in segments {
        let rect = CGRect(x: x + 16, y: y, width: width - 32, height: segment.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
        segment.color.setFill()
        path.fill()
        y += segment.height
    }

    // Highlight
    let highlight = NSBezierPath(roundedRect: CGRect(x: x + 30, y: bottom + 20, width: 26, height: height - 40),
                                 xRadius: 13, yRadius: 13)
    NSColor.white.withAlphaComponent(0.28).setFill()
    highlight.fill()
}

let base: CGFloat = 230
tube(at: size * 0.27, bottom: base,
     segments: [(NSColor.systemRed, 210), (NSColor.systemBlue, 370)])
tube(at: size * 0.50, bottom: base,
     segments: [(NSColor.systemYellow, 120), (NSColor.systemGreen, 200), (NSColor.systemPurple, 260)])
tube(at: size * 0.73, bottom: base,
     segments: [(NSColor.systemOrange, 300), (NSColor.systemTeal, 280)])

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
