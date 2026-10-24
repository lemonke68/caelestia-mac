// Setup window (`rice-shell setup`, opened by install.sh and `rice setup`): what macOS only
// lets the user grant, each row with the button that gets it done (the right System Settings
// pane, the system prompt, a restart), plus basic / full mode. Services come from
// `rice doctor --plain`; rice-shell's own permissions are checked in-process. Refreshes every
// 2 s while open, so rows turn green as the switches are flipped.

import AppKit
import CoreBluetooth
import CoreLocation
import SwiftUI

enum SetupStatus: String { case ok, warn, fail, off }

enum SetupAction: Equatable {
    case settings(String)  // x-apple.systempreferences anchor
    case askAccessibility, askLocation, askBluetooth
    case run(String, [String])  // background command, e.g. yabai --start-service
    case terminal(String)       // `rice <subcommand>` in a Terminal window (needs the password)

    var title: String {
        switch self {
        case .settings: return "Open Settings"
        case .askAccessibility, .askLocation, .askBluetooth: return "Allow"
        case .run: return "Start"
        case .terminal: return "Enable…"
        }
    }
}

struct SetupRow: Identifiable, Equatable {
    let id: String
    let status: SetupStatus
    let title: String
    let hint: String
    let action: SetupAction?
}

final class SetupModel: ObservableObject {
    @Published var services: [SetupRow] = []
    @Published var own: [SetupRow] = []
    @Published var mode: SetupRow?

    private var timer: Timer?
    private var bluetooth: CBCentralManager?
    private let queue = DispatchQueue(label: "rice.setup")

    var allGreen: Bool { (services + own).allSatisfy { $0.status != .fail } }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        queue.async {
            let text = String(data: shell(binDir.appendingPathComponent("rice").path, ["doctor", "--plain"]),
                              encoding: .utf8) ?? ""
            var rows: [SetupRow] = []
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 3 else { continue }
                let status = SetupStatus(rawValue: f[1]) ?? .warn
                rows.append(SetupRow(id: f[0], status: status, title: f[2], hint: f.count > 3 ? f[3] : "",
                                     action: status == .ok ? nil : Self.action(for: f[0], hint: f.count > 3 ? f[3] : "")))
            }
            DispatchQueue.main.async {
                let mode = rows.first { $0.id == "mode" }.map {
                    $0.status == .off ? SetupRow(id: $0.id, status: .off, title: "Basic mode",
                                                 hint: "full mode: button on the right", action: $0.action) : $0
                }
                let services = rows.filter { $0.id != "mode" }
                let own = self.ownRows()
                if self.services != services { self.services = services }
                if self.own != own { self.own = own }
                if self.mode != mode { self.mode = mode }
                // Granted while rice-shell was running: take the media keys over now
                if AXIsProcessTrusted() { _ = MediaKeys.shared.start() }
            }
        }
    }

    private static let accessibilityPane = "Privacy_Accessibility"

    private static func action(for id: String, hint: String) -> SetupAction? {
        switch id {
        case "yabai", "skhd":
            if hint.contains("Accessibility") { return .settings(accessibilityPane) }
            return .run("/bin/sh", ["-c", "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; \(id) --restart-service || \(id) --start-service"])
        case "sketchybar", "borders", "shell", "wallpaper":
            return .run(binDir.appendingPathComponent("rice").path, ["restart"])
        case "mode":
            return .terminal("sa")
        default:
            return nil
        }
    }

    private func ownRows() -> [SetupRow] {
        var rows: [SetupRow] = []
        let ax = AXIsProcessTrusted()
        rows.append(SetupRow(id: "ax", status: ax ? .ok : .fail,
                             title: ax ? "Accessibility" : "Accessibility: off",
                             hint: "media keys, tray, screen recording",
                             action: ax ? nil : .askAccessibility))

        let location = LocationService.shared.authorization
        let locStatus: SetupStatus = location == .authorized || location == .authorizedAlways ? .ok
            : location == .notDetermined ? .warn : .fail
        rows.append(SetupRow(id: "location", status: locStatus,
                             title: locStatus == .ok ? "Location Services" : "Location Services: off",
                             hint: "weather by city and Wi-Fi network names",
                             action: locStatus == .ok ? nil : location == .notDetermined ? .askLocation
                                : .settings("Privacy_LocationServices")))

        let bt = CBManager.authorization
        let btStatus: SetupStatus = bt == .allowedAlways ? .ok : bt == .notDetermined ? .warn : .fail
        rows.append(SetupRow(id: "bluetooth", status: btStatus,
                             title: btStatus == .ok ? "Bluetooth" : "Bluetooth: off",
                             hint: "devices in the Bluetooth panel",
                             action: btStatus == .ok ? nil : bt == .notDetermined ? .askBluetooth
                                : .settings("Privacy_Bluetooth")))

        rows.append(SetupRow(id: "audio", status: .off, title: "System audio recording",
                             hint: "visualizer; macOS asks the first time the Media tab opens", action: nil))
        return rows
    }

    func perform(_ action: SetupAction) {
        switch action {
        case .settings(let anchor):
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
        case .askAccessibility:
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(prompt) { perform(.settings(Self.accessibilityPane)) }
        case .askLocation:
            LocationService.shared.requestAccess()
        case .askBluetooth:
            bluetooth = CBCentralManager(delegate: nil, queue: nil)  // creating one shows the prompt
        case .run(let path, let args):
            queue.async { shell(path, args) }
        case .terminal(let sub):
            // A .command file opens in Terminal, where sudo can ask for the password
            let file = URL(fileURLWithPath: expand("~/.local/state/mac-rice/rice-\(sub).command"))
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "#!/bin/bash\nexec \"\(binDir.appendingPathComponent("rice").path)\" \(sub)\n"
                .write(to: file, atomically: true, encoding: .utf8)
            chmod(file.path, 0o755)
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }
}

