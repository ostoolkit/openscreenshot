import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum CaptureKind: String, Codable {
    case image
    case video
    case gif
}

/// A finished capture: an image or a recording living in the app's capture store.
@MainActor
final class Capture: Identifiable, ObservableObject {
    let id: UUID
    let kind: CaptureKind
    let createdAt: Date
    /// Canonical file owned by the capture store (Application Support).
    let storeURL: URL
    /// Where the file was saved for the user (if "save to disk" is on or Save was pressed).
    @Published var savedURL: URL?
    /// In-memory image for image captures (final rendered pixels).
    let image: CGImage?
    @Published var thumbnail: NSImage?
    /// For captures whose look comes from canvas styling (window captures):
    /// the tight, unstyled screenshot plus the style, so the editor can open
    /// with padding/shadow/background as live settings.
    var sourceImage: CGImage?
    var canvasStyle: CanvasStyle?

    init(id: UUID = UUID(), kind: CaptureKind, storeURL: URL, image: CGImage?, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.storeURL = storeURL
        self.image = image
        self.createdAt = createdAt
    }

    var bestURL: URL { savedURL ?? storeURL }

    var displayName: String { bestURL.lastPathComponent }
}

/// Writes capture files into Application Support and the user's save folder.
@MainActor
enum CaptureStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenScreenshot/Captures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static func imageData(for image: CGImage) -> (data: Data, ext: String)? {
        let settings = AppServices.shared.settings
        switch settings.imageFormat {
        case .png:
            guard let data = image.pngData() else { return nil }
            return (data, "png")
        case .jpg:
            guard let data = image.jpegData(quality: settings.jpegQuality) else { return nil }
            return (data, "jpg")
        }
    }

    /// Persist an image capture into the store; optionally also into the user's save folder.
    /// A non-plain `canvas` (window captures: padding + shadow on transparency)
    /// is rendered into the saved file but kept as live, editable styling for
    /// the annotation editor.
    static func makeImageCapture(_ rawImage: CGImage, scale: CGFloat,
                                 canvas: CanvasStyle = .plain) -> Capture? {
        let settings = AppServices.shared.settings
        var source = rawImage
        var effectiveScale = scale
        if settings.downscaleRetina, scale > 1 {
            source = source.downscaled(by: scale)
            effectiveScale = 1
        }
        let canvasScaled = canvas.scaled(by: effectiveScale)
        let rendered: CGImage
        if canvasScaled.isPlain {
            rendered = source
        } else {
            rendered = AnnotationRenderer.compose(image: source, canvas: canvasScaled) ?? source
        }
        guard let (data, ext) = imageData(for: rendered) else { return nil }

        let id = UUID()
        let storeURL = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try data.write(to: storeURL)
        } catch {
            NSLog("Failed to write capture: \(error)")
            return nil
        }

        let capture = Capture(id: id, kind: .image, storeURL: storeURL, image: rendered)
        capture.thumbnail = rendered.resized(maxPixelWidth: 640).nsImage
        if !canvasScaled.isPlain {
            capture.sourceImage = source
            capture.canvasStyle = canvasScaled
        }

        if settings.saveToDiskAfterCapture {
            saveToUserFolder(capture)
        }
        return capture
    }

    /// Wrap an already-encoded media file (recording / gif / scrolling result).
    static func makeFileCapture(tempURL: URL, kind: CaptureKind, image: CGImage? = nil) -> Capture? {
        let id = UUID()
        let storeURL = directory.appendingPathComponent("\(id.uuidString).\(tempURL.pathExtension)")
        do {
            try FileManager.default.moveItem(at: tempURL, to: storeURL)
        } catch {
            NSLog("Failed to move capture: \(error)")
            return nil
        }
        let capture = Capture(id: id, kind: kind, storeURL: storeURL, image: image)
        if let image {
            capture.thumbnail = image.resized(maxPixelWidth: 640).nsImage
        } else {
            capture.thumbnail = VideoThumbnailer.thumbnail(for: storeURL)
        }
        if AppServices.shared.settings.saveToDiskAfterCapture {
            saveToUserFolder(capture)
        }
        return capture
    }

    @discardableResult
    static func saveToUserFolder(_ capture: Capture) -> URL? {
        let settings = AppServices.shared.settings
        let ext = capture.storeURL.pathExtension
        let name = FileNamer.filename(template: settings.filenameTemplate, date: capture.createdAt, ext: ext)
        let dest = FileNamer.uniqueURL(directory: settings.saveDirectoryURL, filename: name)
        do {
            try FileManager.default.copyItem(at: capture.storeURL, to: dest)
            capture.savedURL = dest
            return dest
        } catch {
            NSLog("Failed to save capture: \(error)")
            return nil
        }
    }

    static func saveAs(_ capture: Capture) {
        let panel = NSSavePanel()
        let ext = capture.storeURL.pathExtension
        panel.nameFieldStringValue = FileNamer.filename(
            template: AppServices.shared.settings.filenameTemplate,
            date: capture.createdAt, ext: ext)
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            do {
                try FileManager.default.copyItem(at: capture.storeURL, to: url)
                capture.savedURL = url
            } catch {
                NSLog("Save As failed: \(error)")
            }
        }
    }

    static func copyToClipboard(_ capture: Capture) {
        if capture.kind == .image, let image = capture.image {
            NSPasteboard.copyImage(image)
        } else {
            NSPasteboard.copyFile(capture.bestURL)
        }
    }
}

@MainActor
enum VideoThumbnailer {
    static func thumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return cg.nsImage
    }
}
