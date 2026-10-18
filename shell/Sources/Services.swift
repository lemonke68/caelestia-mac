// System state for the bar: yabai spaces, the active window, battery, Wi-Fi,
// Bluetooth, volume and keyboard layout.

import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import CoreWLAN
import IOBluetooth
import IOKit.ps

@discardableResult
func shell(_ launchPath: String, _ args: [String]) -> Data {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return Data() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return data
}

let yabaiPath = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "yabai"
let sketchybarPath = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"].first { FileManager.default.isExecutableFile(atPath: $0) }

func yabai(_ args: String...) -> Any? {
    try? JSONSerialization.jsonObject(with: shell(yabaiPath, ["-m"] + args))
}

// MARK: - Spaces

struct SpaceInfo: Equatable {
    let index: Int
    let focused: Bool
    let appPIDs: [pid_t]  // one per app, in window order
}

final class SpacesService: ObservableObject {
    static let shared = SpacesService()
    static let minShown = 5  // caelestia bar.workspaces.shown

    @Published private(set) var spaces: [SpaceInfo] = []
    @Published private(set) var activeTitle = ""
    @Published private(set) var activePID: pid_t = 0
    /// The focused space is a native fullscreen space: the shell chrome steps aside.
    @Published private(set) var fullscreen = false

    private let queue = DispatchQueue(label: "rice.spaces")

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    private var pending = false

    /// Coalesced: yabai signals (focus, title changes) can fire in bursts, and each refresh
    /// spawns three `yabai -m query` processes.
    func refresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.pending = false
            self.query()
        }
    }

    private func query() {
        queue.async {
            let spaces = yabai("query", "--spaces", "--display") as? [[String: Any]] ?? []
            let windows = yabai("query", "--windows", "--display") as? [[String: Any]] ?? []
            let focusedWindow = yabai("query", "--windows", "--window") as? [String: Any]

            var pidsBySpace: [Int: [pid_t]] = [:]
            for w in windows where (w["is-minimized"] as? Bool) != true && (w["is-hidden"] as? Bool) != true {
                guard let space = w["space"] as? Int, let pid = w["pid"] as? Int else { continue }
                if !(pidsBySpace[space]?.contains(pid_t(pid)) ?? false) {
                    pidsBySpace[space, default: []].append(pid_t(pid))
                }
            }
            let infos = spaces.compactMap { s -> SpaceInfo? in
                guard let index = s["index"] as? Int else { return nil }
                return SpaceInfo(index: index, focused: s["has-focus"] as? Bool ?? false,
                                 appPIDs: Array((pidsBySpace[index] ?? []).prefix(5)))
            }
            let front = NSWorkspace.shared.frontmostApplication
            let title = (focusedWindow?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? front?.localizedName ?? ""
            let pid = (focusedWindow?["pid"] as? Int).map { pid_t($0) } ?? front?.processIdentifier ?? 0
            // Native fullscreen, or a space put into fullscreen by ~/.config/yabai/fullscreen.sh (alt + F)
            let focusedSpace = spaces.first { $0["has-focus"] as? Bool == true }
            let fakeFullscreen = (try? String(contentsOfFile: expand("~/.local/state/mac-rice/fullscreen-spaces"), encoding: .utf8))?
                .split(separator: "\n").contains { Int($0) == focusedSpace?["id"] as? Int } ?? false
            let fullscreen = focusedSpace?["is-native-fullscreen"] as? Bool ?? false || fakeFullscreen
            DispatchQueue.main.async {
                if self.fullscreen != fullscreen { self.fullscreen = fullscreen }
                if self.spaces != infos { self.spaces = infos }
                self.activeTitle = title
                self.activePID = pid
            }
        }
    }

    func focus(_ index: Int) {
        queue.async { shell("/bin/sh", [expand("~/.config/yabai/space.sh"), "focus", String(index)]) }
    }
}

// MARK: - Status icons

final class StatusService: ObservableObject {
    static let shared = StatusService()

    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var wifiStrength: Int?  // nil = off / not connected
    @Published private(set) var bluetoothOn = false
    @Published private(set) var volume = 0
    @Published private(set) var muted = false
    @Published private(set) var layout = "EN"

    private var timer: Timer?

    private init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.update() }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.updateLayout() }
        watchVolume()
        let loop = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { StatusService.shared.updateBattery() }
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
    }

    func update() {
        updateBattery()
        updateLayout()
        updateVolume()
        if let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 {
            wifiStrength = max(0, min(100, (iface.rssiValue() + 100) * 2))
        } else {
            wifiStrength = nil
        }
        bluetoothOn = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }

    func updateBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let source = list.first,
              let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            battery = nil
            return
        }
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        battery = max > 0 ? current * 100 / max : nil
        charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
    }

    func updateLayout() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return }
        let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        layout = (langs.first ?? "en").prefix(2).uppercased()
    }

    // CoreAudio: default output device volume + mute, refreshed by property listeners.
    private func outputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    func updateVolume() {
        guard let device = outputDevice() else { return }
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
            volume = Int((vol * 100).rounded())
        }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyMute
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &mute) == noErr {
            muted = mute != 0
        }
    }

    private func watchVolume() {
        let refresh: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { StatusService.shared.updateVolume() }
        }
        var defaultAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { [weak self] _, _ in
            self?.updateVolume()
            self?.watchVolume()
        }
        guard let device = outputDevice() else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &addr, .main, refresh)
        }
    }
}

// MARK: - yabai focus-follows-mouse watchdog

/// yabai turns focus-follows-mouse to an internal "disabled" state while a menu is open and
/// sometimes misses the close (yabai #2217) — e.g. after the tray opens an app's menu — so
/// hover-focus stays dead. If it is still "disabled" on two checks 5 s apart, restore it.
final class FocusWatchdog {
    static let shared = FocusWatchdog()
    private var timer: Timer?
    private var strikes = 0
    private let queue = DispatchQueue(label: "rice.ffm")

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        queue.async {
            let value = String(data: shell(yabaiPath, ["-m", "config", "focus_follows_mouse"]), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value == "disabled" else { self.strikes = 0; return }
            self.strikes += 1
            if self.strikes >= 2 {
                shell(yabaiPath, ["-m", "config", "focus_follows_mouse", "autofocus"])
                self.strikes = 0
            }
        }
    }
}

// MARK: - Desktop switching without the scripting addition

/// Without the scripting addition yabai cannot focus spaces, so space.sh falls back to the
/// macOS "Switch to Desktop N" shortcuts (ctrl + 1…0, enabled by install.sh).
enum SpaceKeys {
    private static let digits: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]  // 0…9

    static func focus(_ n: Int) -> Bool {
        guard (1...10).contains(n) else { return false }
        let key = digits[n % 10]
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
