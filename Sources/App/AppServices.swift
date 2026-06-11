import AppKit

/// Service locator for the app's long-lived controllers.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings = SettingsStore()
    lazy var captureEngine = CaptureEngine()
    lazy var capture = CaptureController()
    lazy var recording = RecordingController()
    lazy var overlay = QuickAccessOverlayController()
    lazy var pins = PinController()
    lazy var history = HistoryStore()
    lazy var desktopIcons = DesktopIconsHider()

    private(set) var statusItem: StatusItemController!

    private init() {}

    func start() {
        statusItem = StatusItemController()
        HotkeyManager.registerAll()
        PermissionsManager.checkOnLaunch()
        // Absorb ScreenCaptureKit's one-time first-use stall in the background
        // so the first real capture doesn't hang under the selection overlay.
        captureEngine.warmUp()
    }

    func willTerminate() {
        desktopIcons.restore()
        if recording.isRecording {
            recording.stopSync()
        }
    }
}
