import AppKit
import CoreImage
import CoreText
import CoreImage.CIFilterBuiltins

/// Shared geometry: CGPaths for annotations in top-left-origin image pixel
/// coordinates. Used by both the live SwiftUI canvas and the CG export path.
enum AnnotationGeometry {
    static func shapePath(for a: Annotation, canvasSize: CGSize? = nil) -> CGPath? {
        switch a.kind {
        case .line:
            let p = CGMutablePath()
            p.move(to: a.start)
            p.addLine(to: a.end)
            return p

        case .arrow:
            return arrowPath(from: a.start, to: a.end, lineWidth: a.lineWidth)

        case .rect, .blur, .pixelate:
            return safeRoundedRect(a.rect, radius: a.kind == .rect ? 2 : 0)

        case .ellipse:
            return CGPath(ellipseIn: a.rect, transform: nil)

        case .freehand, .highlighter:
            guard a.points.count > 1 else { return nil }
            let p = CGMutablePath()
            p.move(to: a.points[0])
            for pt in a.points.dropFirst() {
                p.addLine(to: pt)
            }
            return p

        case .counter:
            let r = counterRadius(for: a)
            return CGPath(ellipseIn: CGRect(x: a.start.x - r, y: a.start.y - r,
                                            width: r * 2, height: r * 2), transform: nil)

        case .spotlight:
            guard let canvasSize else { return nil }
            let p = CGMutablePath()
            p.addRect(CGRect(origin: .zero, size: canvasSize))
            p.addPath(safeRoundedRect(a.rect, radius: 6))
            return p

        case .text:
            return nil
        }
    }

    /// CGPath(roundedRect:) traps when the radius exceeds half the rect size
    /// (which happens on the first ticks of a drag). Clamp defensively.
    static func safeRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = rect.standardized
        let radius = min(radius, r.width / 2, r.height / 2)
        guard radius > 0, r.width > 0.5, r.height > 0.5 else {
            return CGPath(rect: r, transform: nil)
        }
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Arrow rendered as one filled path: tapered shaft + head.
    static func arrowPath(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> CGPath {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let angle = atan2(dy, dx)

        let headLength = min(max(lineWidth * 3.2, 14), length * 0.5)
        let headWidth = headLength * 0.9
        let tailWidth = max(lineWidth * 0.35, 1.5)
        let shaftWidth = max(lineWidth * 0.9, 2)
        let shaftLength = length - headLength

        // Build in local space (arrow along +x), then rotate/translate.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -tailWidth / 2))
        p.addLine(to: CGPoint(x: shaftLength, y: -shaftWidth / 2))
        p.addLine(to: CGPoint(x: shaftLength, y: -headWidth / 2))
        p.addLine(to: CGPoint(x: length, y: 0))
        p.addLine(to: CGPoint(x: shaftLength, y: headWidth / 2))
        p.addLine(to: CGPoint(x: shaftLength, y: shaftWidth / 2))
        p.addLine(to: CGPoint(x: 0, y: tailWidth / 2))
        p.closeSubpath()

        var transform = CGAffineTransform(translationX: start.x, y: start.y)
            .rotated(by: angle)
        return p.copy(using: &transform) ?? p
    }

    static func counterRadius(for a: Annotation) -> CGFloat {
        max(a.fontSize * 0.75, 18)
    }

    static func textAttributes(for a: Annotation) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
            .foregroundColor: a.color.nsColor,
        ]
    }

    static func textSize(for a: Annotation) -> CGSize {
        let string = a.text.isEmpty ? " " : a.text
        return (string as NSString).size(withAttributes: textAttributes(for: a))
    }

    /// Bounding rect used for hit-testing and selection chrome.
    static func bounds(for a: Annotation, canvasSize: CGSize) -> CGRect {
        switch a.kind {
        case .text:
            let size = textSize(for: a)
            return CGRect(origin: a.start, size: size).insetBy(dx: -6, dy: -6)
        case .counter:
            let r = counterRadius(for: a)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        case .spotlight:
            return a.rect
        default:
            guard let path = shapePath(for: a, canvasSize: canvasSize) else { return a.rect }
            return path.boundingBox.insetBy(dx: -a.lineWidth, dy: -a.lineWidth)
        }
    }

    static func hitTest(_ a: Annotation, point: CGPoint, canvasSize: CGSize) -> Bool {
        switch a.kind {
        case .text, .counter, .spotlight, .blur, .pixelate:
            return bounds(for: a, canvasSize: canvasSize).contains(point)
        case .rect, .ellipse:
            guard let path = shapePath(for: a, canvasSize: canvasSize) else { return false }
            if a.filled, path.contains(point) { return true }
            let stroked = path.copy(strokingWithWidth: a.lineWidth + 12,
                                    lineCap: .round, lineJoin: .round, miterLimit: 10)
            return stroked.contains(point)
        case .arrow:
            guard let path = shapePath(for: a, canvasSize: canvasSize) else { return false }
            let stroked = path.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 10)
            return path.contains(point) || stroked.contains(point)
        default:
            guard let path = shapePath(for: a, canvasSize: canvasSize) else { return false }
            let stroked = path.copy(strokingWithWidth: a.lineWidth + 12,
                                    lineCap: .round, lineJoin: .round, miterLimit: 10)
            return stroked.contains(point)
        }
    }
}

