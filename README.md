# OpenScreenshot

An open-source screenshot, screen-recording and annotation tool for macOS.
Built entirely in Swift + SwiftUI on top of ScreenCaptureKit.

## Features

**Capture**
- Area capture over a frozen screen, with crosshair, pixel magnifier, live dimensions,
  and snapping to window/screen edges
- Window capture with a soft drop shadow on a transparent background — applied as
  editable canvas styling, not baked pixels
- Fullscreen capture, All-in-One mode (selection + capture/record/GIF toolbar)
- Capture Previous Area (re-shoot the exact same region)
- Self-timer captures (3/5/10 s) with an on-screen countdown
- Scrolling capture: scroll any window while frames are stitched into one tall image
  (manual scrolling, optional auto-scroll via Accessibility)
- Capture Text (OCR) via the Vision framework, plus QR-code recognition

**Recording**
- MP4 (H.264 + AAC) screen recording of an area, window, or display
- System audio, and microphone on macOS 15+
- GIF recording with configurable frame rate
- Webcam overlay bubble, mouse-click highlights, keystroke overlay, countdown
- Post-record editor: filmstrip trimmer with playhead, export trimmed MP4 or GIF

**Workflow**
- Quick Access Overlay: floating thumbnail stack with drag & drop to any app,
  save/copy/annotate/pin actions, auto-close option
- Annotation editor: arrow, line, rectangle, ellipse, pen, highlighter, text,
  auto-incrementing counter badges, blur, pixelate with adjustable intensity,
  spotlight, crop, and a canvas sidebar (padding, solid/gradient backgrounds,
  rounded corners, shadow)
- Pin screenshots as floating always-on-top windows (scroll to resize,
  ⌥-scroll for opacity, double-click for actual size)
- Capture History window (restore, copy, re-edit, pin, delete)
- Hide desktop icons (wallpaper overlay, no Finder restart)
- Fully rebindable global hotkeys, menu bar app (no Dock icon)

A cloud upload service is intentionally out of scope for now.

## Installing

Download the latest release from GitHub, or:

**Nix (nix-darwin / home-manager)** — the repo ships a flake that packages each
release (auto-updated by CI):

```nix
# flake inputs
inputs.openscreenshot.url = "github:ostoolkit/openscreenshot";

# nix-darwin module
{ pkgs, inputs, ... }: {
  environment.systemPackages = [
    inputs.openscreenshot.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
```

nix-darwin links the app into `/Applications/Nix Apps`. Or imperatively:
`nix profile install github:ostoolkit/openscreenshot`. Nix downloads skip the
quarantine flag, so unsigned releases open without Gatekeeper friction; note
that the Screen Recording permission re-prompts after updates while releases
are ad-hoc signed.

## Building

Requirements: Xcode 15+ (developed against Xcode 26), macOS 14+,
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project OpenScreenshot.xcodeproj -scheme OpenScreenshot -configuration Debug build
```

Or open `OpenScreenshot.xcodeproj` in Xcode and run.

### Permissions

- **Screen Recording** (required): the app prompts on first launch. macOS requires a
  relaunch after granting.
- **Microphone / Camera**: only when you enable mic recording or the webcam overlay.
- **Accessibility**: only for auto-scroll (scrolling capture) and the keystroke overlay.

The build signs with an Apple Development certificate (`CODE_SIGN_STYLE: Automatic`),
so permission grants survive rebuilds. If you don't have a development certificate,
change `CODE_SIGN_IDENTITY` to `"-"` in `project.yml` (ad-hoc) — but note every rebuild
then invalidates TCC grants. To reset permissions while testing:
`tccutil reset ScreenCapture com.ostoolkit.openscreenshot`.

## Default shortcuts

OpenScreenshot takes over the macOS screenshot shortcuts while it runs (app hotkeys
take precedence over the system ones). Everything else ships unbound; all actions are
rebindable in Settings → Shortcuts.

| Action | Shortcut |
|---|---|
| Capture Fullscreen | ⇧⌘3 |
| Capture Area | ⇧⌘4 (Space toggles window mode) |
| All-in-One | ⇧⌘5 |
| Capture Window / OCR / Record / Scrolling / Pin / History | unbound by default |

During selection: **drag** to select, **click** a window to capture it (window mode),
hold **Space** to move the selection, **⇧** constrains to a square, **arrows** nudge,
**Return** confirms, **Esc** cancels.

## Known limitations

- Scrolling capture struggles with sticky headers and virtualized lists.
- Microphone recording requires macOS 15 (ScreenCaptureKit microphone output).
- GIF export uses ImageIO; quality is decent but not gifski-grade.
- No cloud uploads yet.

## License

MIT
