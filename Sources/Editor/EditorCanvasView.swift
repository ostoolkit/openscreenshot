import SwiftUI
import AppKit

/// Scrollable, zoomable canvas hosting the live annotation surface.
struct EditorCanvasContainer: View {
    @ObservedObject var document: EditorDocument
    @Binding var zoom: CGFloat

    var body: some View {
        GeometryReader { geo in
            let comp = document.compositionSize
            let fit = min(geo.size.width / max(comp.width, 1),
                          geo.size.height / max(comp.height, 1),
                          1) * 0.96
            let scale = fit * zoom
            ScrollView([.horizontal, .vertical]) {
                EditorCanvasView(document: document, scale: scale)
                    .frame(width: comp.width * scale, height: comp.height * scale)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
    }
}

/// The composition: background + baked image + live annotation layer.
struct EditorCanvasView: View {
    @ObservedObject var document: EditorDocument
    let scale: CGFloat

    private enum DragMode {
        case draw
        case move(UUID)
        case idle
    }

    @State private var draft: Annotation?
    @State private var dragMode: DragMode?
    @State private var moveLast: CGPoint?
    @State private var moveDistance: CGFloat = 0
    @State private var didRegisterMoveUndo = false
    // Resize-handle drag bookkeeping.
    @State private var handleAnchor: CGPoint?
    @State private var handleOriginal: CGPoint?
    @State private var didRegisterHandleUndo = false
    @FocusState private var textFocused: Bool

    private var imageSize: CGSize {
        CGSize(width: document.bakedImage.width, height: document.bakedImage.height)
    }

    /// Distance from composition edge to the base image: canvas padding plus
    /// the extended-background margin.
    private var contentInset: CGFloat {
        document.padding + document.backgroundExtension
    }

    var body: some View {
        if document.tool == .crop {
            // Dedicated crop mode: the full original image with an adjustable,
            // re-editable crop window (non-destructive).
            CropModeView(document: document, scale: scale)
        } else {
            editingBody
        }
    }

    private var editingBody: some View {
        let comp = document.compositionSize
        let pad = document.padding * scale
        let inset = contentInset * scale

        return ZStack(alignment: .topLeading) {
            backgroundLayer
                .frame(width: comp.width * scale, height: comp.height * scale)

            imageLayer
                .offset(x: pad, y: pad)

            annotationLayer
                .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                .offset(x: inset, y: inset)

            selectionChrome
                .offset(x: inset, y: inset)

            textEditorOverlay
                .offset(x: inset, y: inset)
        }
        .contentShape(Rectangle())
        .gesture(canvasGesture)
    }

    // MARK: - Layers

    @ViewBuilder
    private var backgroundLayer: some View {
        switch document.background {
        case .none:
            CheckerboardView()
        case .solid(let rgba):
            rgba.color
        case .gradient(let index):
            let colors = CanvasBackground.gradients[index % CanvasBackground.gradients.count]
            LinearGradient(colors: [colors[0].color, colors[1].color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var imageLayer: some View {
        let ext = document.backgroundExtension
        let extWidth = (imageSize.width + ext * 2) * scale
        let extHeight = (imageSize.height + ext * 2) * scale
        return ZStack(alignment: .topLeading) {
            if ext > 0, let color = document.extensionColor {
                color.color
            }
            Image(decorative: document.bakedImage, scale: 1 / scale)
                .resizable()
                .interpolation(.high)
                .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                .offset(x: ext * scale, y: ext * scale)
        }
        .frame(width: extWidth, height: extHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: min(document.cornerRadius * scale,
                                                      extWidth / 2,
                                                      extHeight / 2)))
        .shadow(color: document.shadow && document.padding > 0 ? .black.opacity(0.5) : .clear,
                radius: 40 * scale, y: 12 * scale)
    }

    private var annotationLayer: some View {
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.scaleBy(x: scale, y: scale)
                for a in document.annotations {
                    if a.kind == .blur || a.kind == .pixelate { continue }
                    if a.id == document.editingTextID { continue } // live TextField shows it
                    AnnotationRenderer.draw(a, in: cg, canvasSize: imageSize)
                }
                if let draft {
                    if draft.kind == .blur || draft.kind == .pixelate {
                        // Show a marker while the redaction region is being drawn.
                        cg.setFillColor(CGColor(gray: 0.5, alpha: 0.5))
                        cg.fill(draft.rect)
                        cg.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                        cg.setLineWidth(1.5 / scale)
                        cg.stroke(draft.rect)
                    } else {
                        AnnotationRenderer.draw(draft, in: cg, canvasSize: imageSize)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Selection chrome & resize handles

    @ViewBuilder
    private var selectionChrome: some View {
        if document.editingTextID == nil,
           let selected = document.annotation(id: document.selectedID) {
            let bounds = AnnotationGeometry.bounds(for: selected, canvasSize: imageSize)
            Rectangle()
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: max(bounds.width * scale, 2), height: max(bounds.height * scale, 2))
                .offset(x: bounds.minX * scale, y: bounds.minY * scale)
                .allowsHitTesting(false)

            resizeHandles(for: selected)
        }
    }

    @ViewBuilder
    private func resizeHandles(for a: Annotation) -> some View {
        switch a.kind {
        case .line, .arrow:
            endpointHandle(a, isStart: true)
            endpointHandle(a, isStart: false)
        case .rect, .ellipse, .blur, .pixelate, .spotlight:
            cornerHandle(a, corner: .topLeft)
            cornerHandle(a, corner: .topRight)
            cornerHandle(a, corner: .bottomLeft)
            cornerHandle(a, corner: .bottomRight)
        default:
            EmptyView()
        }
    }

    private enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(of r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            }
        }

        var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }
    }

    private func cornerHandle(_ a: Annotation, corner: Corner) -> some View {
        handleView(at: corner.point(of: a.rect)) { newPoint in
            guard var current = document.annotation(id: a.id) else { return }
            if handleAnchor == nil {
                handleAnchor = corner.opposite.point(of: current.rect)
                handleOriginal = corner.point(of: current.rect)
                registerHandleUndoIfNeeded()
            }
            current.start = handleAnchor ?? current.start
            current.end = newPoint
            document.update(current)
        }
    }

    private func endpointHandle(_ a: Annotation, isStart: Bool) -> some View {
        handleView(at: isStart ? a.start : a.end) { newPoint in
            guard var current = document.annotation(id: a.id) else { return }
            if handleAnchor == nil {
                handleAnchor = isStart ? current.end : current.start
                handleOriginal = isStart ? current.start : current.end
                registerHandleUndoIfNeeded()
            }
            if isStart { current.start = newPoint } else { current.end = newPoint }
            document.update(current)
        }
    }

    private func registerHandleUndoIfNeeded() {
        if !didRegisterHandleUndo {
            document.registerUndo()
            didRegisterHandleUndo = true
        }
    }

    private func handleView(at point: CGPoint, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .contentShape(Circle().inset(by: -6))
            .position(x: point.x * scale, y: point.y * scale)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = handleOriginal ?? point
                        onDrag(CGPoint(x: origin.x + value.translation.width / scale,
                                       y: origin.y + value.translation.height / scale))
                    }
                    .onEnded { _ in
                        handleAnchor = nil
                        handleOriginal = nil
                        didRegisterHandleUndo = false
                    }
            )
    }

    // MARK: - Text editing overlay

    @ViewBuilder
    private var textEditorOverlay: some View {
        if let id = document.editingTextID,
           let annotation = document.annotation(id: id) {
            TextField("Text", text: Binding(
                get: { document.annotation(id: id)?.text ?? "" },
                set: { newValue in
                    var a = document.annotation(id: id) ?? annotation
                    a.text = newValue
                    document.update(a)
                }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: annotation.fontSize * scale, weight: .semibold))
                .foregroundStyle(annotation.color.color)
                .frame(minWidth: 120, maxWidth: 480)
                .fixedSize(horizontal: true, vertical: true)
                .background(Color.black.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
                .offset(x: annotation.start.x * scale, y: annotation.start.y * scale)
                .focused($textFocused)
                .onSubmit { commitTextEditing() }
                .onAppear { textFocused = true }
                .onChange(of: textFocused) { _, focused in
                    if !focused { commitTextEditing() }
                }
        }
    }

    private func commitTextEditing() {
        guard let id = document.editingTextID else { return }
        if let a = document.annotation(id: id),
           a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.annotations.removeAll { $0.id == id }
            if document.selectedID == id { document.selectedID = nil }
        }
        document.editingTextID = nil
    }

    // MARK: - Main gesture

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let inset = contentInset
                let point = CGPoint(x: value.location.x / scale - inset,
                                    y: value.location.y / scale - inset)
                let startPoint = CGPoint(x: value.startLocation.x / scale - inset,
                                         y: value.startLocation.y / scale - inset)
                handleDragChanged(point: point, startPoint: startPoint)
            }
            .onEnded { value in
                let inset = contentInset
                let point = CGPoint(x: value.location.x / scale - inset,
                                    y: value.location.y / scale - inset)
                let startPoint = CGPoint(x: value.startLocation.x / scale - inset,
                                         y: value.startLocation.y / scale - inset)
                handleDragEnded(point: point, startPoint: startPoint)
            }
    }

