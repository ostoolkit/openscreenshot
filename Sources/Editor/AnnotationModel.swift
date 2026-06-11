import AppKit
import SwiftUI

struct RGBA: Equatable, Codable {
    var r: Double, g: Double, b: Double, a: Double

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }

    static let red = RGBA(r: 0.93, g: 0.26, b: 0.21, a: 1)
    static let orange = RGBA(r: 1.0, g: 0.58, b: 0.0, a: 1)
    static let yellow = RGBA(r: 1.0, g: 0.84, b: 0.04, a: 1)
    static let green = RGBA(r: 0.20, g: 0.78, b: 0.35, a: 1)
    static let blue = RGBA(r: 0.04, g: 0.52, b: 1.0, a: 1)
    static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87, a: 1)
    static let black = RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        r = ns.redComponent; g = ns.greenComponent; b = ns.blueComponent; a = ns.alphaComponent
    }
}

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, freehand, highlighter, text, counter
    case blur, pixelate, spotlight, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .spotlight: "flashlight.on.fill"
        case .crop: "crop"
        }
    }

    var help: String {
        switch self {
        case .select: "Select & Move (V)"
        case .arrow: "Arrow (A)"
        case .line: "Line (L)"
        case .rect: "Rectangle (R)"
        case .ellipse: "Ellipse (O)"
        case .freehand: "Pen (P)"
        case .highlighter: "Highlighter (H)"
        case .text: "Text (T)"
        case .counter: "Counter (C)"
        case .blur: "Blur (B)"
        case .pixelate: "Pixelate"
        case .spotlight: "Spotlight"
        case .crop: "Crop"
        }
    }
}

/// One annotation object, in base-image pixel coordinates (top-left origin).
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow, line, rect, ellipse, freehand, highlighter, text, counter
        case blur, pixelate, spotlight
    }

    let id: UUID
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBA = .red
    var lineWidth: CGFloat = 8
    var filled = false
    var text: String = ""
    var fontSize: CGFloat = 32
    var number: Int = 1

    init(id: UUID = UUID(), kind: Kind, start: CGPoint, end: CGPoint) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

/// Canvas styling applied around the screenshot layer. Captures (e.g. window
/// captures with shadow) carry one of these so the editor opens with the
/// padding/shadow/background as live, removable settings instead of baked
/// pixels.
struct CanvasStyle: Equatable {
    var padding: CGFloat = 0
    var background: CanvasBackground = .none
    var cornerRadius: CGFloat = 0
    var shadow = false

    static let plain = CanvasStyle()

    /// Default look of a window capture: transparent margin + drop shadow.
    /// Values are in points; call `scaled(by:)` with the image scale.
    static let windowCapture = CanvasStyle(padding: 48, background: .none,
                                           cornerRadius: 0, shadow: true)

    var isPlain: Bool { self == .plain }

    func scaled(by scale: CGFloat) -> CanvasStyle {
        var c = self
        c.padding = (padding * scale).rounded()
        c.cornerRadius = (cornerRadius * scale).rounded()
        return c
    }
}

enum CanvasBackground: Equatable {
    case none
    case solid(RGBA)
    case gradient(Int)

    static let gradients: [[RGBA]] = [
        [RGBA(r: 0.35, g: 0.35, b: 0.95, a: 1), RGBA(r: 0.85, g: 0.35, b: 0.85, a: 1)],
        [RGBA(r: 0.99, g: 0.55, b: 0.30, a: 1), RGBA(r: 0.95, g: 0.25, b: 0.45, a: 1)],
        [RGBA(r: 0.15, g: 0.70, b: 0.75, a: 1), RGBA(r: 0.20, g: 0.35, b: 0.80, a: 1)],
        [RGBA(r: 0.30, g: 0.85, b: 0.50, a: 1), RGBA(r: 0.10, g: 0.55, b: 0.60, a: 1)],
        [RGBA(r: 0.95, g: 0.80, b: 0.45, a: 1), RGBA(r: 0.90, g: 0.45, b: 0.25, a: 1)],
        [RGBA(r: 0.25, g: 0.25, b: 0.32, a: 1), RGBA(r: 0.08, g: 0.08, b: 0.12, a: 1)],
    ]
}

