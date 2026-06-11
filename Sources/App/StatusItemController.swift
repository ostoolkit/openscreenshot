import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var recordingTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureIdle()
    }

    // MARK: - States

    func configureIdle() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "OpenScreenshot")
            button.contentTintColor = nil
            button.title = ""
            button.toolTip = nil
            button.action = nil
            button.target = nil
        }
        statusItem.menu = buildMenu()
    }

    /// While recording the status item becomes a click-to-stop button with a timer.
    func configureRecording(startedAt: Date) {
        statusItem.menu = nil
        if let button = statusItem.button {
            // A filled red square reads unambiguously as "stop".
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            button.image = NSImage(systemSymbolName: "stop.fill",
                                   accessibilityDescription: "Stop Recording")?
                .withSymbolConfiguration(config)
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            button.toolTip = "Stop recording"
            button.target = self
            button.action = #selector(stopRecordingClicked)
        }
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                button.title = String(format: " %d:%02d", elapsed / 60, elapsed % 60)
            }
        }
    }

    @objc private func stopRecordingClicked() {
        if let button = statusItem.button {
            button.contentTintColor = nil
        }
        Task { await AppServices.shared.recording.stop() }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(item("Capture Area", #selector(captureArea), "4", symbol: "rectangle.dashed"))
        menu.addItem(item("Capture Window", #selector(captureWindow), "", symbol: "macwindow"))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), "3", symbol: "rectangle.inset.filled"))
        menu.addItem(item("All-in-One", #selector(allInOne), "5", symbol: "square.on.square.dashed"))
        menu.addItem(item("Capture Previous Area", #selector(capturePrevious), "", symbol: "arrow.counterclockwise"))
        menu.addItem(.separator())
        menu.addItem(item("Scrolling Capture", #selector(scrollingCapture), "", symbol: "arrow.up.and.down.square"))
        menu.addItem(item("Capture Text (OCR)", #selector(captureText), "", symbol: "text.viewfinder"))
        menu.addItem(.separator())
        menu.addItem(item("Record Screen", #selector(recordScreen), "", symbol: "record.circle"))
        menu.addItem(item("Record GIF", #selector(recordGIF), "", symbol: "photo.stack"))

        let timerMenu = NSMenu()
        for seconds in [3, 5, 10] {
            let i = NSMenuItem(title: "\(seconds) seconds", action: #selector(selfTimer(_:)), keyEquivalent: "")
            i.target = self
            i.tag = seconds
            timerMenu.addItem(i)
        }
        let timerItem = NSMenuItem(title: "Self-Timer", action: nil, keyEquivalent: "")
        timerItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        menu.addItem(.separator())
        menu.addItem(item("Annotate From Clipboard", #selector(annotateClipboard), "", symbol: "pencil.tip.crop.circle"))
        menu.addItem(item("Pin From Clipboard", #selector(pinClipboard), "", symbol: "pin"))
        menu.addItem(item("Capture History…", #selector(showHistory), "", symbol: "clock.arrow.circlepath"))
        menu.addItem(.separator())

        let hideIcons = item("Hide Desktop Icons", #selector(toggleDesktopIcons), "", symbol: "eye.slash")
        hideIcons.state = AppServices.shared.desktopIcons.isHidden ? .on : .off
        menu.addItem(hideIcons)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        let quit = NSMenuItem(title: "Quit OpenScreenshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleDesktopIcons) {
            item.state = AppServices.shared.desktopIcons.isHidden ? .on : .off
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            i.keyEquivalentModifierMask = key == "," ? [.command] : [.command, .shift]
        }
        i.target = self
        if let symbol {
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return i
    }

    // MARK: - Actions

    @objc private func captureArea() { AppServices.shared.capture.startAreaCapture() }
    @objc private func captureWindow() { AppServices.shared.capture.startWindowCapture() }
    @objc private func captureFullscreen() { AppServices.shared.capture.captureFullscreen() }
    @objc private func allInOne() { AppServices.shared.capture.startAllInOne() }
    @objc private func capturePrevious() { AppServices.shared.capture.capturePreviousArea() }
    @objc private func scrollingCapture() { AppServices.shared.capture.startScrollingCapture() }
    @objc private func captureText() { AppServices.shared.capture.startOCRCapture() }
    @objc private func recordScreen() { AppServices.shared.capture.startRecordingSelection(gif: false) }
    @objc private func recordGIF() { AppServices.shared.capture.startRecordingSelection(gif: true) }
    @objc private func selfTimer(_ sender: NSMenuItem) { AppServices.shared.capture.startSelfTimerCapture(delay: sender.tag) }
    @objc private func annotateClipboard() {
        if let image = NSPasteboard.image?.cgImage {
            EditorWindowController.open(image: image)
        } else {
            Toast.show("No image on clipboard", systemImage: "exclamationmark.circle.fill")
        }
    }
    @objc private func pinClipboard() {
        if let image = NSPasteboard.image?.cgImage {
            AppServices.shared.pins.pin(image: image)
        } else {
            Toast.show("No image on clipboard", systemImage: "exclamationmark.circle.fill")
        }
    }
    @objc private func showHistory() { HistoryWindowController.show() }
    @objc private func toggleDesktopIcons() { AppServices.shared.desktopIcons.toggle() }
    @objc private func openSettings() { SettingsWindowController.show() }
}
