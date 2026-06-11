import AppKit
import UniformTypeIdentifiers

extension CGImage {
    /// Crop using a rect expressed in points within an image that has `scale` pixels per point.
    func cropping(toPointRect rect: CGRect, scale: CGFloat) -> CGImage? {
        let pixelRect = CGRect(x: rect.origin.x * scale,
                               y: rect.origin.y * scale,
                               width: rect.width * scale,
                               height: rect.height * scale).integral
        return cropping(to: pixelRect)
    }

    var nsImage: NSImage {
        // Divide by backing scale so the NSImage reports point size on screen.
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }

    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }

    func jpegData(quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Scale to a target pixel width, preserving aspect.
    func resized(maxPixelWidth: Int) -> CGImage {
        guard width > maxPixelWidth else { return self }
        let ratio = CGFloat(maxPixelWidth) / CGFloat(width)
        let newW = maxPixelWidth
        let newH = Int(CGFloat(height) * ratio)
        guard let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? self
    }

    /// Downscale by an integer factor (e.g. retina 2x -> 1x).
    func downscaled(by factor: CGFloat) -> CGImage {
        guard factor > 1 else { return self }
        let newW = Int(CGFloat(width) / factor)
        let newH = Int(CGFloat(height) / factor)
        guard let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? self
    }
}

extension NSImage {
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Background analysis (extend-background / normalize-margins)

extension CGImage {
    /// Downsampled RGBA8 pixel buffer for analysis. Row 0 is the BOTTOM row
    /// (unflipped CG context).
    private func rgbaBuffer(maxDimension: Int) -> (buffer: [UInt8], width: Int, height: Int)? {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(width, height)))
        let w = max(1, Int(CGFloat(width) * scale))
        let h = max(1, Int(CGFloat(height) * scale))
        let bytesPerRow = w * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * h, alignment: 4)
        defer { data.deallocate() }
        guard let ctx = CGContext(data: data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buffer = [UInt8](UnsafeRawBufferPointer(start: data, count: bytesPerRow * h))
        return (buffer, w, h)
    }

    /// The most common color along the image's outer edges — the "background"
    /// of terminal panels, editors, web pages, etc.
    func dominantEdgeColor() -> RGBA? {
        guard let (buf, w, h) = rgbaBuffer(maxDimension: 128), w > 2, h > 2 else { return nil }
        var buckets: [UInt32: (count: Int, r: Int, g: Int, b: Int)] = [:]

        func sample(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            guard buf[i + 3] > 200 else { return } // ignore transparent margins
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            let key = UInt32(r >> 4) << 8 | UInt32(g >> 4) << 4 | UInt32(b >> 4)
            var entry = buckets[key] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.r += r; entry.g += g; entry.b += b
            buckets[key] = entry
        }

        for x in 0..<w { sample(x, 0); sample(x, h - 1) }
        for y in 0..<h { sample(0, y); sample(w - 1, y) }

        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count > 0 else {
            return nil
        }
        let n = Double(best.count) * 255.0
        return RGBA(r: Double(best.r) / n, g: Double(best.g) / n, b: Double(best.b) / n, a: 1)
    }

    /// Bounding box (full-resolution pixels, top-left origin) of everything
    /// that differs from `background`. Returns nil if nothing stands out.
    func contentBoundingBox(background: RGBA, tolerance: Int = 60) -> CGRect? {
        guard let (buf, w, h) = rgbaBuffer(maxDimension: 512) else { return nil }
        let br = Int(background.r * 255), bg = Int(background.g * 255), bb = Int(background.b * 255)
        var minX = w, minY = h, maxX = -1, maxY = -1

        for y in 0..<h {
            let rowStart = y * w * 4
            for x in 0..<w {
                let i = rowStart + x * 4
                let diff = abs(Int(buf[i]) - br) + abs(Int(buf[i + 1]) - bg) + abs(Int(buf[i + 2]) - bb)
                if diff > tolerance {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Buffer rows are bottom-up; flip to top-left coordinates.
        let topMinY = h - 1 - maxY
        let topMaxY = h - 1 - minY
        let scaleX = CGFloat(width) / CGFloat(w)
        let scaleY = CGFloat(height) / CGFloat(h)
        // Safety margin: one downsampled pixel + a little.
        let margin = max(scaleX, scaleY) + 2
        let rect = CGRect(x: CGFloat(minX) * scaleX - margin,
                          y: CGFloat(topMinY) * scaleY - margin,
                          width: CGFloat(maxX - minX + 1) * scaleX + margin * 2,
                          height: CGFloat(topMaxY - topMinY + 1) * scaleY + margin * 2)
        return rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

extension NSPasteboard {
    static func copyImage(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image.nsImage])
    }

    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    static func copyString(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    static var image: NSImage? {
        NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage
    }
}
