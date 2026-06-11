import AppKit
import SwiftUI

@MainActor
enum PermissionsManager {
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func checkOnLaunch() {
        guard !hasScreenRecordingPermission else { return }
        // Triggers the one-time system prompt; afterwards the user must
        // enable it manually in System Settings and relaunch.
        CGRequestScreenCaptureAccess()
        showOnboarding()
    }

    /// Returns true if capture can proceed; shows guidance otherwise.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecordingPermission { return true }
        showOnboarding()
        return false
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Onboarding window

    private static var window: NSWindow?

    static func showOnboarding() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = PermissionsView()
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Welcome to OpenScreenshot"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private struct PermissionsView: View {
    @State private var granted = PermissionsManager.hasScreenRecordingPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Screen Recording Permission Needed")
                .font(.title2.bold())
            Text("OpenScreenshot needs the Screen Recording permission to capture your screen.\nEnable it in System Settings → Privacy & Security → Screen Recording,\nthen relaunch OpenScreenshot.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if granted {
                Label("Permission granted — you're all set!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Button("Open System Settings") {
                        PermissionsManager.openScreenRecordingSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Relaunch App") {
                        relaunch()
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 480)
        .onReceive(timer) { _ in
            granted = PermissionsManager.hasScreenRecordingPermission
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        NSApp.terminate(nil)
    }
}
