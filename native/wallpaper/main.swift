// rice-wallpaper: animated (gif) and static wallpaper for macOS, Caelestia-style.
//
//   rice-wallpaper              run the daemon (launchd agent)
//   rice-wallpaper set <path>   remember <path> and tell the running daemon to show it
//   rice-wallpaper get          print the current wallpaper
//
// The image fills every screen and is cropped to the screen's aspect ratio
// (Qt's PreserveAspectCrop in the Arch shell patch). Windows sit at desktop level,
// below the Finder icons, on every Space.

import AppKit

let statePath = NSString(string: "~/.local/state/mac-rice/wallpaper").expandingTildeInPath
let changedNotification = Notification.Name("rice.wallpaper.changed")

func readState() -> String? {
    guard let raw = try? String(contentsOfFile: statePath, encoding: .utf8) else { return nil }
    let path = NSString(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    return path.isEmpty ? nil : path
}

final class Wallpaper: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var frames: Frames?

    func applicationDidFinishLaunching(_ notification: Notification) {
        load()
        rebuildWindows()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed), name: changedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Windows created behind the lock screen (an agent restarted while locked) keep its
        // zoomed-out transform; laying them out again after unlock puts them back.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screensChanged), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    private func load() {
        frames = readState().flatMap { Frames(path: $0) }
    }

    @objc private func changed() {
        load()
        for case let view as FillView in windows.compactMap(\.contentView) {
            if let frames { view.show(frames) }
        }
    }

    @objc private func screensChanged() { rebuildWindows() }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isOpaque = true
            let view = FillView(frame: NSRect(origin: .zero, size: screen.frame.size))
            if let frames { view.show(frames) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak view, weak window] _ in
                // Stop animating while windows fully cover the desktop.
                view?.paused = !(window?.occlusionState.contains(.visible) ?? true)
            }
            return window
        }
    }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "set":
    guard let raw = args.dropFirst().first else {
        FileHandle.standardError.write("usage: rice-wallpaper set <path>\n".data(using: .utf8)!)
        exit(2)
    }
    let path = NSString(string: raw).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: path) else {
        FileHandle.standardError.write("no such file: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    try FileManager.default.createDirectory(
        atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try path.write(toFile: statePath, atomically: true, encoding: .utf8)
    DistributedNotificationCenter.default().postNotificationName(
        changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
case "get":
    print(readState() ?? "")
case nil:
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Wallpaper()
    app.delegate = delegate
    app.run()
default:
    FileHandle.standardError.write("usage: rice-wallpaper [set <path> | get]\n".data(using: .utf8)!)
    exit(2)
}
