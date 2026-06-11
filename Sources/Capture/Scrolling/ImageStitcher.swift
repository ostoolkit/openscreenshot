import CoreGraphics
import Foundation

/// Stitches sequential frames of a scrolling region into one tall image.
/// Matching is done with per-row signatures: for each new frame we find the
/// vertical offset that best aligns it with the previous frame, then append
/// only the newly revealed rows.
final class ImageStitcher {
    private(set) var slices: [CGImage] = []
    private(set) var totalHeight = 0
    private var width = 0

    private var previousSignatures: [UInt64] = []

    /// Returns the number of new pixel rows appended (0 if the frame didn't advance).
    @discardableResult
    func add(frame: CGImage) -> Int {
        let signatures = Self.rowSignatures(of: frame)
        defer { previousSignatures = signatures }

        if slices.isEmpty {
            slices.append(frame)
            totalHeight = frame.height
            width = frame.width
            return frame.height
        }

        guard frame.width == width else { return 0 }
        guard let dy = Self.scrollOffset(previous: previousSignatures, current: signatures),
              dy > 0 else { return 0 }

        // The bottom `dy` rows of the new frame are new content.
        let newRect = CGRect(x: 0, y: frame.height - dy, width: width, height: dy)
        guard let slice = frame.cropping(to: newRect) else { return 0 }
        slices.append(slice)
        totalHeight += dy
        return dy
    }

    /// Compose all slices into the final tall image.
    func compose() -> CGImage? {
        guard !slices.isEmpty else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: totalHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CGContext origin is bottom-left; slices accumulate top-to-bottom.
        var y = totalHeight
        for slice in slices {
            y -= slice.height
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: slice.width, height: slice.height))
        }
        return ctx.makeImage()
    }

    // MARK: - Row matching

    /// FNV-1a hash over sampled pixels of each row.
    static func rowSignatures(of image: CGImage) -> [UInt64] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &buffer, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampleCount = min(64, width)
        let stride = max(1, width / sampleCount)
        var signatures = [UInt64](repeating: 0, count: height)

        for row in 0..<height {
            // CGContext rows are bottom-up; flip so index 0 = visual top row.
            let bufferRow = height - 1 - row
            var hash: UInt64 = 0xcbf29ce484222325
            let rowStart = bufferRow * bytesPerRow
            var x = 0
            while x < width {
                let p = rowStart + x * 4
                let pixel = UInt64(buffer[p]) << 16 | UInt64(buffer[p + 1]) << 8 | UInt64(buffer[p + 2])
                hash = (hash ^ pixel) &* 0x100000001b3
                x += stride
            }
            signatures[row] = hash
        }
        return signatures
    }

    /// Find dy >= 0 such that previous[dy...] == current[0 ..< h-dy]
    /// (content scrolled up by dy rows). Returns nil when no alignment is good.
    static func scrollOffset(previous: [UInt64], current: [UInt64]) -> Int? {
        let h = min(previous.count, current.count)
        guard h > 40 else { return nil }

        var bestDy: Int?
        var bestScore = 0.0
        let maxDy = h - 24 // require at least 24 overlapping rows

        for dy in 0...maxDy {
            let overlap = h - dy
            // Sample up to 120 rows of the overlap for speed.
            let step = max(1, overlap / 120)
            var matches = 0
            var total = 0
            var i = 0
            while i < overlap {
                if previous[dy + i] == current[i] { matches += 1 }
                total += 1
                i += step
            }
            let score = Double(matches) / Double(max(total, 1))
            if score > 0.92 {
                // Prefer the smallest dy with near-perfect overlap (dy 0 = no movement).
                if score > bestScore || (bestDy == nil) {
                    bestScore = score
                    bestDy = dy
                    if score > 0.995, dy > 0 { break }
                }
                if dy == 0, score > 0.98 {
                    return 0 // frame unchanged
                }
            }
        }
        return bestDy
    }
}
