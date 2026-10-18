// rice-shell: caelestia-style shell for macOS (frame, vertical bar, panels).
//
//   rice-shell                    run (launchd agent com.mac-rice.shell)
//   rice-shell spaces-changed     yabai signals: refresh workspaces / active window
//   rice-shell theme-changed      theme-switch: reload colours
//   rice-shell toggle <panel>     open/close a panel (session, dashboard, …)
//   rice-shell dashboard <tab>    open the dashboard on dashboard|media|performance|weather
//   rice-shell popout wifi|bluetooth <x>   SketchyBar click: popout under the icon at x
//   rice-shell tray-click <bundle id>      SketchyBar tray: open that app's menu bar menu
//   rice-shell record-stop                 SketchyBar recording pill: stop the screen recording
//   rice-shell screen-info                 print bar geometry for this Mac as shell variables
//   rice-shell space-key <N>               focus desktop N via ctrl + N (no scripting addition)
//   rice-shell setup                       open the setup window (permissions, full mode)

import AppKit
import Combine
import SwiftUI

enum Shell {
    static let notification = Notification.Name("rice.shell")

    static func post(_ args: String...) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: args.joined(separator: " "), userInfo: nil, deliverImmediately: true)
    }
}

final class App: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var session: SessionController?
    private var dashboard: DashboardController?
    private var launcher: LauncherController?
    private var osd: OsdController?
    private var popouts: PopoutController?
    private let setup = SetupController()
    private var fullscreenSub: AnyCancellable?
    private var clickThrough: [ObjectIdentifier: Bool] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindows()
        TrayService.shared.start()
        fullscreenSub = SpacesService.shared.$fullscreen.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.setFullscreen($0) }
        RecordingService.shared.start()
        FocusWatchdog.shared.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Windows created behind the lock screen (agent restarted while locked) keep its
        // zoomed-out transform; laying them out again after unlock puts them back.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screensChanged), name: .init("com.apple.screenIsUnlocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: Shell.notification, object: nil)
    }

    @objc private func screensChanged() { buildWindows() }

    /// SketchyBar and yabai follow the screen too: a Mac without a notch, the lid closed on an
    /// external display. sketchybarrc and yabairc read the same values at load.
    private func applyBarGeometry() {
        let g = Geometry(primaryScreen)
        DispatchQueue.global().async {
            if let sketchybar = sketchybarPath {
                shell(sketchybar, ["--bar", "height=\(Int(g.bar))", "notch_width=\(Int(g.notchWidth))"])
            }
            shell(yabaiPath, ["-m", "config", "external_bar", "all:\(Int(g.externalBar)):0"])
        }
    }

    /// Native fullscreen space: hide the frame, the vertical bar and SketchyBar, so the window
    /// gets the whole screen; bring them back when leaving it.
    /// The windows stay ordered in and only turn invisible: an orderOut/orderFront round trip
    /// drops them from all spaces but the current one.
    private func setFullscreen(_ on: Bool) {
        for window in windows {
            let id = ObjectIdentifier(window)
            if on {
                if window.alphaValue > 0 { clickThrough[id] = window.ignoresMouseEvents }
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            } else {
                window.alphaValue = 1
                window.ignoresMouseEvents = clickThrough[id] ?? window.ignoresMouseEvents
            }
        }
        if let sketchybar = sketchybarPath {
            DispatchQueue.global().async { shell(sketchybar, ["--bar", "hidden=\(on ? "on" : "off")"]) }
        }
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        guard let screen = primaryScreen else { return }
        applyBarGeometry()
        windows = [makeFrameWindow(on: screen), makeBarWindow(on: screen)]
        session?.panel.close()
        session = SessionController(screen: screen)
        dashboard?.panel.close()
        dashboard = DashboardController(screen: screen)
        launcher?.panel.close()
        launcher = LauncherController(screen: screen)
        osd?.panel.close()
        osd = OsdController(screen: screen)
        popouts = PopoutController(screen: screen)
        clickThrough = [:]
        windows.forEach { $0.orderFrontRegardless() }
        if SpacesService.shared.fullscreen { setFullscreen(true) }
    }

    @objc private func command(_ note: Notification) {
        let args = (note.object as? String ?? "").split(separator: " ").map(String.init)
        // Logged so a hotkey that "does nothing" can be told apart from a lost notification
        if args.first != "spaces-changed" { FileHandle.standardError.write(Data("command: \(args.joined(separator: " "))\n".utf8)) }
        switch args.first {
        case "spaces-changed":
            SpacesService.shared.refresh()
        case "theme-changed":
            Theme.shared.reload()
            TrayService.shared.resync()  // theme-switch reloads SketchyBar
            RecordingService.shared.resync()
        case "popout":
            if args.count >= 3, let x = Double(args[2]) { popouts?.toggle(args[1], x: CGFloat(x)) }
        case "tray-click":
            if args.count >= 2 { TrayService.shared.click(args[1]) }
        case "record-stop":
            RecordingService.shared.stop()
        case "setup":
            setup.show()
        case "dashboard":
            if let tab = args.dropFirst().first { dashboard?.show(tab: tab) }
        case "toggle":
            switch args.dropFirst().first {
            case "session": session?.toggle()
            case "dashboard": dashboard?.toggle()
            case "launcher": launcher?.toggle()
            case "osd": osd?.show()
            default: break
            }
        default:
            break
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "screen-info" {
    print(Geometry(primaryScreen).shellVars)
    exit(0)
}
if args.first == "space-key", args.count >= 2, let n = Int(args[1]) {
    exit(SpaceKeys.focus(n) ? 0 : 1)
}
if !args.isEmpty {
    DistributedNotificationCenter.default().postNotificationName(
        Shell.notification, object: args.joined(separator: " "), userInfo: nil, deliverImmediately: true)
    exit(0)
}

// Clean exit on SIGTERM (launchd): stop child processes first
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    MediaService.shared.shutdown()
    exit(0)
}
termSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
