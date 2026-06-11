import AppKit
import SwiftUI

/// Borderless, non-activating panel that covers one screen during selection.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the per-screen selection panels and the event monitors for one
/// selection session. Only one session can be active at a time.
@MainActor
final class SelectionOverlayController {
    static var current: SelectionOverlayController?

    private var panels: [OverlayPanel] = []
    private var model: SelectionModel!
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private let completion: (SelectionOutcome) -> Void
    private var finished = false

    private init(completion: @escaping (SelectionOutcome) -> Void) {
        self.completion = completion
    }

    static func begin(purpose: SelectionPurpose,
                      startInWindowMode: Bool = false,
                      timerDelay: Int? = nil,
                      completion: @escaping (SelectionOutcome) -> Void) {
        // Escape hatch: pressing any capture hotkey while a selection session
        // is active cancels it (works even if the overlay lost key focus,
        // since Carbon hotkeys are global).
        if let existing = current {
            existing.cancel()
            return
        }
        let controller = SelectionOverlayController(completion: completion)
        current = controller
        Task {
            await controller.start(purpose: purpose, timerDelay: timerDelay,
                                   windowMode: startInWindowMode)
        }
    }

    private func start(purpose: SelectionPurpose, timerDelay: Int?, windowMode: Bool) async {
        // Freeze the screen first so the selection happens over a static image.
        let snapshots: [CaptureEngine.DisplaySnapshot]
        do {
            snapshots = try await AppServices.shared.captureEngine.snapshotAllDisplays()
        } catch {
            NSLog("Freeze failed: \(error)")
            Toast.show("Could not capture the screen", systemImage: "xmark.circle.fill")
            Self.current = nil
            completion(.cancelled)
            return
        }

        var snapshotMap: [CGDirectDisplayID: CaptureEngine.DisplaySnapshot] = [:]
        for snap in snapshots {
            snapshotMap[snap.screen.displayID] = snap
        }

        model = SelectionModel(purpose: purpose,
                               timerDelay: timerDelay,
                               windowMode: windowMode,
                               windows: WindowInfo.onScreenWindows(),
                               snapshots: snapshotMap)
        model.controller = self

        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = SelectionScreenView(model: model, screen: screen)
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Make the panel under the mouse key so it receives key events.
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first
        keyPanel?.makeKey()

        NSCursor.crosshair.push()
        installMonitors()
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.model.shiftHeld = event.modifierFlags.contains(.shift)
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            if event.type == .keyDown { cancel() }
            return true
        case 36, 76: // Return / keypad Enter
            if event.type == .keyDown, model.hasSelection {
                if model.purpose.usesConfirmStage, !model.confirmStage {
                    model.confirmStage = true
                } else {
                    confirmDefaultAction()
                }
            }
            return true
        case 49: // Space — while dragging: hold to move the selection;
                 // otherwise: toggle window-picking mode.
            if model.isDragging {
                model.spaceHeld = event.type == .keyDown
            } else if event.type == .keyDown {
                model.windowMode.toggle()
                model.updateHover(to: model.mouseLocation)
            } else {
                model.spaceHeld = false
            }
            return true
        case 123, 124, 125, 126: // Arrows
            guard event.type == .keyDown, model.hasSelection else { return true }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: model.moveSelection(dx: -step, dy: 0)
            case 124: model.moveSelection(dx: step, dy: 0)
            case 125: model.moveSelection(dx: 0, dy: -step)
            case 126: model.moveSelection(dx: 0, dy: step)
            default: break
            }
            return true
        default:
            return false
        }
    }

    private func confirmDefaultAction() {
        switch model.purpose {
        case .recordVideo: commitRecording(gif: false)
        case .recordGIF: commitRecording(gif: true)
        default: commitArea(model.selectionRect)
        }
    }

    // MARK: - Commits (called from model / toolbar)

    func commitArea(_ rect: NSRect) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        let screen = model.activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let purpose = model.purpose
        let timerDelay = model.timerDelay

        if purpose == .scrolling {
            finish(.scrollArea(rect: rect, screen: screen))
            return
        }

        guard let snap = model.snapshot(for: screen),
              let cropped = crop(snapshot: snap, globalRect: rect) else {
            finish(.cancelled)
            return
        }
        finish(.areaImage(cropped, rect: rect, screen: screen, purpose: purpose, timerDelay: timerDelay))
    }

    func commitWindow(_ window: WindowInfo) {
        finish(.window(window, purpose: model.purpose))
    }

    func commitRecording(gif: Bool) {
        let rect = model.selectionRect
        let screen = model.activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        finish(.recordArea(rect: rect, screen: screen, gif: gif))
    }

    func commitFullscreen() {
        let screen = model.activeScreen
            ?? NSScreen.screen(containing: model.mouseLocation)
            ?? NSScreen.main ?? NSScreen.screens[0]
        guard let snap = model.snapshot(for: screen) else {
            finish(.cancelled)
            return
        }
        finish(.areaImage(snap.image, rect: screen.frame, screen: screen,
                          purpose: model.purpose, timerDelay: model.timerDelay))
    }

    func cancel() {
        finish(.cancelled)
    }

    /// Crop a frozen display snapshot using a global AppKit rect.
    private func crop(snapshot: CaptureEngine.DisplaySnapshot, globalRect: NSRect) -> CGImage? {
        let screenFrame = snapshot.screen.frame
        let clamped = globalRect.intersection(screenFrame)
        guard !clamped.isEmpty else { return nil }
        // Screen-local, top-left-origin point rect.
        let local = CGRect(x: clamped.minX - screenFrame.minX,
                           y: screenFrame.maxY - clamped.maxY,
                           width: clamped.width,
                           height: clamped.height)
        return snapshot.image.cropping(toPointRect: local, scale: snapshot.scale)
    }

    private func finish(_ outcome: SelectionOutcome) {
        guard !finished else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        NSCursor.pop()

        // Commits originate inside SwiftUI gesture/button callbacks hosted by
        // these very panels. Tearing the hosting views down synchronously
        // crashes (use-after-free), so defer to the next runloop turn.
        let panels = self.panels
        self.panels = []
        let completion = self.completion
        DispatchQueue.main.async {
            for panel in panels {
                panel.orderOut(nil)
                panel.contentView = nil
            }
            Self.current = nil
            completion(outcome)
        }
    }
}
