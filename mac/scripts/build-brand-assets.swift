#!/usr/bin/env swift
// Regenerates the Mac app's brand art from the shared "Synced Mac" mark (the Android app's 2a mark:
// a laptop with two opposing arrows). Run from `mac/`:  swift scripts/build-brand-assets.swift
//
//   Resources/AppIcon.icon/Assets/glyph.png                    the icon's glyph layer (1024², white,
//                                                             arrows cut out so the fill shows through)
//   Resources/Assets.xcassets/MenuBarIcon.imageset/menubar_18  the template menu-bar image, @1x
//   Resources/Assets.xcassets/MenuBarIcon.imageset/menubar_36  … and @2x
//
// Never hand-edit those PNGs; edit the geometry below and re-run. The script is idempotent. The
// icon's fill, dark and tinted looks live in `Resources/AppIcon.icon/icon.json` (Icon Composer).
import AppKit

/// The mark, in the design's 24-unit grid for the menu bar and in its 60-unit grid (viewBox
/// 24 24 60 60) for the app icon — the same shapes in both.
enum Mark {
    // App-icon grid (viewBox 24 24 60 60)
    static let laptop = CGRect(x: 32, y: 36, width: 44, height: 30)
    static let laptopRadius: CGFloat = 6
    static let base = CGRect(x: 28, y: 68, width: 52, height: 5)
    static let baseRadius: CGFloat = 2.5
    static let arrows: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 44, y: 46)); p.addLine(to: CGPoint(x: 64, y: 46))
        p.move(to: CGPoint(x: 60.5, y: 42.5)); p.addLine(to: CGPoint(x: 64, y: 46)); p.addLine(to: CGPoint(x: 60.5, y: 49.5))
        p.move(to: CGPoint(x: 64, y: 56)); p.addLine(to: CGPoint(x: 44, y: 56))
        p.move(to: CGPoint(x: 47.5, y: 52.5)); p.addLine(to: CGPoint(x: 44, y: 56)); p.addLine(to: CGPoint(x: 47.5, y: 59.5))
        return p
    }()

    // Menu-bar grid (24 × 24), outline style
    static let barLaptop = CGRect(x: 3.5, y: 3.5, width: 17, height: 12.5)
    static let barArrows: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8, y: 7.5)); p.addLine(to: CGPoint(x: 16, y: 7.5))
        p.move(to: CGPoint(x: 14.25, y: 5.75)); p.addLine(to: CGPoint(x: 16, y: 7.5)); p.addLine(to: CGPoint(x: 14.25, y: 9.25))
        p.move(to: CGPoint(x: 16, y: 12)); p.addLine(to: CGPoint(x: 8, y: 12))
        p.move(to: CGPoint(x: 9.75, y: 10.25)); p.addLine(to: CGPoint(x: 8, y: 12)); p.addLine(to: CGPoint(x: 9.75, y: 13.75))
        return p
    }()
}

/// Renders a square transparent PNG, drawing in a y-down space like SVG's.
func render(size: Int, _ draw: (CGContext) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - App icon glyph layer

let iconGlyph = render(size: 1024) { ctx in
    // The mark fills 70 % of the icon, centred, like the design.
    let box: CGFloat = 1024 * 0.7
    let scale = box / 60
    ctx.translateBy(x: (1024 - box) / 2, y: (1024 - box) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -24, y: -24)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(rounded(Mark.laptop, Mark.laptopRadius)); ctx.fillPath()
    ctx.addPath(rounded(Mark.base, Mark.baseRadius)); ctx.fillPath()
    // The arrows are cut out, so the icon's fill shows through them.
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(Mark.arrows); ctx.strokePath()
}

// MARK: - Menu bar template

func menuBar(_ px: Int) -> Data {
    render(size: px) { ctx in
        let s = CGFloat(px) / 24
        ctx.scaleBy(x: s, y: s)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)) // template: only alpha matters
        ctx.setLineWidth(1.75); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(rounded(Mark.barLaptop, 3)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 2, y: 19.5)); ctx.addLine(to: CGPoint(x: 22, y: 19.5)); ctx.strokePath()
        ctx.addPath(Mark.barArrows); ctx.strokePath()
    }
}

// MARK: - Write

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    print("wrote \(path) (\(data.count) bytes)")
}
try write(iconGlyph, "AppIcon.icon/Assets/glyph.png")
try write(menuBar(18), "Assets.xcassets/MenuBarIcon.imageset/menubar_18.png")
try write(menuBar(36), "Assets.xcassets/MenuBarIcon.imageset/menubar_36.png")
