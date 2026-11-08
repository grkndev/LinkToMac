#!/usr/bin/env swift
// Draws the install window's background (the DMG's Finder window) to the macOS design:
//   swift scripts/dmg/make-background.swift <version> <outDir>
// → <outDir>/background.png (660 × 400 @ 72 dpi) and background@2x.png (1320 × 800 @ 144 dpi).
//
// Finder draws the two icons and their names itself; this image is only what is behind them: the
// soft gradient, the dashed "drag" arrow, the headline, the pills that keep a name readable in both
// light mode (black text) and dark mode (white text), and a footer carrying the VERSION — which is
// why it is rendered per release instead of being a checked-in asset.
import AppKit

let version = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0.0.0"
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draw text with its top-left at (x, y) in the y-down canvas; returns its width.
@discardableResult
func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: CGColor,
          tracking: CGFloat = 0, centeredIn width: CGFloat? = nil) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: tracking,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let w = str.size().width
    str.draw(at: NSPoint(x: width.map { (($0 - w) / 2).rounded(.down) } ?? x, y: y))
    return w
}

func render(scale: Int, version: String) -> Data {
    let w = 660, h = 400
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h) // points, so the @2x image is tagged 144 dpi
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: gctx.cgContext, flipped: true)
    let ctx = gctx.cgContext
    // (No scaling here: the rep's size is in points, so the context already maps points to pixels.)
    // CoreGraphics is y-up; the design is y-down.
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // 1. Base: radial-gradient(120% 90% at 50% 0%, #fff 0%, #F2F4FA 45%, #E6EAF4 100%)
    ctx.saveGState()
    ctx.translateBy(x: 330, y: 0); ctx.scaleBy(x: 792, y: 360)
    let base = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xF2F4FA), rgb(0xE6EAF4)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(base, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // 2. Two soft colour glows at the bottom corners (420 × 300 ellipses)
    func glow(center: CGPoint, color: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y); ctx.scaleBy(x: 210, y: 150)
        let g = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ctx.restoreGState()
    }
    glow(center: CGPoint(x: 130, y: 390), color: rgb(0x6E84C8, 0.16))
    glow(center: CGPoint(x: 540, y: 400), color: rgb(0xA082C8, 0.13))

    // 3. Name pills. Finder paints the icon NAME on top of these in black (light mode) or white
    //    (dark mode); the tone is picked so both land near 4.5:1 on the one image.
    for x in [103.0, 433.0] {
        ctx.setFillColor(rgb(0x3C486E, 0.74))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 260, width: 124, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
    }

    // 4. The dashed "drag" arrow between the two icons
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(3)
    ctx.setStrokeColor(rgb(0x9AA6C9)); ctx.setLineDash(phase: 0, lengths: [1, 9])
    ctx.move(to: CGPoint(x: 262, y: 178))
    ctx.addCurve(to: CGPoint(x: 398, y: 178), control1: CGPoint(x: 300, y: 138), control2: CGPoint(x: 360, y: 138))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setStrokeColor(rgb(0x7F8DB8))
    ctx.move(to: CGPoint(x: 397.5, y: 167)); ctx.addLine(to: CGPoint(x: 400, y: 180)); ctx.addLine(to: CGPoint(x: 387.5, y: 177.5))
    ctx.strokePath()

    // 5. Headline + hint (drawn through AppKit text, in the flipped context)
    text("Drag to Applications to install", x: 0, y: 34, size: 20, weight: .bold, color: rgb(0x1B1C21),
         tracking: -0.3, centeredIn: 660)
    text("Then open Link to Mac from Launchpad or Spotlight", x: 0, y: 63.5, size: 13, weight: .regular,
         color: rgb(0x5F6372), centeredIn: 660)

    // 6. Footer: the mark and "Link to Mac <version> · pairs with the Android app · grkn.dev", centred
    let footer = "Link to Mac \(version) · pairs with the Android app · grkn.dev"
    let fw = NSAttributedString(string: footer, attributes: [.font: NSFont.systemFont(ofSize: 11)]).size().width
    let x0 = (660 - (16 + 7 + fw)) / 2
    ctx.saveGState()
    ctx.translateBy(x: x0, y: 368); ctx.scaleBy(x: 16.0 / 60, y: 16.0 / 60); ctx.translateBy(x: -24, y: -24)
    ctx.setFillColor(rgb(0x8E929E))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 32, y: 36, width: 44, height: 30), cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 28, y: 68, width: 52, height: 5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)); ctx.fillPath()
    ctx.setStrokeColor(rgb(0xE6EAF4)); ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let arrows = CGMutablePath()
    arrows.move(to: CGPoint(x: 44, y: 46)); arrows.addLine(to: CGPoint(x: 64, y: 46))
    arrows.move(to: CGPoint(x: 60.5, y: 42.5)); arrows.addLine(to: CGPoint(x: 64, y: 46)); arrows.addLine(to: CGPoint(x: 60.5, y: 49.5))
    arrows.move(to: CGPoint(x: 64, y: 56)); arrows.addLine(to: CGPoint(x: 44, y: 56))
    arrows.move(to: CGPoint(x: 47.5, y: 52.5)); arrows.addLine(to: CGPoint(x: 44, y: 56)); arrows.addLine(to: CGPoint(x: 47.5, y: 59.5))
    ctx.addPath(arrows); ctx.strokePath()
    ctx.restoreGState()
    text(footer, x: x0 + 23, y: 369.5, size: 11, weight: .regular, color: rgb(0x8E929E))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1, version: version).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2, version: version).write(to: outDir.appendingPathComponent("background@2x.png"))
print("wrote background.png and background@2x.png for \(version)")
