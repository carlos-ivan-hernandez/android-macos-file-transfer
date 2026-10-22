import AppKit

enum IconError: LocalizedError {
    case failed

    var errorDescription: String? { "Couldn't make the app icon." }
}

/// Turns an image into an .icns file with every size macOS uses. build.sh runs it through
/// `AMFileTransfer icon <image> <output.icns>`.
enum IconMaker {
    private static let iconsetEntries: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// The image is drawn as-is, scaled to fit a square and centered, so transparent areas
    /// (like the corners of an app icon) stay transparent.
    static func writeICNS(_ image: NSImage, to destination: URL) throws {
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory.appendingPathComponent("AMFileTransferIcon-\(UUID().uuidString)")
        let iconset = workDir.appendingPathComponent("icon.iconset")
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        var pngs: [Int: Data] = [:]
        for entry in iconsetEntries {
            if pngs[entry.pixels] == nil {
                guard let png = pngData(image, pixels: entry.pixels) else { throw IconError.failed }
                pngs[entry.pixels] = png
            }
            try pngs[entry.pixels]!.write(to: iconset.appendingPathComponent(entry.name + ".png"))
        }
        try runIconutil(iconset: iconset, destination: destination)
    }

    private static func runIconutil(iconset: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IconError.failed }
    }

    /// Puts a full-bleed square image on Apple's macOS icon grid: an 824pt rounded square with a
    /// soft drop shadow, centered on a transparent 1024pt canvas.
    static func gridIcon(from image: NSImage) -> NSImage {
        let canvas: CGFloat = 1024
        let drawing = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
            let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.shadowBlurRadius = 24
            shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            shape.addClip()
            image.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // Render once at full size. Redrawing at each icon size would keep the shadow's offset and
        // blur in pixels, so it would swamp the small sizes.
        guard let png = pngData(drawing, pixels: Int(canvas)), let rendered = NSImage(data: png) else { return drawing }
        return rendered
    }

    static func pngData(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let canvas = CGFloat(pixels)
        let size = image.size
        if size.width > 0, size.height > 0 {
            let ratio = min(canvas / size.width, canvas / size.height)
            let drawn = NSSize(width: size.width * ratio, height: size.height * ratio)
            let target = NSRect(
                x: (canvas - drawn.width) / 2, y: (canvas - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            )
            // NSImage picks the best representation for the size, so icons stay sharp when small.
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        }
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
