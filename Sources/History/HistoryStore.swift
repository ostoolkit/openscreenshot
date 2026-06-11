import AppKit
import SwiftUI

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let kind: CaptureKind
    let filename: String
    let createdAt: Date
}

/// Persistent record of recent captures (files live in the capture store).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 100
    private var indexURL: URL {
        CaptureStore.directory.appendingPathComponent("history.json")
    }

    init() {
        load()
    }

    func add(_ capture: Capture) {
        let entry = HistoryEntry(id: capture.id,
                                 kind: capture.kind,
                                 filename: capture.storeURL.lastPathComponent,
                                 createdAt: capture.createdAt)
        entries.insert(entry, at: 0)
        prune()
        save()
    }

    func remove(id: UUID) {
        if let entry = entries.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: url(for: entry))
        }
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        for entry in entries {
            try? FileManager.default.removeItem(at: url(for: entry))
        }
        entries = []
        save()
    }

    func url(for entry: HistoryEntry) -> URL {
        CaptureStore.directory.appendingPathComponent(entry.filename)
    }

    func image(for entry: HistoryEntry) -> CGImage? {
        NSImage(contentsOf: url(for: entry))?.cgImage
    }

    private func prune() {
        while entries.count > maxEntries {
            let removed = entries.removeLast()
            try? FileManager.default.removeItem(at: url(for: removed))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL)
        }
    }
}

// MARK: - History window

@MainActor
final class HistoryWindowController {
    private static var window: NSWindow?

    static func show() {
        if let window {
            if !window.isVisible {
                AppActivation.windowOpened()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = HistoryView()
        let hosting = NSHostingController(rootView: view)
        // Keep the window at our size — by default NSHostingController resizes
        // the window to the SwiftUI ideal size (a skinny strip for a ScrollView).
        hosting.sizingOptions = []
        let w = NSWindow(contentViewController: hosting)
        w.title = "Capture History"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 720, height: 480))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        AppActivation.windowOpened()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { _ in
            Task { @MainActor in
                AppActivation.windowClosed()
            }
        }
        w.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject private var history = AppServices.shared.history

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 400)
    }

    private var content: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("No Captures Yet",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Your recent screenshots and recordings will appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(history.entries) { entry in
                            HistoryItemView(entry: entry, history: history)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .toolbar {
            Button("Clear All", role: .destructive) {
                history.clear()
            }
            .disabled(history.entries.isEmpty)
        }
    }
}

private struct HistoryItemView: View {
    let entry: HistoryEntry
    let history: HistoryStore
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if entry.kind != .image {
                    Image(systemName: entry.kind == .gif ? "photo.stack.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .frame(height: 120)

            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            let url = history.url(for: entry)
            thumbnail = entry.kind == .image
                ? NSImage(contentsOf: url)
                : VideoThumbnailer.thumbnail(for: url)
        }
        .draggable(history.url(for: entry))
        .contextMenu {
            Button("Copy") {
                if entry.kind == .image, let image = history.image(for: entry) {
                    NSPasteboard.copyImage(image)
                } else {
                    NSPasteboard.copyFile(history.url(for: entry))
                }
            }
            if entry.kind == .image {
                Button("Annotate") {
                    if let image = history.image(for: entry) {
                        EditorWindowController.open(image: image)
                    }
                }
                Button("Pin") {
                    if let image = history.image(for: entry) {
                        AppServices.shared.pins.pin(image: image)
                    }
                }
            } else {
                Button("Edit") {
                    let capture = Capture(id: entry.id, kind: entry.kind,
                                          storeURL: history.url(for: entry), image: nil,
                                          createdAt: entry.createdAt)
                    VideoTrimmerWindowController.open(capture: capture)
                }
            }
            Button("Save As…") {
                let capture = Capture(id: entry.id, kind: entry.kind,
                                      storeURL: history.url(for: entry),
                                      image: history.image(for: entry),
                                      createdAt: entry.createdAt)
                CaptureStore.saveAs(capture)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([history.url(for: entry)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                history.remove(id: entry.id)
            }
        }
    }
}
