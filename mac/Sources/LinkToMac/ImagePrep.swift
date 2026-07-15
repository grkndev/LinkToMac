import AppKit

/// Prepares a pasteboard image for the encrypted `file` frame: small PNGs pass through,
/// anything bigger is re-encoded (downscale + JPEG) until it fits the raw-byte budget the
/// relay's 1 MiB frame cap leaves after the seal + base64 (~4/3) overhead.
@MainActor
enum ImagePrep {
    /// Raw payload budget: 700 KB → ~960 KB frame after seal + base64, under the 1 MiB cap.
    static let rawBudgetBytes = 700 * 1024

    /// (scale, JPEG quality) ladder — the first output within budget wins.
    private static let steps: [(scale: CGFloat, quality: CGFloat)] = [(1.0, 0.8), (0.7, 0.7), (0.5, 0.5)]

    /// nil = the image can't be brought under budget (or isn't decodable) — caller skips it.
    static func prepare(_ data: Data) -> (bytes: Data, mime: String)? {
        if data.count <= rawBudgetBytes {
            if isPNG(data) { return (data, "image/png") }
            // An already-fitting JPEG must not take a second lossy trip through the ladder.
            if isJPEG(data) { return (data, "image/jpeg") }
        }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        for step in steps {
            guard
                let scaled = resample(rep, scale: step.scale),
                let jpeg = scaled.representation(using: .jpeg, properties: [.compressionFactor: step.quality])
            else { continue }
            if jpeg.count <= rawBudgetBytes { return (jpeg, "image/jpeg") }
        }
        return nil
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count > 8 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
    }

    private static func resample(_ rep: NSBitmapImageRep, scale: CGFloat) -> NSBitmapImageRep? {
        if scale >= 1.0 { return rep }
        let w = max(1, Int(CGFloat(rep.pixelsWide) * scale))
        let h = max(1, Int(CGFloat(rep.pixelsHigh) * scale))
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        out.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = ctx
        // JPEG has no alpha — composite onto white so window-shadow transparency doesn't go black.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return out
    }
}
