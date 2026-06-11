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
