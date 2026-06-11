import AppKit
import SwiftUI
import ServiceManagement

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg
    var id: String { rawValue }
    var ext: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum OverlayCorner: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }
}

/// UserDefaults-backed app settings. One source of truth, observable from SwiftUI.
@MainActor
final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    // MARK: General / after-capture
    @Published var showQuickAccessOverlay: Bool { didSet { d.set(showQuickAccessOverlay, forKey: "showQuickAccessOverlay") } }
    @Published var copyToClipboardAfterCapture: Bool { didSet { d.set(copyToClipboardAfterCapture, forKey: "copyToClipboardAfterCapture") } }
    @Published var saveToDiskAfterCapture: Bool { didSet { d.set(saveToDiskAfterCapture, forKey: "saveToDiskAfterCapture") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var launchAtLogin: Bool {
        didSet {
            d.set(launchAtLogin, forKey: "launchAtLogin")
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }

    // MARK: Screenshots
    @Published var imageFormat: ImageFormat { didSet { d.set(imageFormat.rawValue, forKey: "imageFormat") } }
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    @Published var filenameTemplate: String { didSet { d.set(filenameTemplate, forKey: "filenameTemplate") } }
    @Published var saveDirectoryPath: String { didSet { d.set(saveDirectoryPath, forKey: "saveDirectoryPath") } }
    @Published var downscaleRetina: Bool { didSet { d.set(downscaleRetina, forKey: "downscaleRetina") } }
    @Published var captureCursor: Bool { didSet { d.set(captureCursor, forKey: "captureCursor") } }
    @Published var captureWindowShadow: Bool { didSet { d.set(captureWindowShadow, forKey: "captureWindowShadow") } }
    @Published var crosshairMagnifier: Bool { didSet { d.set(crosshairMagnifier, forKey: "crosshairMagnifier") } }
    @Published var hideIconsWhileCapturing: Bool { didSet { d.set(hideIconsWhileCapturing, forKey: "hideIconsWhileCapturing") } }

    // MARK: Quick Access Overlay
    @Published var overlayCorner: OverlayCorner { didSet { d.set(overlayCorner.rawValue, forKey: "overlayCorner") } }
    @Published var overlayAutoCloseSeconds: Int { didSet { d.set(overlayAutoCloseSeconds, forKey: "overlayAutoCloseSeconds") } } // 0 = never

    // MARK: Recording
    @Published var videoFPS: Int { didSet { d.set(videoFPS, forKey: "videoFPS") } }
    @Published var gifFPS: Int { didSet { d.set(gifFPS, forKey: "gifFPS") } }
    @Published var recordSystemAudio: Bool { didSet { d.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    @Published var recordMicrophone: Bool { didSet { d.set(recordMicrophone, forKey: "recordMicrophone") } }
    @Published var webcamOverlayEnabled: Bool { didSet { d.set(webcamOverlayEnabled, forKey: "webcamOverlayEnabled") } }
    @Published var highlightClicks: Bool { didSet { d.set(highlightClicks, forKey: "highlightClicks") } }
    @Published var showKeystrokes: Bool { didSet { d.set(showKeystrokes, forKey: "showKeystrokes") } }
    @Published var countdownSeconds: Int { didSet { d.set(countdownSeconds, forKey: "countdownSeconds") } } // 0 = off
    @Published var recordCursor: Bool { didSet { d.set(recordCursor, forKey: "recordCursor") } }

    var saveDirectoryURL: URL {
        let url = URL(fileURLWithPath: (saveDirectoryPath as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    init() {
        let defaults: [String: Any] = [
            "showQuickAccessOverlay": true,
            "copyToClipboardAfterCapture": false,
            "saveToDiskAfterCapture": true,
            "playSounds": true,
            "launchAtLogin": false,
            "imageFormat": ImageFormat.png.rawValue,
            "jpegQuality": 0.9,
            "filenameTemplate": "OpenScreenshot %y-%m-%d at %H.%M.%S",
            "saveDirectoryPath": "~/Desktop",
            "downscaleRetina": false,
            "captureCursor": false,
            "captureWindowShadow": true,
            "crosshairMagnifier": true,
            "hideIconsWhileCapturing": false,
            "overlayCorner": OverlayCorner.bottomLeft.rawValue,
            "overlayAutoCloseSeconds": 0,
            "videoFPS": 60,
            "gifFPS": 15,
            "recordSystemAudio": true,
            "recordMicrophone": false,
            "webcamOverlayEnabled": false,
            "highlightClicks": false,
            "showKeystrokes": false,
            "countdownSeconds": 3,
            "recordCursor": true,
        ]
        d.register(defaults: defaults)

        showQuickAccessOverlay = d.bool(forKey: "showQuickAccessOverlay")
        copyToClipboardAfterCapture = d.bool(forKey: "copyToClipboardAfterCapture")
        saveToDiskAfterCapture = d.bool(forKey: "saveToDiskAfterCapture")
        playSounds = d.bool(forKey: "playSounds")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "png") ?? .png
        jpegQuality = d.double(forKey: "jpegQuality")
        filenameTemplate = d.string(forKey: "filenameTemplate") ?? "OpenScreenshot %y-%m-%d at %H.%M.%S"
        saveDirectoryPath = d.string(forKey: "saveDirectoryPath") ?? "~/Desktop"
        downscaleRetina = d.bool(forKey: "downscaleRetina")
        captureCursor = d.bool(forKey: "captureCursor")
        captureWindowShadow = d.bool(forKey: "captureWindowShadow")
        crosshairMagnifier = d.bool(forKey: "crosshairMagnifier")
        hideIconsWhileCapturing = d.bool(forKey: "hideIconsWhileCapturing")
        overlayCorner = OverlayCorner(rawValue: d.string(forKey: "overlayCorner") ?? "bottomLeft") ?? .bottomLeft
        overlayAutoCloseSeconds = d.integer(forKey: "overlayAutoCloseSeconds")
        videoFPS = d.integer(forKey: "videoFPS")
        gifFPS = d.integer(forKey: "gifFPS")
        recordSystemAudio = d.bool(forKey: "recordSystemAudio")
        recordMicrophone = d.bool(forKey: "recordMicrophone")
        webcamOverlayEnabled = d.bool(forKey: "webcamOverlayEnabled")
        highlightClicks = d.bool(forKey: "highlightClicks")
        showKeystrokes = d.bool(forKey: "showKeystrokes")
        countdownSeconds = d.integer(forKey: "countdownSeconds")
        recordCursor = d.bool(forKey: "recordCursor")
    }

    // Last-used selection rect (AppKit global coords), for "Capture Previous Area".
    var lastSelectionRect: NSRect? {
        get {
            guard let s = d.string(forKey: "lastSelectionRect") else { return nil }
            let r = NSRectFromString(s)
            return r.isEmpty ? nil : r
        }
        set {
            if let r = newValue { d.set(NSStringFromRect(r), forKey: "lastSelectionRect") }
        }
    }
}