/// The editor's document: base image + annotations + canvas styling + undo.
@MainActor
final class EditorDocument: ObservableObject {
    @Published var baseImage: CGImage {
        didSet { rebakeBase() }
    }
    /// Base image with blur/pixelate regions baked in (preview & export source).
    @Published private(set) var bakedImage: CGImage

    @Published var annotations: [Annotation] = [] {
        didSet {
            let redactions = annotations.filter { $0.kind == .blur || $0.kind == .pixelate }
            if redactions != lastRedactions {
                lastRedactions = redactions
                rebakeBase()
            }
        }
    }
    private var lastRedactions: [Annotation] = []

    @Published var selectedID: UUID?
    @Published var editingTextID: UUID?
    @Published var tool: EditorTool = .arrow

    // Tool options
    @Published var color: RGBA = .red
    @Published var strokeWidth: CGFloat = 8
    @Published var fillShapes = false
    @Published var fontSizeValue: CGFloat = 32

    // Canvas / background
    @Published var padding: CGFloat = 0
    @Published var background: CanvasBackground = .none
    @Published var cornerRadius: CGFloat = 0
    @Published var shadow = false

    var lineWidth: CGFloat { strokeWidth }
    var fontSize: CGFloat { fontSizeValue }

    var nextCounterNumber: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    /// Full composition size including padding.
    var compositionSize: CGSize {
        CGSize(width: CGFloat(baseImage.width) + padding * 2,
               height: CGFloat(baseImage.height) + padding * 2)
    }

    init(image: CGImage, canvas: CanvasStyle = .plain) {
        baseImage = image
        bakedImage = image
        padding = canvas.padding
        background = canvas.background
        cornerRadius = canvas.cornerRadius
        shadow = canvas.shadow
    }

    var canvasStyle: CanvasStyle {
        CanvasStyle(padding: padding, background: background,
                    cornerRadius: cornerRadius, shadow: shadow)
    }

    // MARK: - Undo

    private struct Snapshot {
        let annotations: [Annotation]
        let baseImage: CGImage
        let padding: CGFloat
        let background: CanvasBackground
        let cornerRadius: CGFloat
        let shadow: Bool
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var currentSnapshot: Snapshot {
        Snapshot(annotations: annotations, baseImage: baseImage, padding: padding,
                 background: background, cornerRadius: cornerRadius, shadow: shadow)
    }

    /// Call before any mutation.
    func registerUndo() {
        undoStack.append(currentSnapshot)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        apply(snap)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        apply(snap)
    }

    private func apply(_ snap: Snapshot) {
        annotations = snap.annotations
        if baseImage !== snap.baseImage { baseImage = snap.baseImage }
        padding = snap.padding
        background = snap.background
        cornerRadius = snap.cornerRadius
        shadow = snap.shadow
        selectedID = nil
        editingTextID = nil
    }

    // MARK: - Mutations

    func add(_ annotation: Annotation) {
        registerUndo()
        annotations.append(annotation)
    }

    func update(_ annotation: Annotation) {
        if let i = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[i] = annotation
        }
    }

    func annotation(id: UUID?) -> Annotation? {
        annotations.first { $0.id == id }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        registerUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func applyCrop(_ rect: CGRect) {
        let pixelRect = rect.intersection(CGRect(x: 0, y: 0,
                                                 width: baseImage.width,
                                                 height: baseImage.height)).integral
        guard pixelRect.width > 4, pixelRect.height > 4,
              let cropped = baseImage.cropping(to: pixelRect) else { return }
        registerUndo()
        baseImage = cropped
        for i in annotations.indices {
            annotations[i].translate(dx: -pixelRect.minX, dy: -pixelRect.minY)
        }
        tool = .select
    }

    private func rebakeBase() {
        let redactions = annotations.filter { $0.kind == .blur || $0.kind == .pixelate }
        bakedImage = AnnotationRenderer.bake(base: baseImage, redactions: redactions)
    }

    // MARK: - Export

    func renderFinal() -> CGImage? {
        AnnotationRenderer.render(document: self)
    }
}
