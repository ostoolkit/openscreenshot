import SwiftUI
import AppKit

/// The selection UI rendered on one screen's overlay panel.
struct SelectionScreenView: View {
    @ObservedObject var model: SelectionModel
    let screen: NSScreen

    @State private var adjustMode: AdjustMode = .none

    private enum AdjustMode {
        case none
        case moving(last: NSPoint)
        case drawing
    }

    private var screenSize: CGSize { screen.frame.size }

    // MARK: - Coordinate conversion (view local, top-left origin <-> AppKit global)

    private func global(fromLocal p: CGPoint) -> NSPoint {
        NSPoint(x: screen.frame.minX + p.x, y: screen.frame.maxY - p.y)
    }

    private func local(fromGlobal p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
    }

    private func localRect(fromGlobal r: NSRect) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX,
               y: screen.frame.maxY - r.maxY,
               width: r.width, height: r.height)
    }

    private var selectionLocal: CGRect { localRect(fromGlobal: model.selectionRect) }
    private var mouseLocal: CGPoint { local(fromGlobal: model.mouseLocation) }
    private var mouseOnThisScreen: Bool {
        NSMouseInRect(model.mouseLocation, screen.frame, false)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            frozenBackground
            dimmingLayer
            windowHighlight
            crosshair
            selectionChrome
            magnifier
            hintBar
            toolbar
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(mainGesture)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase {
                model.updateHover(to: global(fromLocal: p))
            }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var frozenBackground: some View {
        if let snap = model.snapshot(for: screen) {
            Image(decorative: snap.image, scale: snap.scale)
                .resizable()
                .interpolation(.high)
                .frame(width: screenSize.width, height: screenSize.height)
        }
    }

    private var dimmingLayer: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: screenSize))
            if model.hasSelection {
                path.addRect(selectionLocal)
            } else if model.windowMode, let w = model.hoveredWindow, !model.isDragging {
                path.addRect(localRect(fromGlobal: w.appKitFrame))
            }
        }
        .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var windowHighlight: some View {
        if model.windowMode, !model.hasSelection, !model.isDragging, let w = model.hoveredWindow {
            let r = localRect(fromGlobal: w.appKitFrame)
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2.5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var crosshair: some View {
        if mouseOnThisScreen, !model.windowMode, !model.isDragging, !model.confirmStage, !model.hasSelection {
            Path { p in
                p.move(to: CGPoint(x: mouseLocal.x, y: 0))
                p.addLine(to: CGPoint(x: mouseLocal.x, y: screenSize.height))
                p.move(to: CGPoint(x: 0, y: mouseLocal.y))
                p.addLine(to: CGPoint(x: screenSize.width, y: mouseLocal.y))
            }
            .stroke(Color.white.opacity(0.7), lineWidth: 1)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var selectionChrome: some View {
        if model.hasSelection {
            let r = selectionLocal
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                Rectangle()
                    .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)

                if model.confirmStage {
                    handles(for: r)
                }

                dimensionsLabel(for: r)
            }
            .allowsHitTesting(model.confirmStage)
        }
    }

    private func dimensionsLabel(for r: CGRect) -> some View {
        let text = "\(Int(model.selectionRect.width)) × \(Int(model.selectionRect.height))"
        let below = r.maxY + 26 < screenSize.height
        return Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
            .offset(x: max(4, r.minX), y: below ? r.maxY + 6 : max(4, r.minY - 24))
            .allowsHitTesting(false)
    }

    private func handles(for r: CGRect) -> some View {
        ForEach(Array(SelectionHandle.allCases.enumerated()), id: \.offset) { _, handle in
            let pos = handlePosition(handle, in: r)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .position(pos)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            model.resizeSelection(handle: handle, to: global(fromLocal: v.location))
                        }
                )
        }
    }

    private func handlePosition(_ handle: SelectionHandle, in r: CGRect) -> CGPoint {
        // Note: view-local "top" is the global rect's maxY.
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

    // MARK: - Magnifier

    @ViewBuilder
    private var magnifier: some View {
        if mouseOnThisScreen,
           !model.confirmStage,
           !model.windowMode,
           AppServices.shared.settings.crosshairMagnifier,
           let snap = model.snapshot(for: screen),
           let zoomed = magnifierImage(snapshot: snap) {
            let size: CGFloat = 126
            let offsetX = mouseLocal.x + size + 40 > screenSize.width ? -size - 20 : 20
            let offsetY = mouseLocal.y + size + 70 > screenSize.height ? -size - 50 : 20
            VStack(spacing: 4) {
                ZStack {
                    Image(decorative: zoomed, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size, height: size)
                    // center pixel marker
                    Rectangle().stroke(Color.red, lineWidth: 1).frame(width: 6, height: 6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.8), lineWidth: 1))

                let cg = Coordinates.cgPoint(fromAppKit: model.mouseLocation)
                Text("\(Int(cg.x)), \(Int(cg.y))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            }
            .offset(x: mouseLocal.x + offsetX, y: mouseLocal.y + offsetY)
            .allowsHitTesting(false)
        }
    }

    private func magnifierImage(snapshot: CaptureEngine.DisplaySnapshot) -> CGImage? {
        let scale = snapshot.scale
        let regionPx: CGFloat = 21 * scale
        let center = CGPoint(x: mouseLocal.x * scale, y: mouseLocal.y * scale)
        let rect = CGRect(x: center.x - regionPx / 2, y: center.y - regionPx / 2,
                          width: regionPx, height: regionPx)
        return snapshot.image.cropping(to: rect)
    }

    // MARK: - Hint bar & toolbar

    @ViewBuilder
    private var hintBar: some View {
        if !model.hasSelection, !model.isDragging, mouseOnThisScreen {
            HStack(spacing: 14) {
                if model.windowMode {
                    hint(key: "Click", text: "capture window")
                    hint(key: "Space", text: "area mode")
                } else {
                    hint(key: "Drag", text: "select area")
                    hint(key: "Space", text: "window mode")
                }
                hint(key: "Esc", text: "cancel")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
            .offset(y: 24)
            .allowsHitTesting(false)
        }
    }

    private func hint(key: String, text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var toolbar: some View {
        if model.confirmStage, model.hasSelection, model.activeScreen == screen {
            let r = selectionLocal
            let below = r.maxY + 64 < screenSize.height
            HStack(spacing: 2) {
                if model.purpose == .allInOne || model.purpose == .recordVideo {
                    toolbarButton("record.circle.fill", "Record", tint: .red) {
                        model.controller?.commitRecording(gif: false)
                    }
                }
                if model.purpose == .allInOne || model.purpose == .recordGIF {
                    toolbarButton("photo.stack.fill", "GIF", tint: .orange) {
                        model.controller?.commitRecording(gif: true)
                    }
                }
                if model.purpose == .allInOne {
                    toolbarButton("camera.fill", "Capture", tint: .white) {
                        model.controller?.commitArea(model.selectionRect)
                    }
                    toolbarButton("rectangle.inset.filled", "Fullscreen", tint: .white) {
                        model.controller?.commitFullscreen()
                    }
                } else if model.purpose != .recordVideo && model.purpose != .recordGIF {
                    toolbarButton("camera.fill", "Capture", tint: .white) {
                        model.controller?.commitArea(model.selectionRect)
                    }
                }
                Divider().frame(height: 22)
                toolbarButton("xmark", "Cancel", tint: .white) {
                    model.controller?.cancel()
                }
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
            .position(x: min(max(r.midX, 140), screenSize.width - 140),
                      y: below ? r.maxY + 36 : r.minY - 36)
        }
    }

    private func toolbarButton(_ symbol: String, _ label: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gesture

    private var mainGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let gp = global(fromLocal: value.location)
                switch adjustMode {
                case .none:
                    if model.confirmStage,
                       model.selectionRect.contains(global(fromLocal: value.startLocation)) {
                        adjustMode = .moving(last: global(fromLocal: value.startLocation))
                        fallthroughMove(to: gp)
                    } else {
                        adjustMode = .drawing
                        model.confirmStage = false
                        model.beginDrag(at: global(fromLocal: value.startLocation), on: screen)
                        model.continueDrag(to: gp)
                    }
                case .moving:
                    fallthroughMove(to: gp)
                case .drawing:
                    model.continueDrag(to: gp)
                }
            }
            .onEnded { value in
                let gp = global(fromLocal: value.location)
                switch adjustMode {
                case .drawing:
                    model.endDrag(at: gp)
                case .moving:
                    model.confirmStage = true
                case .none:
                    model.endDrag(at: gp)
                }
                adjustMode = .none
            }
    }

    private func fallthroughMove(to point: NSPoint) {
        if case .moving(let last) = adjustMode {
            model.moveSelection(dx: point.x - last.x, dy: point.y - last.y)
            adjustMode = .moving(last: point)
            model.mouseLocation = point
        }
    }
}

/// Big numeral countdown shown before timed captures and recordings.
@MainActor
enum CountdownOverlay {
    static func show(seconds: Int, on screen: NSScreen, completion: @escaping () -> Void) {
        guard seconds > 0 else {
            completion()
            return
        }
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let model = CountdownModel(value: seconds)
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()

        Task { @MainActor in
            for v in stride(from: seconds, through: 1, by: -1) {
                model.value = v
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            panel.orderOut(nil)
            completion()
        }
    }
}

@MainActor
final class CountdownModel: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            Color.clear
            Text("\(model.value)")
                .font(.system(size: 160, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 18)
                .padding(60)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 40))
                .id(model.value)
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: model.value)
        }
    }
}
