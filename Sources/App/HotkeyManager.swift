import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Defaults take over the macOS screenshot shortcuts (app-registered
    // hotkeys win over the system ones while we run). Everything else
    // ships unbound.
    static let captureArea = Self("captureArea", default: .init(.four, modifiers: [.command, .shift]))
    static let captureWindow = Self("captureWindow")
    static let captureFullscreen = Self("captureFullscreen", default: .init(.three, modifiers: [.command, .shift]))
    static let allInOne = Self("allInOne", default: .init(.five, modifiers: [.command, .shift]))
    static let capturePreviousArea = Self("capturePreviousArea")
    static let scrollingCapture = Self("scrollingCapture")
    static let captureText = Self("captureText")
    static let toggleRecording = Self("toggleRecording")
    static let recordGIF = Self("recordGIF")
    static let annotateClipboard = Self("annotateClipboard")
    static let pinClipboard = Self("pinClipboard")
    static let captureHistory = Self("captureHistory")
    static let toggleDesktopIcons = Self("toggleDesktopIcons")
}

@MainActor
enum HotkeyManager {
    static func registerAll() {
        let services = AppServices.shared

        KeyboardShortcuts.onKeyUp(for: .captureArea) { services.capture.startAreaCapture() }
        KeyboardShortcuts.onKeyUp(for: .captureWindow) { services.capture.startWindowCapture() }
        KeyboardShortcuts.onKeyUp(for: .captureFullscreen) { services.capture.captureFullscreen() }
        KeyboardShortcuts.onKeyUp(for: .allInOne) { services.capture.startAllInOne() }
        KeyboardShortcuts.onKeyUp(for: .capturePreviousArea) { services.capture.capturePreviousArea() }
        KeyboardShortcuts.onKeyUp(for: .scrollingCapture) { services.capture.startScrollingCapture() }
        KeyboardShortcuts.onKeyUp(for: .captureText) { services.capture.startOCRCapture() }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            if services.recording.isRecording {
                Task { await services.recording.stop() }
            } else {
                services.capture.startRecordingSelection(gif: false)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .recordGIF) {
            if services.recording.isRecording {
                Task { await services.recording.stop() }
            } else {
                services.capture.startRecordingSelection(gif: true)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .annotateClipboard) {
            if let image = NSPasteboard.image?.cgImage { EditorWindowController.open(image: image) }
        }
        KeyboardShortcuts.onKeyUp(for: .pinClipboard) {
            if let image = NSPasteboard.image?.cgImage { services.pins.pin(image: image) }
        }
        KeyboardShortcuts.onKeyUp(for: .captureHistory) { HistoryWindowController.show() }
        KeyboardShortcuts.onKeyUp(for: .toggleDesktopIcons) { services.desktopIcons.toggle() }
    }
}
