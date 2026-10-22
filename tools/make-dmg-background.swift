// Renders the disk image window background.
// Usage: swift tools/make-dmg-background.swift <scale> <output.png>
//
// Layout must match tools/make-dmg.sh: a 600x400pt window with the app icon
// centred at (160, 180) and the Applications link at (440, 180).

import AppKit

let scale = CGFloat(Double(CommandLine.arguments[1])!)
let size = NSSize(width: 600, height: 400)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size  // draw in points; the rep's pixel size provides the scale

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Finder flips y relative to AppKit: icon centre y=180 from the top.
func fromTop(_ y: CGFloat) -> CGFloat { size.height - y }

NSGradient(
    starting: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1),
    ending: NSColor(srgbRed: 0.91, green: 0.92, blue: 0.97, alpha: 1))!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let h = (text as NSString).size(withAttributes: attrs).height
    (text as NSString).draw(in: NSRect(x: 0, y: fromTop(y) - h / 2, width: size.width, height: h), withAttributes: attrs)
}

drawCentered("Install Android USB Tools", y: 52, font: .systemFont(ofSize: 22, weight: .semibold),
             color: NSColor(white: 0.12, alpha: 1))
drawCentered("Drag the app into your Applications folder", y: 80, font: .systemFont(ofSize: 13),
             color: NSColor(white: 0.40, alpha: 1))

// Arrow between the two icons.
let accent = NSColor(srgbRed: 0.18, green: 0.27, blue: 0.85, alpha: 1)  // the icon's ultramarine
let arrowY = fromTop(180)
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 245, y: arrowY))
shaft.line(to: NSPoint(x: 345, y: arrowY))
shaft.lineWidth = 5
shaft.lineCapStyle = .round
accent.setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 360, y: arrowY))
head.line(to: NSPoint(x: 340, y: arrowY + 14))
head.line(to: NSPoint(x: 340, y: arrowY - 14))
head.close()
accent.setFill()
head.fill()

drawCentered("Then open it from Applications and follow the setup.", y: 330,
             font: .systemFont(ofSize: 12), color: NSColor(white: 0.45, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
