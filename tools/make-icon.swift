// Renders the 1024px app icon PNG: a yellow USB-C cable tied in a loose loop
// on an ultramarine tile.
// Usage: swift tools/make-icon.swift <output.png>

import AppKit

let px = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// MARK: Tile

// Standard macOS icon grid: an 824pt tile centred in the 1024pt canvas.
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
tileShadow.shadowOffset = NSSize(width: 0, height: -12)
tileShadow.shadowBlurRadius = 28
tileShadow.set()
rgb(0x1B228F).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: rgb(0x3A55F2), ending: rgb(0x1B228F))!.draw(in: tile, angle: -90)
// A soft light falling from the top edge.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
    .draw(in: tile, relativeCenterPosition: NSPoint(x: -0.2, y: 0.9))

// Everything else stays inside the tile.
tile.addClip()

// MARK: Cable

// A prolate trochoid gives a single loop: x = a·t − b·sin t, y = b·cos t − b.
// Over t ∈ [−π, π] it runs level, rises into a loop and returns level; straight
// runs continue it on both sides.
let a: CGFloat = 78, b: CGFloat = 150
func trochoid(_ t: CGFloat) -> NSPoint { NSPoint(x: a * t - b * sin(t), y: b * cos(t) - b) }

// Where the loop crosses itself: a·t = b·sin t.
var tCross: CGFloat = 1.5
for _ in 0..<50 { tCross -= (a * tCross - b * sin(tCross)) / (a - b * cos(tCross)) }

let plugScale: CGFloat = 0.82
let plugLength: CGFloat = 282 * plugScale
let lead: CGFloat = 40      // straight cable between the loop and the plug
let tail: CGFloat = 700     // straight cable running off the bottom-left

// Rotate the run to rise at 45° and pin the plug's tip near the top-right.
let angle: CGFloat = .pi / 4
let tipLocal = NSPoint(x: a * .pi + lead + plugLength, y: -2 * b)
let tipTarget = NSPoint(x: 800, y: 800)
func rotate(_ p: NSPoint) -> NSPoint {
    NSPoint(x: p.x * cos(angle) - p.y * sin(angle), y: p.x * sin(angle) + p.y * cos(angle))
}
let tipRotated = rotate(tipLocal)
let origin = NSPoint(x: tipTarget.x - tipRotated.x, y: tipTarget.y - tipRotated.y)
func place(_ p: NSPoint) -> NSPoint {
    let r = rotate(p)
    return NSPoint(x: origin.x + r.x, y: origin.y + r.y)
}

func cablePath(_ from: CGFloat, _ to: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    if from <= -.pi { path.move(to: place(NSPoint(x: -a * .pi - tail, y: -2 * b))) }
    let lo = max(from, -.pi), hi = min(to, .pi)
    let steps = Int((hi - lo) * 80)
    for i in 0...steps {
        let p = place(trochoid(lo + (hi - lo) * CGFloat(i) / CGFloat(steps)))
        path.isEmpty ? path.move(to: p) : path.line(to: p)
    }
    if to >= .pi { path.line(to: place(NSPoint(x: a * .pi + lead, y: -2 * b))) }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

let width: CGFloat = 64
func strokeTube(_ path: NSBezierPath, shadow: Bool) {
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowOffset = NSSize(width: 6, height: -10)
        s.shadowBlurRadius = 18
        s.set()
    }
    path.lineWidth = width
    rgb(0xD99A00).setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()

    path.lineWidth = width * 0.74
    rgb(0xFFC62B).setStroke()
    path.stroke()

    // Glossy highlight along the middle of the tube.
    let highlight = path.copy() as! NSBezierPath
    highlight.lineWidth = width * 0.2
    rgb(0xFFE58A).setStroke()
    highlight.stroke()
}

// The later pass through the crossing is drawn on top with a shadow so it
// reads as lying over the earlier one. Repainting the tube's interior across
// the joint afterwards hides where the two strokes meet.
let joint = tCross - 0.7
strokeTube(cablePath(-.pi, joint), shadow: false)
strokeTube(cablePath(joint, .pi), shadow: true)
let bridge = cablePath(joint - 0.6, joint + 0.6)
bridge.lineWidth = width * 0.74
rgb(0xFFC62B).setStroke()
bridge.stroke()
bridge.lineWidth = width * 0.2
rgb(0xFFE58A).setStroke()
bridge.stroke()

// MARK: USB-C plug

let end = place(NSPoint(x: a * .pi + lead, y: -2 * b))
let heading = angle

NSGraphicsContext.saveGraphicsState()
let xf = NSAffineTransform()
xf.translateX(by: end.x, yBy: end.y)
xf.rotate(byRadians: heading)
xf.scale(by: plugScale)
xf.concat()

let plugShadow = NSShadow()
plugShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
plugShadow.shadowOffset = NSSize(width: 8, height: -12)
plugShadow.shadowBlurRadius = 20

// Strain relief tapering into the overmold.
NSGraphicsContext.saveGraphicsState()
plugShadow.set()
let relief = NSBezierPath()
relief.move(to: NSPoint(x: -10, y: -width * 0.5))
relief.line(to: NSPoint(x: 40, y: -58))
relief.line(to: NSPoint(x: 40, y: 58))
relief.line(to: NSPoint(x: -10, y: width * 0.5))
relief.close()
rgb(0xD99A00).setFill()
relief.fill()
let overmold = NSBezierPath(roundedRect: NSRect(x: 30, y: -66, width: 150, height: 132), xRadius: 36, yRadius: 36)
overmold.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0xFFD95C), ending: rgb(0xE5A600))!.draw(in: overmold, angle: -90)

// Metal shell in profile, slightly slimmer than the overmold, with a
// rounded nose like a USB-C plug.
let shell = NSBezierPath(roundedRect: NSRect(x: 168, y: -40, width: 104, height: 80), xRadius: 22, yRadius: 22)
NSGradient(colors: [rgb(0xF4F6FA), rgb(0xC9CFDB), rgb(0x9AA3B5)])!.draw(in: shell, angle: -90)
rgb(0x7D8698).setStroke()
shell.lineWidth = 3
shell.stroke()

// A pressed seam along the shell catches the light.
let seam = NSBezierPath()
seam.move(to: NSPoint(x: 184, y: 6))
seam.line(to: NSPoint(x: 256, y: 6))
seam.lineWidth = 5
seam.lineCapStyle = .round
rgb(0x8A93A6).setStroke()
seam.stroke()

NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