// MARK: - View

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var theme = Theme.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: T.l) {
            HStack(spacing: T.m) {
                MIcon(name: "tune", size: 28, color: theme["primary"])
                VStack(alignment: .leading, spacing: 2) {
                    Text("mac-rice Setup").font(.body(T.fontLarge, .semibold)).foregroundStyle(theme["onSurface"])
                    Text("Only you can grant these permissions in macOS: use the button on the right.")
                        .font(.body(T.fontSmaller)).foregroundStyle(theme["onSurfaceVariant"])
                }
            }

            // Working services fold into one line: the window has to fit a 13" screen
            if model.services.allSatisfy({ $0.status == .ok }) && !model.services.isEmpty {
                section("Services", [SetupRow(id: "services", status: .ok, title: "All services running",
                                            hint: "yabai, skhd, SketchyBar, borders, rice-shell, wallpapers", action: nil)])
            } else {
                section("Services", model.services)
            }
            section("rice-shell", model.own)

            if let mode = model.mode {
                VStack(alignment: .leading, spacing: T.s) {
                    Text("Mode").font(.body(T.fontNormal, .semibold)).foregroundStyle(theme["primary"])
                    SetupRowView(row: mode, perform: model.perform)
                    if mode.status != .ok {
                        Text("Basic mode: spaces are created in Mission Control (F3 → \"+\"), switched with alt + number. Full mode adds on-the-fly space creation, moving windows between spaces and a transparent menu bar, but requires a one-time boot into Recovery to partially disable SIP.")
                            .font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Text(model.allGreen ? "All set." : "Red rows still need attention.")
                    .font(.body(T.fontSmaller)).foregroundStyle(theme["onSurfaceVariant"])
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                    .buttonStyle(SetupButtonStyle(filled: true))
            }
        }
        .padding(T.xl)
        .frame(width: 560)
        .background(theme["surface"])
    }

    private func section(_ title: String, _ rows: [SetupRow]) -> some View {
        VStack(alignment: .leading, spacing: T.s) {
            Text(title).font(.body(T.fontNormal, .semibold)).foregroundStyle(theme["primary"])
            ForEach(rows) { SetupRowView(row: $0, perform: model.perform) }
        }
    }
}

struct SetupRowView: View {
    let row: SetupRow
    let perform: (SetupAction) -> Void
    @ObservedObject var theme = Theme.shared

    private var icon: (String, String) {
        switch row.status {
        case .ok: return ("check_circle", "primary")
        case .warn: return ("error", "tertiary")
        case .fail: return ("cancel", "error")
        case .off: return ("radio_button_unchecked", "outline")
        }
    }

    var body: some View {
        HStack(spacing: T.m) {
            MIcon(name: icon.0, size: 20, color: theme[icon.1])
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.body(T.fontNormal)).foregroundStyle(theme["onSurface"])
                if !row.hint.isEmpty {
                    Text(row.hint).font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
                }
            }
            Spacer()
            if let action = row.action {
                Button(action.title) { perform(action) }.buttonStyle(SetupButtonStyle(filled: row.status == .fail))
            }
        }
        .padding(.horizontal, T.m)
        .padding(.vertical, T.s)
        .background(RoundedRectangle(cornerRadius: T.m, style: .continuous).fill(theme["surfaceContainer"]))
    }
}

/// Theme-coloured pill: filled for what needs doing now, tonal otherwise.
struct SetupButtonStyle: ButtonStyle {
    let filled: Bool
    @ObservedObject var theme = Theme.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body(T.fontSmaller, .medium))
            .foregroundStyle(theme[filled ? "onPrimary" : "onSecondaryContainer"])
            .padding(.horizontal, T.m)
            .padding(.vertical, T.xs + 2)
            .background(Capsule().fill(theme[filled ? "primary" : "secondaryContainer"]))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Window

final class SetupController: NSObject, NSWindowDelegate {
    private let model = SetupModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SetupView(model: model) { [weak w] in w?.close() })
            window = w
        }
        model.start()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
}