    /// Decide once per drag what it does: move an annotation or draw.
    private func decideDragMode(startPoint: CGPoint) -> DragMode {
        // Dragging from inside the selected annotation moves it, whatever the tool.
        if document.editingTextID == nil,
           let sel = document.annotation(id: document.selectedID),
           AnnotationGeometry.bounds(for: sel, canvasSize: imageSize)
               .insetBy(dx: -6, dy: -6).contains(startPoint) {
            return .move(sel.id)
        }

        if document.tool == .select {
            if let hit = document.annotations.reversed().first(where: {
                AnnotationGeometry.hitTest($0, point: startPoint, canvasSize: imageSize)
            }) {
                document.selectedID = hit.id
                return .move(hit.id)
            }
            document.selectedID = nil
            return .idle
        }

        // Text tool over an existing text annotation: edit instead of stacking.
        if document.tool == .text,
           let hit = document.annotations.reversed().first(where: {
               $0.kind == .text && AnnotationGeometry.hitTest($0, point: startPoint, canvasSize: imageSize)
           }) {
            document.selectedID = hit.id
            return .move(hit.id)
        }

        return .draw
    }

    private func handleDragChanged(point: CGPoint, startPoint: CGPoint) {
        if dragMode == nil {
            dragMode = decideDragMode(startPoint: startPoint)
            moveLast = startPoint
            moveDistance = 0
            didRegisterMoveUndo = false
        }

        switch dragMode {
        case .move(let id):
            guard var a = document.annotation(id: id) else { return }
            let last = moveLast ?? point
            let dx = point.x - last.x
            let dy = point.y - last.y
            moveDistance += abs(dx) + abs(dy)
            if moveDistance > 2 {
                if !didRegisterMoveUndo {
                    document.registerUndo()
                    didRegisterMoveUndo = true
                }
                a.translate(dx: dx, dy: dy)
                document.update(a)
            }
            moveLast = point

        case .draw:
            switch document.tool {
            case .text, .counter:
                break // click tools, handled on end
            case .freehand, .highlighter:
                if draft == nil {
                    var a = Annotation(kind: document.tool == .freehand ? .freehand : .highlighter,
                                       start: startPoint, end: point)
                    a.color = document.color
                    a.lineWidth = document.lineWidth
                    a.points = [startPoint]
                    draft = a
                }
                draft?.points.append(point)
                draft?.end = point
            default:
                if draft == nil {
                    var a = Annotation(kind: kind(for: document.tool), start: startPoint, end: point)
                    a.color = document.color
                    a.lineWidth = document.lineWidth
                    a.filled = document.fillShapes
                    draft = a
                }
                draft?.end = point
            }

        case .idle, nil:
            break
        }
    }