/// CGContext rendering for export, plus blur/pixelate baking.
@MainActor
enum AnnotationRenderer {
    // MARK: - Redaction baking

    static func bake(base: CGImage, redactions: [Annotation]) -> CGImage {
        guard !redactions.isEmpty else { return base }
        let ciContext = CIContext()
        let baseCI = CIImage(cgImage: base)
        var output = baseCI
        let height = CGFloat(base.height)

        for redaction in redactions {
            let r = redaction.rect
            guard r.width > 2, r.height > 2 else { continue }
            // CIImage coordinates are bottom-left.
            let ciRect = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)

            // Intensity comes from the annotation's size slider (lineWidth
            // 2–24), NOT the region size — sizing blocks by region made large
            // regions look like blown-up content instead of pixelation.
            let filtered: CIImage
            if redaction.kind == .blur {
                let f = CIFilter.gaussianBlur()
                f.inputImage = output.clampedToExtent()
                f.radius = Float(max(4, redaction.lineWidth * 2.2))
                filtered = f.outputImage ?? output
            } else {
                let f = CIFilter.pixellate()
                f.inputImage = output.clampedToExtent()
                f.scale = Float(max(6, redaction.lineWidth * 1.6))
                f.center = CGPoint(x: ciRect.midX, y: ciRect.midY)
                filtered = f.outputImage ?? output
            }
            output = filtered.cropped(to: ciRect).composited(over: output)
        }

