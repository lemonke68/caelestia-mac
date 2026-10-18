// rice-picker: fullscreen coverflow wallpaper picker, a port of the Arch shell patch
// caelestia/shell-patches/modules/wallpaperpicker/Content.qml.
//
// ← / → or the wheel move, Enter or a click on the centre card applies, Esc or a click
// on the scrim closes and restores the wallpaper you started with. Moving previews the
// wallpaper live (debounced 180 ms). Running it again (or SIGTERM) closes it, so one
// hotkey toggles. Colours come from the current mac-rice theme's scheme.txt.

import AppKit
import SwiftUI

let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let riceRoot = binDir.deletingLastPathComponent()
let statePath = NSString(string: "~/.local/state/mac-rice/wallpaper").expandingTildeInPath

func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

// MARK: - Theme

extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0x888888
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

struct Theme {
    var colours: [String: String] = [:]
    var wallpaperDir = expand("~/.config/assets/media")

    subscript(role: String) -> Color { Color(hex: colours[role] ?? "888888") }

    static func load() -> Theme {
        var theme = Theme()
        let name = (try? String(contentsOfFile: expand("~/.local/state/mac-rice/theme"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "hyprlain"
        let dir = riceRoot.appendingPathComponent("themes/\(name)")
        if let text = try? String(contentsOf: dir.appendingPathComponent("scheme.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 2 { theme.colours[String(parts[0])] = String(parts[1]) }
            }
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("theme.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let wallDir = json["wallpaperDir"] as? String {
            theme.wallpaperDir = expand(wallDir)
        }
        return theme
    }
}

// MARK: - Model

struct Wall: Hashable {
    let path: String
    let relativePath: String

    var category: String? {
        relativePath.contains("/") ? String(relativePath.split(separator: "/")[0]) : nil
    }
    var isGif: Bool { path.lowercased().hasSuffix(".gif") }
}

func scanWallpapers(in dir: String) -> [Wall] {
    let extensions: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]
    guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
    var walls: [Wall] = []
    while let rel = walker.nextObject() as? String {
        // Same depth as wallpaper-next: <dir>/<category>/<file>, so anim/icons stays out
        if walker.level >= 2, (walker.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
            walker.skipDescendants()
            continue
        }
        let ext = (rel as NSString).pathExtension.lowercased()
        if extensions.contains(ext) {
            walls.append(Wall(path: (dir as NSString).appendingPathComponent(rel), relativePath: rel))
        }
    }
    return walls.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
}

final class Picker: ObservableObject {
    let theme = Theme.load()
    let all: [Wall]
    let original: String
    let categories: [String]

    @Published private(set) var walls: [Wall] = []
    @Published var sel = 0 { didSet { schedulePreview() } }
    @Published var search = "" { didSet { refilter() } }
    @Published var category = "" { didSet { refilter() } }
    @Published var thumbs: [String: CGImage] = [:]
    @Published var entered = false

    private var previewWork: DispatchWorkItem?
    private var confirmed = false
    private var closing = false

    init() {
        all = scanWallpapers(in: theme.wallpaperDir)
        categories = Array(Set(all.compactMap(\.category))).sorted()
        original = ((try? String(contentsOfFile: statePath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        walls = all
        sel = all.firstIndex { $0.path == original } ?? 0
        previewWork?.cancel()  // opening must not re-set the current wallpaper
    }

    var current: Wall? { walls.indices.contains(sel) ? walls[sel] : nil }

    func go(_ delta: Int) {
        guard !walls.isEmpty else { return }
        sel = (sel + delta + walls.count) % walls.count
    }

    func jump(to index: Int) {
        guard walls.indices.contains(index) else { return }
        sel = index
    }

    private func refilter() {
        let keep = current?.path
        walls = all.filter {
            (category.isEmpty || $0.category == category)
                && (search.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(search))
        }
        sel = walls.firstIndex { $0.path == keep } ?? 0
    }

    private func schedulePreview() {
        previewWork?.cancel()
        guard let path = current?.path else { return }
        let work = DispatchWorkItem { [weak self] in self?.setWallpaper(path) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func setWallpaper(_ path: String) {
        let task = Process()
        task.executableURL = binDir.appendingPathComponent("rice-wallpaper")
        task.arguments = ["set", path]
        try? task.run()
        task.waitUntilExit()
    }

    func confirm() {
        previewWork?.cancel()
        if let path = current?.path { setWallpaper(path) }
        confirmed = true
        close()
    }

    func close() {
        guard !closing else { return }
        closing = true
        previewWork?.cancel()
        if !confirmed, !original.isEmpty { setWallpaper(original) }
        withAnimation(.easeIn(duration: 0.18)) { entered = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    /// Decode thumbnails in the background, nearest to the selection first.
    func loadThumbs(maxPixel: Int) {
        let start = sel
        let order = all.indices.sorted { abs($0 - start) < abs($1 - start) }.map { all[$0].path }
        DispatchQueue.global(qos: .userInitiated).async {
            for path in order {
                guard let frames = Frames(path: path, maxPixel: maxPixel, firstOnly: true) else { continue }
                let image = frames.images[0]
                DispatchQueue.main.async { self.thumbs[path] = image }
            }
        }
    }
}

// MARK: - Views

/// Plays a gif inside SwiftUI via the shared layer-backed FillView.
struct AnimatedWallpaper: NSViewRepresentable {
    let path: String
    let maxPixel: Int

    func makeNSView(context: Context) -> FillView {
        let view = FillView(frame: .zero, background: .clear)
        let path = path, maxPixel = maxPixel
        DispatchQueue.global(qos: .userInitiated).async {
            guard let frames = Frames(path: path, maxPixel: maxPixel) else { return }
            DispatchQueue.main.async { view.show(frames) }
        }
        return view
    }

    func updateNSView(_ nsView: FillView, context: Context) {}
}

/// Shear along x around the centre of a w×h box (Qt's Matrix4x4(1, skew, …)).
func shear(_ k: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGAffineTransform {
    CGAffineTransform(translationX: -w / 2, y: -h / 2)
        .concatenating(CGAffineTransform(a: 1, b: 0, c: k, d: 1, tx: 0, ty: 0))
        .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
}

struct PickerView: View {
    @ObservedObject var m: Picker
    let size: CGSize

    // Geometry from Content.qml
    let skew: CGFloat = -0.3
    let sideRatio: CGFloat = 0.3
    let gap: CGFloat = 6
    let rounding: CGFloat = 28  // Tokens.rounding.extraLarge
    var cardW: CGFloat { max(260, min(size.width * 0.46, size.height * 0.52 * 16 / 9, 780)) }
    var cardH: CGFloat { cardW * 9 / 16 }
    var imageW: CGFloat { cardW + abs(skew) * cardH * 2 + 60 }

    private func dist(_ i: Int) -> Int { abs(i - m.sel) }

    private func width(_ i: Int) -> CGFloat {
        let d = dist(i)
        return d == 0 ? cardW : cardW * sideRatio * max(0.58, pow(0.88, CGFloat(d - 1)))
    }

    private func height(_ i: Int) -> CGFloat {
        let d = dist(i)
        return d == 0 ? cardH : cardH * max(0.62, pow(0.9, CGFloat(d - 1)))
    }

    private func radius(_ i: Int) -> CGFloat { rounding * max(0.45, pow(0.85, CGFloat(dist(i)))) }

    /// x of card i's centre relative to the screen centre; the selection sits at 0.
    private func centerX(_ i: Int) -> CGFloat {
        if i == m.sel { return 0 }
        let dir = i > m.sel ? 1 : -1
        var x = (cardW + gap) / 2
        var j = m.sel + dir
        while j != i {
            x += width(j) + gap
            j += dir
        }
        return CGFloat(dir) * (x + (width(i) + gap) / 2)
    }

    private var visible: [Int] {
        guard !m.walls.isEmpty else { return [] }
        let lo = max(0, m.sel - 30), hi = min(m.walls.count - 1, m.sel + 30)
        return (lo...hi).filter { abs(centerX($0)) < size.width / 2 + cardW }
    }

    var body: some View {
        ZStack {
            m.theme["scrim"]
                .opacity(m.entered ? 0.82 : 0)
                .contentShape(Rectangle())
                .onTapGesture { m.close() }

            ZStack {
                ForEach(visible, id: \.self) { i in
                    card(i)
                        .position(x: size.width / 2 + centerX(i), y: size.height / 2)
                        .zIndex(i == m.sel ? 100 : Double(max(1, 50 - dist(i))))
                }
            }
            .frame(width: size.width, height: size.height)
            .opacity(m.entered ? 1 : 0)
            .scaleEffect(m.entered ? 1 : 0.94)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: m.sel)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: m.walls)

            topBar
                .position(x: size.width / 2, y: m.entered ? 80 : -40)
                .opacity(m.entered ? 1 : 0)

            caption
                .position(x: size.width / 2, y: size.height - 70)
                .opacity(m.entered ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            m.loadThumbs(maxPixel: Int(imageW * 2))
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { m.entered = true }
            }
        }
    }

    private func card(_ i: Int) -> some View {
        let wall = m.walls[i]
        let w = width(i), h = height(i), r = radius(i)
        let isCurrent = i == m.sel
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)

        return ZStack {
            m.theme["surfaceContainerHigh"]

            // Always rendered at focused-card size so side cards show a true slice
            ZStack {
                if let thumb = m.thumbs[wall.path] {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .interpolation(thumb.width < 900 ? .none : .medium)
                        .aspectRatio(contentMode: .fill)
                }
                if isCurrent && wall.isGif {
                    AnimatedWallpaper(path: wall.path, maxPixel: Int(imageW * 2))
                }
            }
            .frame(width: imageW, height: cardH)
            .clipped()
            .transformEffect(shear(-skew, imageW, cardH))  // keeps the picture upright

            m.theme["scrim"].opacity(isCurrent ? 0 : 0.35)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(m.theme["primary"], lineWidth: isCurrent ? 2 : 0))
        .transformEffect(shear(skew, w, h))
        .contentShape(Rectangle())
        .onTapGesture { isCurrent ? m.confirm() : m.jump(to: i) }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(m.theme["onSurfaceVariant"])
                .padding(.leading, 4)
            chip("Все", active: m.category.isEmpty) { m.category = "" }
            ForEach(m.categories, id: \.self) { c in
                chip(c, active: m.category == c) { m.category = m.category == c ? "" : c }
            }
            Rectangle().fill(m.theme["outlineVariant"]).frame(width: 1, height: 20).padding(.horizontal, 4)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(m.theme["onSurfaceVariant"])
                TextField("", text: $m.search, prompt: Text("Поиск").foregroundColor(m.theme["onSurfaceVariant"]))
                    .textFieldStyle(.plain)
                    .foregroundStyle(m.theme["onSurface"])
            }
            .padding(.horizontal, 12)
            .frame(width: 210, height: 32)
            .background(Capsule().fill(m.theme["surfaceContainerHighest"]))
            Button { m.close() } label: {
                Image(systemName: "xmark").foregroundStyle(m.theme["onSurfaceVariant"]).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(m.theme["surfaceContainer"]))
        .overlay(Capsule().strokeBorder(m.theme["outlineVariant"], lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? m.theme["onSecondaryContainer"] : m.theme["onSurfaceVariant"])
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(active ? m.theme["secondaryContainer"] : m.theme["surfaceContainerHighest"]))
            .overlay(Capsule().strokeBorder(m.theme["primary"], lineWidth: active ? 1 : 0))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }

    private var caption: some View {
        VStack(spacing: 4) {
            Text(m.current?.relativePath ?? "Обои не найдены")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(m.theme["onSurface"])
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: size.width * 0.6)
            Text(m.walls.isEmpty ? "Проверьте wallpaperDir в theme.json" : "\(m.sel + 1) / \(m.walls.count)")
                .font(.system(size: 11))
                .foregroundStyle(m.theme["onSurfaceVariant"])
        }
    }
}

// MARK: - Window and input

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class App: NSObject, NSApplicationDelegate {
    let model = Picker()
    var window: OverlayWindow!
    var scrollAccum: CGFloat = 0
    var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PickerView(m: model, size: screen.frame.size))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return event.type == .keyDown ? self.key(event) : self.scroll(event)
        }

        // A second launch sends SIGTERM (pkill), which closes like Esc: one hotkey toggles.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in self?.model.close() }
        source.resume()
        sigterm = source
    }

    func applicationDidResignActive(_ notification: Notification) { model.close() }

    private var editingSearch: Bool { window.firstResponder is NSTextView }

    private func key(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53:  // Esc
            if editingSearch {
                if model.search.isEmpty { window.makeFirstResponder(nil) } else { model.search = "" }
            } else {
                model.close()
            }
        case 36, 76:  // Return, Enter
            if editingSearch { window.makeFirstResponder(nil) } else { model.confirm() }
        case 125 where editingSearch:  // Down leaves the search field
            window.makeFirstResponder(nil)
        case 123 where !editingSearch: model.go(-1)
        case 124 where !editingSearch: model.go(1)
        case 115 where !editingSearch: model.jump(to: 0)
        case 119 where !editingSearch: model.jump(to: model.walls.count - 1)
        default:
            return event
        }
        return nil
    }

    // One wheel notch (or ~40pt of trackpad travel) = one wallpaper
    private func scroll(_ event: NSEvent) -> NSEvent? {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollAccum += delta
            if abs(scrollAccum) >= 40 {
                model.go(scrollAccum > 0 ? -1 : 1)
                scrollAccum = 0
            }
        } else if delta != 0 {
            model.go(delta > 0 ? -1 : 1)
        }
        return nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
