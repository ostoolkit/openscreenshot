import SwiftUI
import KeyboardShortcuts

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, screenshots, recording, quickAccess, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .screenshots: "Screenshots"
        case .recording: "Recording"
        case .quickAccess: "Quick Access"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .screenshots: "camera"
        case .recording: "video"
        case .quickAccess: "rectangle.stack"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general: GeneralSettingsTab()
                case .shortcuts: ShortcutsSettingsTab()
                case .screenshots: ScreenshotsSettingsTab()
                case .recording: RecordingSettingsTab()
                case .quickAccess: QuickAccessSettingsTab()
                case .about: AboutSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 620)
        .environmentObject(settings)
    }

    /// System Settings-style icon tabs (a plain TabView in a window renders
    /// a cramped text-only tab strip).
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                        Text(item.label)
                            .font(.system(size: 10))
                    }
                    .frame(width: 78, height: 46)
                    .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                    .background(tab == item ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Show Quick Access Overlay", isOn: $settings.showQuickAccessOverlay)
                Toggle("Copy to clipboard", isOn: $settings.copyToClipboardAfterCapture)
                Toggle("Save to disk", isOn: $settings.saveToDiskAfterCapture)
            }
            Section {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Hide desktop icons while capturing", isOn: $settings.hideIconsWhileCapturing)
            }
            Section("Permissions") {
                HStack {
                    Label(
                        PermissionsManager.hasScreenRecordingPermission
                            ? "Screen Recording: granted"
                            : "Screen Recording: not granted",
                        systemImage: PermissionsManager.hasScreenRecordingPermission
                            ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(PermissionsManager.hasScreenRecordingPermission ? .green : .red)
                    Spacer()
                    Button("Open System Settings") {
                        PermissionsManager.openScreenRecordingSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section("Capture") {
                KeyboardShortcuts.Recorder("Capture Area", name: .captureArea)
                KeyboardShortcuts.Recorder("Capture Window", name: .captureWindow)
                KeyboardShortcuts.Recorder("Capture Fullscreen", name: .captureFullscreen)
                KeyboardShortcuts.Recorder("All-in-One", name: .allInOne)
                KeyboardShortcuts.Recorder("Capture Previous Area", name: .capturePreviousArea)
                KeyboardShortcuts.Recorder("Scrolling Capture", name: .scrollingCapture)
                KeyboardShortcuts.Recorder("Capture Text (OCR)", name: .captureText)
            }
            Section("Recording") {
                KeyboardShortcuts.Recorder("Record Screen / Stop", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Record GIF / Stop", name: .recordGIF)
            }
            Section("Tools") {
                KeyboardShortcuts.Recorder("Annotate From Clipboard", name: .annotateClipboard)
                KeyboardShortcuts.Recorder("Pin From Clipboard", name: .pinClipboard)
                KeyboardShortcuts.Recorder("Capture History", name: .captureHistory)
                KeyboardShortcuts.Recorder("Toggle Desktop Icons", name: .toggleDesktopIcons)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct ScreenshotsSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("File") {
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                if settings.imageFormat == .jpg {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0) {
                        Text("JPEG quality")
                    }
                }
                TextField("Filename template", text: $settings.filenameTemplate)
                    .help("Tokens: %y year, %m month, %d day, %H hour, %M minute, %S second")
                HStack {
                    TextField("Save location", text: $settings.saveDirectoryPath)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Section("Capture") {
                Toggle("Downscale Retina screenshots to 1x", isOn: $settings.downscaleRetina)
                Toggle("Show cursor in screenshots", isOn: $settings.captureCursor)
                Toggle("Capture window shadow", isOn: $settings.captureWindowShadow)
                Toggle("Show magnifier in crosshair", isOn: $settings.crosshairMagnifier)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryPath = url.path
        }
    }
}

private struct RecordingSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $settings.videoFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordMicrophone)
                    .disabled(!isMacOS15)
                if !isMacOS15 {
                    Text("Microphone recording requires macOS 15 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("GIF") {
                Picker("GIF frame rate", selection: $settings.gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                }
            }
            Section("Overlays") {
                Toggle("Webcam overlay", isOn: $settings.webcamOverlayEnabled)
                Toggle("Highlight mouse clicks", isOn: $settings.highlightClicks)
                Toggle("Show keystrokes (needs Accessibility)", isOn: $settings.showKeystrokes)
                Toggle("Show cursor", isOn: $settings.recordCursor)
            }
            Section {
                Picker("Countdown before recording", selection: $settings.countdownSeconds) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private var isMacOS15: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}

private struct QuickAccessSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Overlay position") {
                Picker("Screen corner", selection: $settings.overlayCorner) {
                    ForEach(OverlayCorner.allCases) { corner in
                        Text(corner.label).tag(corner)
                    }
                }
            }
            Section("Auto-close") {
                Picker("Close overlay automatically", selection: $settings.overlayAutoCloseSeconds) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("OpenScreenshot").font(.title.bold())
            Text("An open-source screenshot, recording and annotation tool for macOS.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}
