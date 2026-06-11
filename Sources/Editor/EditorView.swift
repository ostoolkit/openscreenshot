import SwiftUI
import AppKit

/// Bridges the shared NSColorPanel to a callback, for custom color buttons.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    private var onChange: ((NSColor) -> Void)?

    func present(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

struct EditorView: View {
    @ObservedObject var document: EditorDocument
    @State private var zoom: CGFloat = 1

    var body: some View {
        HStack(spacing: 0) {
            CanvasSidebar(document: document)
                .frame(width: 248)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                optionsBar
                Divider()
                EditorCanvasContainer(document: document, zoom: $zoom)
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .frame(minWidth: 1000, minHeight: 480)
        .onDeleteCommand {
            if document.editingTextID == nil {
                document.deleteSelected()
            }
        }
        .background(shortcutButtons)
    }

    // MARK: - Toolbar (tools + actions)

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    toolButton(tool)
                }
            }

            Divider().frame(height: 22)

            iconButton("arrow.uturn.backward", help: "Undo (⌘Z)") { document.undo() }
                .disabled(!document.canUndo)
            iconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)") { document.redo() }
                .disabled(!document.canRedo)

            Spacer()

            HStack(spacing: 2) {
                iconButton("minus.magnifyingglass", help: "Zoom out") { zoom = max(zoom / 1.25, 0.2) }
                Button { zoom = 1 } label: {
                    Text("\(Int(zoom * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, height: 26)
                        .contentShape(Rectangle())
                }
                .help("Reset zoom")
                iconButton("plus.magnifyingglass", help: "Zoom in") { zoom = min(zoom * 1.25, 6) }
            }

            Divider().frame(height: 22)

            labelButton("Pin", symbol: "pin", help: "Pin to screen") { pin() }
            labelButton("Copy", symbol: "doc.on.doc", help: "Copy to clipboard") { copyResult() }
            labelButton("Save", symbol: "square.and.arrow.down", help: "Save (⌘S)") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .contextMenu {
                    Button("Save As…") { saveAs() }
                }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Icon button with a full-size clickable area (bare borderless buttons
    /// only hit-test the glyph itself).
    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func labelButton(_ title: String, symbol: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button {
            document.tool = tool
            if tool != .select { document.selectedID = nil }
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 28)
                .background(document.tool == tool ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.help)
    }

    // MARK: - Options bar (color / stroke / fill / size)

    private var selectedKind: Annotation.Kind? {
        document.annotation(id: document.selectedID)?.kind
    }

    /// What the size slider controls, based on the active tool / selection.
    private enum SizeContext {
        case stroke, font, intensity
    }

    private var sizeContext: SizeContext {
        if selectedKind == .text || selectedKind == .counter { return .font }
        if selectedKind == .blur || selectedKind == .pixelate { return .intensity }
        switch document.tool {
        case .text, .counter: return .font
        case .blur, .pixelate: return .intensity
        default: return .stroke
        }
    }

    /// One slider, three meanings: stroke width for shapes, font size for
    /// text & number badges, blur/pixel intensity for redactions.
    private var sizeSlider: some View {
        let context = sizeContext
        let isFont = context == .font
        return HStack(spacing: 6) {
            Image(systemName: isFont ? "textformat.size"
                  : context == .intensity ? "circle.dotted" : "lineweight")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(isFont ? document.fontSizeValue : document.strokeWidth) },
                set: { newValue in
                    let v = CGFloat(newValue)
                    if isFont {
                        document.fontSizeValue = v
                        updateSelection { $0.fontSize = v }
                    } else {
                        document.strokeWidth = v
                        updateSelection { $0.lineWidth = v }
                    }
                }), in: isFont ? 12...80 : 2...24) { editing in
                if editing {
                    registerSelectionUndoOnce()
                } else {
                    strokeUndoRegistered = false
                }
            }
            .controlSize(.small)
            .frame(width: 110)
            Text("\(Int(isFont ? document.fontSizeValue : document.strokeWidth))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
        .help(isFont ? "Size" : context == .intensity ? "Blur / pixel intensity" : "Stroke width")
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        document.color = swatch
                        applyToSelection { $0.color = swatch }
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                            .overlay {
                                if document.color == swatch {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                                }
                            }
                            .frame(width: 24, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // Custom color: compact rainbow button -> shared color panel
                // (the system ColorPicker well is oversized in a toolbar).
                Button {
                    if document.selectedID != nil {
                        document.registerUndo()
                    }
                    ColorPanelBridge.shared.present(initial: document.color.nsColor) { nsColor in
                        let rgba = RGBA(color: Color(nsColor: nsColor))
                        document.color = rgba
                        updateSelection { $0.color = rgba }
                    }
                } label: {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                              center: .center))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Custom color…")
            }

            Divider().frame(height: 18)

            sizeSlider

            if document.tool == .rect || document.tool == .ellipse
                || selectedKind == .rect || selectedKind == .ellipse {
                Toggle("Fill", isOn: Binding(
                    get: { document.fillShapes },
                    set: { newValue in
                        document.fillShapes = newValue
                        applyToSelection { $0.filled = newValue }
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        let size = document.compositionSize
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }

    @State private var strokeUndoRegistered = false

    /// One-shot change (swatch click, toggle): registers undo per call.
    private func applyToSelection(_ transform: (inout Annotation) -> Void) {
        guard let id = document.selectedID,
              var a = document.annotation(id: id) else { return }
        document.registerUndo()
        transform(&a)
        document.update(a)
    }

    /// Continuous change (slider drag): no undo per tick —
    /// `registerSelectionUndoOnce` handles it at drag start.
    private func updateSelection(_ transform: (inout Annotation) -> Void) {
        guard let id = document.selectedID,
              var a = document.annotation(id: id) else { return }
        transform(&a)
        document.update(a)
    }

    private func registerSelectionUndoOnce() {
        guard document.selectedID != nil, !strokeUndoRegistered else { return }
        document.registerUndo()
        strokeUndoRegistered = true
    }

    // MARK: - Output actions

    private func save() {
        guard let image = document.renderFinal() else { return }
        if let capture = CaptureStore.makeImageCapture(image, scale: 1) {
            if capture.savedURL == nil {
                CaptureStore.saveToUserFolder(capture)
            }
            AppServices.shared.history.add(capture)
            if let url = capture.savedURL {
                Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
            }
        }
    }

    private func saveAs() {
        guard let image = document.renderFinal() else { return }
        if let capture = CaptureStore.makeImageCapture(image, scale: 1) {
            CaptureStore.saveAs(capture)
        }
    }

    private func copyResult() {
        guard let image = document.renderFinal() else { return }
        NSPasteboard.copyImage(image)
        Toast.show("Copied to clipboard")
    }

    private func pin() {
        guard let image = document.renderFinal() else { return }
        AppServices.shared.pins.pin(image: image)
    }

    /// Hidden buttons providing window-level keyboard shortcuts.
    private var shortcutButtons: some View {
        Group {
            Button("") { document.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { document.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { copyResult() }.keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

// MARK: - Canvas sidebar

/// Padding / background / corner styling for the composition, with live
/// previews of every preset.
struct CanvasSidebar: View {
    @ObservedObject var document: EditorDocument
    @State private var sliderUndoRegistered = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Canvas")
                    .font(.headline)

                slider(label: "Padding",
                       value: $document.padding,
                       range: 0...240,
                       format: { "\(Int($0)) px" })

                slider(label: "Corner radius",
                       value: $document.cornerRadius,
                       range: 0...80,
                       format: { "\(Int($0)) px" })

                Toggle("Shadow", isOn: Binding(
                    get: { document.shadow },
                    set: { v in
                        document.registerUndo()
                        document.shadow = v
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Divider()

                Text("Screenshot background")
                    .font(.headline)

                slider(label: "Extend background",
                       value: $document.backgroundExtension,
                       range: 0...240,
                       format: { "\(Int($0)) px" })

                HStack(spacing: 8) {
                    Button {
                        document.registerUndo()
                        ColorPanelBridge.shared.present(
                            initial: (document.extensionColor ?? .black).nsColor) { nsColor in
                            document.extensionColor = RGBA(color: Color(nsColor: nsColor))
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill((document.extensionColor ?? .black).color)
                            .frame(width: 34, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Background color (auto-detected from the image edges)")

                    Button("Normalize margins") {
                        document.normalizeMargins()
                    }
                    .controlSize(.small)
                    .help("Trim uneven background around the content, then extend it evenly")
                }

                Text("Grows the screenshot's own background — e.g. extend a terminal's dark backdrop before adding canvas padding.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Canvas background")
                    .font(.headline)

                noneButton

                Text("Gradients")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 8)], spacing: 8) {
                    ForEach(0..<CanvasBackground.gradients.count, id: \.self) { i in
                        gradientSwatch(i)
                    }
                }

                Text("Solid colors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 8)], spacing: 8) {
                    ForEach(Array(solidChoices.enumerated()), id: \.offset) { _, rgba in
                        solidSwatch(rgba)
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var solidChoices: [RGBA] {
        RGBA.palette + [
            RGBA(r: 0.95, g: 0.95, b: 0.97, a: 1),
            RGBA(r: 0.16, g: 0.17, b: 0.21, a: 1),
            RGBA(r: 0.87, g: 0.91, b: 0.98, a: 1),
            RGBA(r: 0.93, g: 0.87, b: 0.80, a: 1),
        ]
    }

    private func slider(label: String,
                        value: Binding<CGFloat>,
                        range: ClosedRange<Double>,
                        format: @escaping (CGFloat) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = CGFloat($0) }),
                   in: range) { editing in
                if editing, !sliderUndoRegistered {
                    document.registerUndo()
                    sliderUndoRegistered = true
                } else if !editing {
                    sliderUndoRegistered = false
                }
            }
            .controlSize(.small)
        }
    }

    private var noneButton: some View {
        Button {
            document.registerUndo()
            document.background = .none
        } label: {
            HStack {
                CheckerboardView()
                    .frame(width: 28, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("None (transparent)")
                    .font(.system(size: 11))
                Spacer()
                if document.background == .none {
                    Image(systemName: "checkmark").font(.caption.bold())
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func gradientSwatch(_ index: Int) -> some View {
        let colors = CanvasBackground.gradients[index]
        let isSelected = document.background == .gradient(index)
        return Button {
            document.registerUndo()
            document.background = .gradient(index)
            applyNiceDefaultsIfNeeded()
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [colors[0].color, colors[1].color],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.2),
                                  lineWidth: isSelected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func solidSwatch(_ rgba: RGBA) -> some View {
        let isSelected = document.background == .solid(rgba)
        return Button {
            document.registerUndo()
            document.background = .solid(rgba)
            applyNiceDefaultsIfNeeded()
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(rgba.color)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.25),
                                  lineWidth: isSelected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Picking a background with zero padding looks like nothing happened;
    /// give the composition pleasant defaults on first use.
    private func applyNiceDefaultsIfNeeded() {
        if document.padding == 0 {
            document.padding = 64
            document.cornerRadius = max(document.cornerRadius, 16)
            document.shadow = true
        }
    }
}
