// Renders the app icon (1024x1024 PNG): dark squircle, Claude spark, usage ring.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle (macOS icon grid: 824pt body centred in 1024).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.03, alpha: 1)])!.draw(in: bg, angle: -90)
ctx.restoreGState()

let c = CGPoint(x: 512, y: 512)
let claude = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let green = NSColor(red: 0.36, green: 0.89, blue: 0.56, alpha: 1)

// Track + usage arc.
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
ctx.addArc(center: c, radius: 300, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: green.withAlphaComponent(0.8).cgColor)
ctx.setStrokeColor(green.cgColor)
ctx.addArc(center: c, radius: 300, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * 0.68, clockwise: true)
ctx.strokePath()
ctx.restoreGState()

// Spark: 10 rounded rays, alternating lengths.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: claude.withAlphaComponent(0.7).cgColor)
claude.setFill()
for i in 0..<10 {
    let len: CGFloat = i % 2 == 0 ? 190 : 140
    let w: CGFloat = 46
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: CGFloat(i) * .pi / 5)
    NSBezierPath(roundedRect: CGRect(x: -w / 2, y: 22, width: w, height: len), xRadius: w / 2, yRadius: w / 2).fill()
    ctx.restoreGState()
}
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