        guard let result = ciContext.createCGImage(output, from: baseCI.extent) else { return base }
        return result
    }

    // MARK: - Final composition

    static func render(document: EditorDocument) -> CGImage? {
        compose(image: document.bakedImage,
                canvas: document.canvasStyle,
                annotations: document.annotations)
    }

    /// Compose a screenshot with canvas styling (padding, background, rounded
    /// corners, shadow) and optional annotations. Also used at capture time so
    /// window captures get their default look through the same pipeline the
    /// editor can later modify.
    static func compose(image: CGImage,
                        canvas: CanvasStyle,
                        annotations: [Annotation] = []) -> CGImage? {
        let padding = max(0, canvas.padding)
        let size = CGSize(width: CGFloat(image.width) + padding * 2,
                          height: CGFloat(image.height) + padding * 2)
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 1. Background (context is bottom-left; backgrounds are symmetric enough).
        switch canvas.background {
        case .none:
            break
        case .solid(let rgba):
            ctx.setFillColor(rgba.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        case .gradient(let index):
            let colors = CanvasBackground.gradients[index % CanvasBackground.gradients.count]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [colors[0].cgColor, colors[1].cgColor] as CFArray,
                                      locations: [0, 1])!
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size.height),
                                   end: CGPoint(x: size.width, y: 0),
                                   options: [])
        }

        // 2. Screenshot layer. Round the corners in a separate pass, then draw
        // with a context shadow: the shadow follows the drawn image's alpha
        // contour, so it works for opaque area captures and transparent-edged
        // window captures alike (no opaque backing needed — which would peek
        // out from behind transparent corners).
        var layer = image
        if canvas.cornerRadius > 0, let rounded = roundedCorners(image, radius: canvas.cornerRadius) {
            layer = rounded
        }
        let imageRect = CGRect(x: padding, y: padding,
                               width: CGFloat(image.width), height: CGFloat(image.height))
        ctx.saveGState()
        if canvas.shadow, padding > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40,
                          color: CGColor(gray: 0, alpha: 0.5))
        }
        ctx.draw(layer, in: imageRect)
        ctx.restoreGState()

        // 3. Annotations: flip to top-left coords offset by padding.
        guard !annotations.isEmpty else { return ctx.makeImage() }
        ctx.saveGState()
        ctx.translateBy(x: padding, y: size.height - padding)
        ctx.scaleBy(x: 1, y: -1)
        let canvasSize = CGSize(width: image.width, height: image.height)
        for a in annotations where a.kind != .blur && a.kind != .pixelate {
            draw(a, in: ctx, canvasSize: canvasSize)
        }
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// Clip an image to rounded corners in its own transparent layer.
    /// (Clipping in the main context would clip the shadow away too.)
    private static func roundedCorners(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.addPath(AnnotationGeometry.safeRoundedRect(rect, radius: radius))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Draw one annotation into a context already transformed to
    /// top-left-origin coordinates (y down).
    static func draw(_ a: Annotation, in ctx: CGContext, canvasSize: CGSize) {
        switch a.kind {
        case .arrow, .counter:
            guard let path = AnnotationGeometry.shapePath(for: a, canvasSize: canvasSize) else { return }
            ctx.setFillColor(a.color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            if a.kind == .counter {
                drawCounterNumber(a, in: ctx)
            }

        case .rect, .ellipse:
            guard let path = AnnotationGeometry.shapePath(for: a, canvasSize: canvasSize) else { return }
            if a.filled {
                ctx.setFillColor(a.color.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(a.lineWidth)
                ctx.addPath(path)
                ctx.strokePath()
            }

        case .line, .freehand:
            guard let path = AnnotationGeometry.shapePath(for: a, canvasSize: canvasSize) else { return }
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()

        case .highlighter:
            guard let path = AnnotationGeometry.shapePath(for: a, canvasSize: canvasSize) else { return }
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            var c = a.color
            c.a = 0.45
            ctx.setStrokeColor(c.cgColor)
            ctx.setLineWidth(max(a.lineWidth * 2.4, 18))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

        case .spotlight:
            guard let path = AnnotationGeometry.shapePath(for: a, canvasSize: canvasSize) else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)

        case .text:
            drawText(a, in: ctx)

        case .blur, .pixelate:
            break // baked into the base image
        }
    }

    private static func drawCounterNumber(_ a: Annotation, in ctx: CGContext) {
        let r = AnnotationGeometry.counterRadius(for: a)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r * 1.05, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: "\(a.number)", attributes: attrs)
        let line = CTLineCreateWithAttributedString(string)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        // Un-flip locally so glyphs render upright.
        ctx.translateBy(x: a.start.x - lineBounds.width / 2,
                        y: a.start.y + lineBounds.height / 2 + lineBounds.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let attrs = AnnotationGeometry.textAttributes(for: a)
        var y = a.start.y
        let lineHeight = AnnotationGeometry.textSize(for: a).height / CGFloat(max(a.text.components(separatedBy: "\n").count, 1))
        for lineText in a.text.components(separatedBy: "\n") {
            let string = NSAttributedString(string: lineText.isEmpty ? " " : lineText, attributes: attrs)
            let line = CTLineCreateWithAttributedString(string)
            ctx.saveGState()
            ctx.translateBy(x: a.start.x, y: y + lineHeight * 0.8)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            y += lineHeight
        }
    }
}