    private func handleDragEnded(point: CGPoint, startPoint: CGPoint) {
        defer {
            draft = nil
            dragMode = nil
            moveLast = nil
            moveDistance = 0
        }

        switch dragMode {
        case .move(let id):
            // A click (no real movement) on a text annotation opens the editor.
            if moveDistance < 3,
               let a = document.annotation(id: id) {
                document.selectedID = id
                if a.kind == .text {
                    document.editingTextID = id
                }
            }

        case .idle, nil:
            break

        case .draw:
            switch document.tool {
            case .text:
                var a = Annotation(kind: .text, start: point, end: point)
                a.color = document.color
                a.fontSize = document.fontSize
                document.add(a)
                document.selectedID = a.id
                document.editingTextID = a.id

            case .counter:
                var a = Annotation(kind: .counter, start: point, end: point)
                a.color = document.color
                a.fontSize = document.fontSize
                a.number = document.nextCounterNumber
                document.add(a)
                document.selectedID = a.id

            default:
                if var a = draft {
                    let dragDistance = hypot(point.x - startPoint.x, point.y - startPoint.y)
                    guard dragDistance > 3 else { break }
                    a.end = point
                    document.add(a)
                    document.selectedID = a.id
                }
            }
        }
    }

    private func kind(for tool: EditorTool) -> Annotation.Kind {
        switch tool {
        case .arrow: .arrow
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        case .blur: .blur
        case .pixelate: .pixelate
        case .spotlight: .spotlight
        default: .rect
        }
    }
}

/// Interactive, re-editable crop mode: shows the FULL original image with the
/// current crop as an adjustable window (handles, move, redraw, thirds grid).
/// Cropping is non-destructive, so re-entering the tool lets you expand the
/// region back out.
struct CropModeView: View {
    @ObservedObject var document: EditorDocument
    let scale: CGFloat

    @State private var rect: CGRect = .zero
    @State private var dragAnchor: CGRect?
    @State private var dragKind: DragKind = .none

