import AppKit
import SwiftUI

enum SelectionPurpose {
    case screenshot
    case ocr
    case recordVideo
    case recordGIF
    case scrolling
    case allInOne

    /// Whether mouse-up enters an adjustable confirm stage with a toolbar
    /// instead of committing immediately.
    var usesConfirmStage: Bool {
        switch self {
        case .allInOne, .recordVideo, .recordGIF: true
        default: false
        }
    }
}

enum SelectionOutcome {
    case cancelled
    /// Cropped from the frozen snapshot.
    case areaImage(CGImage, rect: NSRect, screen: NSScreen, purpose: SelectionPurpose, timerDelay: Int?)
    case window(WindowInfo, purpose: SelectionPurpose)
    case recordArea(rect: NSRect, screen: NSScreen, gif: Bool)
    case scrollArea(rect: NSRect, screen: NSScreen)
}

/// Shared state for all per-screen selection panels.
@MainActor
final class SelectionModel: ObservableObject {
    let purpose: SelectionPurpose
    let timerDelay: Int?
    let windows: [WindowInfo]
    /// Frozen snapshot per displayID.
    let snapshots: [CGDirectDisplayID: CaptureEngine.DisplaySnapshot]

    /// Global AppKit coordinates.
    @Published var mouseLocation: NSPoint = NSEvent.mouseLocation
    @Published var dragOrigin: NSPoint?
    @Published var selectionRect: NSRect = .zero
    @Published var isDragging = false
    @Published var confirmStage = false
    @Published var hoveredWindow: WindowInfo?
    @Published var spaceHeld = false
    @Published var shiftHeld = false
    /// When true the session is in window-picking mode (hover highlight +
    /// click captures). Area mode never highlights windows.
    @Published var windowMode: Bool

    /// The screen on which the drag started (capture target).
    @Published var activeScreen: NSScreen?

    weak var controller: SelectionOverlayController?

    init(purpose: SelectionPurpose,
         timerDelay: Int?,
         windowMode: Bool,
         windows: [WindowInfo],
         snapshots: [CGDirectDisplayID: CaptureEngine.DisplaySnapshot]) {
        self.purpose = purpose
        self.timerDelay = timerDelay
        self.windowMode = windowMode
        self.windows = windows
        self.snapshots = snapshots
    }

    var hasSelection: Bool { selectionRect.width > 2 && selectionRect.height > 2 }

    func snapshot(for screen: NSScreen) -> CaptureEngine.DisplaySnapshot? {
        snapshots[screen.displayID]
    }

    // MARK: - Mouse handling (global AppKit coordinates)

    private var lastDragPoint: NSPoint?

    func beginDrag(at point: NSPoint, on screen: NSScreen) {
        dragOrigin = point
        lastDragPoint = point
        activeScreen = screen
        isDragging = true
        confirmStage = false
        selectionRect = NSRect(origin: point, size: .zero)
    }

    func continueDrag(to point: NSPoint) {
        guard var origin = dragOrigin, let last = lastDragPoint else { return }
        if spaceHeld {
            // Holding space moves the in-progress selection.
            origin.x += point.x - last.x
            origin.y += point.y - last.y
            dragOrigin = origin
        }
        lastDragPoint = point
        var rect = NSRect(x: min(origin.x, point.x),
                          y: min(origin.y, point.y),
                          width: abs(point.x - origin.x),
                          height: abs(point.y - origin.y))
        if shiftHeld {
            // Constrain to a square.
            let side = max(rect.width, rect.height)
            rect.size = NSSize(width: side, height: side)
            if point.x < origin.x { rect.origin.x = origin.x - side }
            if point.y < origin.y { rect.origin.y = origin.y - side }
        }
        selectionRect = snapped(rect)
        mouseLocation = point
    }

    func endDrag(at point: NSPoint) {
        isDragging = false
        let clickDistance = dragOrigin.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
        dragOrigin = nil
        lastDragPoint = nil

        if clickDistance < 4 || !hasSelection {
            // Treat as a click: in window mode, capture the hovered window.
            if windowMode, let window = hoveredWindow {
                controller?.commitWindow(window)
            }
            // In area mode a bare click does nothing; stay active.
            selectionRect = .zero
            return
        }

        if purpose.usesConfirmStage {
            confirmStage = true
        } else {
            controller?.commitArea(selectionRect)
        }
    }

    func updateHover(to point: NSPoint) {
        mouseLocation = point
        guard windowMode, !isDragging, !confirmStage else {
            if hoveredWindow != nil { hoveredWindow = nil }
            return
        }
        hoveredWindow = WindowInfo.window(at: Coordinates.cgPoint(fromAppKit: point), in: windows)
    }

    // MARK: - Confirm-stage adjustments

    func moveSelection(dx: CGFloat, dy: CGFloat) {
        selectionRect = selectionRect.offsetBy(dx: dx, dy: dy)
    }

    func resizeSelection(handle: SelectionHandle, to point: NSPoint) {
        var r = selectionRect
        switch handle {
        case .topLeft:
            r = NSRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: point.y - r.minY)
        case .top:
            r = NSRect(x: r.minX, y: r.minY, width: r.width, height: point.y - r.minY)
        case .topRight:
            r = NSRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: point.y - r.minY)
        case .left:
            r = NSRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: r.height)
        case .right:
            r = NSRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: r.height)
        case .bottomLeft:
            r = NSRect(x: point.x, y: point.y, width: r.maxX - point.x, height: r.maxY - point.y)
        case .bottom:
            r = NSRect(x: r.minX, y: point.y, width: r.width, height: r.maxY - point.y)
        case .bottomRight:
            r = NSRect(x: r.minX, y: point.y, width: point.x - r.minX, height: r.maxY - point.y)
        }
        if r.width < 0 { r.origin.x += r.width; r.size.width = -r.width }
        if r.height < 0 { r.origin.y += r.height; r.size.height = -r.height }
        selectionRect = r
    }

    // MARK: - Snapping

    /// Snap edges to nearby window edges and screen edges.
    private func snapped(_ rect: NSRect) -> NSRect {
        guard !spaceHeld else { return rect }
        let threshold: CGFloat = 8
        var r = rect
        var xEdges: [CGFloat] = []
        var yEdges: [CGFloat] = []
        for screen in NSScreen.screens {
            xEdges.append(contentsOf: [screen.frame.minX, screen.frame.maxX])
            yEdges.append(contentsOf: [screen.frame.minY, screen.frame.maxY])
        }
        for w in windows.prefix(20) {
            let f = w.appKitFrame
            xEdges.append(contentsOf: [f.minX, f.maxX])
            yEdges.append(contentsOf: [f.minY, f.maxY])
        }
        func snapValue(_ v: CGFloat, edges: [CGFloat]) -> CGFloat? {
            edges.first { abs($0 - v) <= threshold }
        }
        // Snap the moving edge only (the one nearest the cursor); cheap approach:
        // snap min/max independently without changing the opposite edge.
        if let s = snapValue(r.minX, edges: xEdges) { r.size.width += r.minX - s; r.origin.x = s }
        if let s = snapValue(r.maxX, edges: xEdges) { r.size.width = s - r.minX }
        if let s = snapValue(r.minY, edges: yEdges) { r.size.height += r.minY - s; r.origin.y = s }
        if let s = snapValue(r.maxY, edges: yEdges) { r.size.height = s - r.minY }
        return r
    }
}

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
}
