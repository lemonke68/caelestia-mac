// Tray in SketchyBar: background apps with a menu bar item (Karing, FlClashX, Tailscale…).
// The real macOS menu bar is transparent under SketchyBar, so rice-shell mirrors each app as
// a SketchyBar item with the app's icon; clicking it presses the app's own menu bar item
// through Accessibility, which opens the app's native menu (caelestia bar Tray).

import AppKit
import ApplicationServices

final class TrayService {
    static let shared = TrayService()

    private let sketchybar = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private var shown: [String] = []
    private var timer: Timer?
    private let queue = DispatchQueue(label: "rice.tray")

    /// Not mirrored: Apple's own extras and our own pieces.
    private let skip: Set<String> = ["com.mac-rice.shell", "com.felixkratz.sketchybar"]

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.sync() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.sync() }
        sync()
    }

    /// SketchyBar was reloaded (theme switch): its items are gone, add them again.
    func resync() {
        shown = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.sync() }
    }

    private func extrasMenuBar(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    func sync() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return !id.hasPrefix("com.apple.") && !skip.contains(id)
        }
        queue.async {
            let ids = apps.compactMap { app -> String? in
                guard let bar = self.extrasMenuBar(app.processIdentifier), !self.children(bar).isEmpty else { return nil }
                return app.bundleIdentifier
            }.sorted()
            DispatchQueue.main.async { self.apply(ids) }
        }
    }

    private func apply(_ ids: [String]) {
        guard ids != shown, let sketchybar else { return }
        var args: [String] = []
        for id in shown where !ids.contains(id) { args += ["--remove", "tray.\(id)"] }
        args += ["--remove", "tray_bracket"]
        let cli = binDir.appendingPathComponent("rice-shell").path
        for id in ids where !shown.contains(id) {
            args += ["--add", "item", "tray.\(id)", "right",
                     "--set", "tray.\(id)",
                     "background.image=app.\(id)", "background.image.scale=0.5", "background.drawing=on",
                     "background.color=0x00000000", "icon.drawing=off", "label.drawing=off", "width=26",
                     "padding_left=1", "padding_right=1",
                     "click_script=\(cli) tray-click \(id)"]
        }
        if !ids.isEmpty {
            args += ["--add", "bracket", "tray_bracket", "/tray\\..*/"]
        }
        shown = ids
        shell(sketchybar, args)
    }

    /// Open the app's own menu bar menu.
    func click(_ bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let bar = extrasMenuBar(app.processIdentifier),
              let item = children(bar).first else { return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }
}

/// Screen recording indicator in SketchyBar. A Cmd+Shift+5 recording puts its Stop button into
/// screencaptureui's menu bar extras, which SketchyBar covers; show a red pill with the elapsed
/// time instead, and press that Stop button through Accessibility when the pill is clicked.
final class RecordingService {
    static let shared = RecordingService()

    private let sketchybar = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private let bundleID = "com.apple.screencaptureui"
    private var started: Date?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "rice.recording")

    func start() {
        // screencaptureui is spawned on demand and sends no launch notification: poll it
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// SketchyBar was reloaded: add the pill again on the next tick.
    func resync() {
        if started != nil { started = nil; poll() }
    }

    private func stopButton() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            "AXExtrasMenuBar" as CFString, &bar) == .success else { return nil }
        var items: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &items)
        return (items as? [AXUIElement])?.first
    }

    private func poll() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty || started != nil else { return }
        queue.async {
            let recording = self.stopButton() != nil
            DispatchQueue.main.async { self.update(recording) }
        }
    }

    private func update(_ recording: Bool) {
        guard let sketchybar else { return }
        switch (recording, started) {
        case (true, nil):
            started = Date()
            let theme = Theme.shared
            let bg = "0xff" + (theme.colours["error"] ?? "c9524f")
            let fg = "0xff" + (theme.colours["onError"] ?? "000000")
            let cli = binDir.appendingPathComponent("rice-shell").path
            shell(sketchybar, ["--add", "item", "recording", "right",
                               "--set", "recording",
                               "icon=\u{F044A}", "icon.color=\(fg)", "label=0:00", "label.color=\(fg)",
                               "label.font=JetBrainsMono Nerd Font:Bold:12.0",
                               "background.color=\(bg)", "background.drawing=on",
                               "click_script=\(cli) record-stop"])
        case (true, let start?):
            let s = Int(Date().timeIntervalSince(start))
            shell(sketchybar, ["--set", "recording", "label=\(s / 60):" + String(format: "%02d", s % 60)])
        case (false, _?):
            started = nil
            shell(sketchybar, ["--remove", "recording"])
        case (false, nil):
            break
        }
    }

    func stop() {
        queue.async {
            guard let button = self.stopButton() else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            DispatchQueue.main.async { self.poll() }
        }
    }
}