    private enum DragKind {
        case none
        case move
        case draw(start: CGPoint)
    }

    private var fullSize: CGSize {
        CGSize(width: document.fullImage.width, height: document.fullImage.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: document.fullImage, scale: 1 / scale)
                .resizable()
                .interpolation(.high)
                .frame(width: fullSize.width * scale, height: fullSize.height * scale)

            // Dim everything outside the crop window.
            Path { p in
                p.addRect(CGRect(origin: .zero,
                                 size: CGSize(width: fullSize.width * scale,
                                              height: fullSize.height * scale)))
                p.addRect(scaled(rect))
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Border + rule-of-thirds grid.
            Path { p in
                let r = scaled(rect)
                p.addRect(r)
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY))
                    p.addLine(to: CGPoint(x: x, y: r.maxY))
                    let y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: r.minX, y: y))
                    p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.9), lineWidth: 1)
            .allowsHitTesting(false)

            handles

            dimensionsLabel

            controlBar
        }
        .frame(width: fullSize.width * scale, height: fullSize.height * scale)
        .contentShape(Rectangle())
        .gesture(cropGesture)
        .onAppear {
            rect = document.cropRect ?? document.fullRect
        }
    }

    private func scaled(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale, y: r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }

    private var dimensionsLabel: some View {
        let r = scaled(rect)
        return Text("\(Int(rect.width)) × \(Int(rect.height))")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .offset(x: max(r.minX + 6, 4), y: max(r.minY + 6, 4))
            .allowsHitTesting(false)
    }

    private var controlBar: some View {
        let r = scaled(rect)
        let below = r.maxY + 50 < fullSize.height * scale
        return HStack(spacing: 8) {
            Button("Cancel") {
                document.tool = .select
            }
            if document.cropRect != nil {
                Button("Remove Crop") {
                    document.setCrop(nil)
                }
            }
            Button("Apply") {
                document.setCrop(rect)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .position(x: min(max(r.midX, 130), fullSize.width * scale - 130),
                  y: below ? r.maxY + 30 : max(r.minY - 30, 24))
    }

    // MARK: - Handles

    private var handles: some View {
        ForEach(Array(SelectionHandle.allCases.enumerated()), id: \.offset) { _, handle in
            let pos = position(of: handle, in: scaled(rect))
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .contentShape(Circle().inset(by: -8))
                .position(pos)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragAnchor == nil { dragAnchor = rect }
                            guard let anchor = dragAnchor else { return }
                            let dx = value.translation.width / scale
                            let dy = value.translation.height / scale
                            rect = clamped(resize(anchor, handle: handle, dx: dx, dy: dy))
                        }
                        .onEnded { _ in dragAnchor = nil }
                )
        }
    }

    /// Handle positions in view space. SelectionHandle's "top" refers to the
    /// AppKit-global top; in view coordinates (y down) that's minY.
    private func position(of handle: SelectionHandle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    /// Resize in image coordinates (y down): "top" handles move minY.
    private func resize(_ r: CGRect, handle: SelectionHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .top: minY += dy
        case .topRight: maxX += dx; minY += dy
        case .left: minX += dx
        case .right: maxX += dx
        case .bottomLeft: minX += dx; maxY += dy
        case .bottom: maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func clamped(_ r: CGRect) -> CGRect {
        var c = r.intersection(document.fullRect)
        if c.isNull || c.isEmpty {
            c = rect
        }
        if c.width < 20 { c.size.width = 20 }
        if c.height < 20 { c.size.height = 20 }
        return c.intersection(document.fullRect)
    }

    // MARK: - Move / redraw gesture

    private var cropGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)

                if case .none = dragKind {
                    if rect.insetBy(dx: -6, dy: -6).contains(start) {
                        dragKind = .move
                        dragAnchor = rect
                    } else {
                        dragKind = .draw(start: start)
                    }
                }

                switch dragKind {
                case .move:
                    guard let anchor = dragAnchor else { return }
                    var moved = anchor.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
                    moved.origin.x = min(max(moved.origin.x, 0), document.fullRect.width - moved.width)
                    moved.origin.y = min(max(moved.origin.y, 0), document.fullRect.height - moved.height)
                    rect = moved
                case .draw(let s):
                    rect = clamped(CGRect(x: min(s.x, point.x), y: min(s.y, point.y),
                                          width: abs(point.x - s.x), height: abs(point.y - s.y)))
                case .none:
                    break
                }
            }
            .onEnded { _ in
                dragKind = .none
                dragAnchor = nil
            }
    }
}

/// Transparency checkerboard shown when there is no canvas background.
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.init(white: 0.93)))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color(.init(white: 0.82)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}
