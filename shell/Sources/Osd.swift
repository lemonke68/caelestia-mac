// OSD on the right edge, after caelestia modules/osd: vertical sliders for volume and
// brightness (sizes.osd 30 × 150), shown on change, hidden after osd.hideDelay 2 s.
//
// To replace the system HUD the volume / brightness / mute keys are taken over with an
// event tap (needs Accessibility) and applied here: CoreAudio for volume, the private
// DisplayServices framework for the built-in display's brightness. Without the
// permission the keys stay with macOS and the OSD still follows volume changes.

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import SwiftUI

// MARK: - Brightness (DisplayServices, private)

enum Brightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: Get? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setFn: Set? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    private static var display: UInt32 {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var value: Float? {
        var v: Float = 0
        guard let getFn, getFn(display, &v) == 0 else { return nil }
        return v
    }

    static func set(_ v: Float) {
        _ = setFn?(display, min(1, max(0, v)))
    }
}

// MARK: - Volume (CoreAudio)

enum Volume {
    static var device: AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    static func set(_ v: Float) {
        guard let device else { return }
        var value = min(1, max(0, v))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        if value > 0 { setMuted(false) }
    }

    static func setMuted(_ muted: Bool) {
        guard let device else { return }
        var m: UInt32 = muted ? 1 : 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}

// MARK: - Media keys

/// Event tap on NX_SYSDEFINED aux keys. Returns false when Accessibility is missing.
final class MediaKeys {
    enum Key: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    static let shared = MediaKeys()
    var handler: ((Key, Bool) -> Void)?  // (key, fine step)
    private var tap: CFMachPort?

    /// Idempotent: the OSD is rebuilt on every screen change, and the setup window retries
    /// once Accessibility has been granted.
    func start() -> Bool {
        if tap != nil { return true }
        let callback: CGEventTapCallBack = { _, type, cgEvent, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MediaKeys.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(cgEvent)
            }
            guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(cgEvent)
            }
            let code = (event.data1 & 0xFFFF0000) >> 16
            let down = ((event.data1 & 0xFF00) >> 8) == 0xA
            guard let key = Key(rawValue: code) else { return Unmanaged.passUnretained(cgEvent) }
            if down {
                let fine = event.modifierFlags.contains([.option, .shift])
                DispatchQueue.main.async { MediaKeys.shared.handler?(key, fine) }
            }
            return nil  // swallowed: no system HUD
        }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

// MARK: - OSD

final class OsdModel: ObservableObject {
    @Published var brightness: Double = Double(Brightness.value ?? 0.5)
}

struct OsdView: View {
    @ObservedObject var model: OsdModel
    @ObservedObject var status = StatusService.shared
    @ObservedObject var theme = Theme.shared

    static let sliderW: CGFloat = 30
    static let sliderH: CGFloat = 150
    static let padding: CGFloat = T.l
    static let offset: CGFloat = max(0, min(T.l - T.thickness, T.l)) / 2
    static var depth: CGFloat { sliderW + padding + offset * 2 + T.s }
    static var along: CGFloat { sliderH * 2 + T.m + padding * 2 }

    private var volumeIcon: String {
        if status.muted || status.volume == 0 { return "volume_off" }
        return status.volume >= 66 ? "volume_up" : status.volume >= 33 ? "volume_down" : "volume_mute"
    }

    var body: some View {
        VStack(spacing: T.m) {
            FilledSlider(value: status.muted ? 0 : Double(status.volume) / 100, icon: volumeIcon) {
                Volume.set(Float($0))
            }
            FilledSlider(value: model.brightness,
                         icon: "brightness_\(min(7, Int((model.brightness * 6).rounded()) + 1))") {
                model.brightness = $0
                Brightness.set(Float($0))
            }
        }
        .padding(.vertical, Self.padding)
        .offset(x: -Self.offset)
    }
}

/// caelestia FilledSlider: a capsule filled from the bottom, icon riding at the bottom.
struct FilledSlider: View {
    @ObservedObject var theme = Theme.shared
    let value: Double
    let icon: String
    let onMove: (Double) -> Void

    var body: some View {
        let w = OsdView.sliderW, h = OsdView.sliderH
        ZStack(alignment: .bottom) {
            Capsule().fill(theme["surfaceContainer"])
            Capsule().fill(theme["primary"])
                .frame(height: max(w, h * value))
            MIcon(name: icon, size: 18, color: value * h > w * 0.8 ? theme["onPrimary"] : theme["onSurface"])
                .frame(height: w)
        }
        .frame(width: w, height: h)
        .clipShape(Capsule())
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: value)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            onMove(min(1, max(0, 1 - g.location.y / h)))
        })
    }
}

final class OsdController {
    let model = OsdModel()
    let panel: Panel<OsdView>
    private var hideWork: DispatchWorkItem?
    private var lastVolume: (Int, Bool)?
    private var sub: Any?
    let keysTaken: Bool

    init(screen: NSScreen) {
        let innerTop = screen.frame.maxY - T.top
        let innerBottom = screen.frame.minY + T.thickness
        panel = Panel(edge: .right, along: OsdView.along, depth: OsdView.depth,
                      center: (innerTop + innerBottom) / 2, screen: screen, content: OsdView(model: model))

        // Ask for Accessibility once; the tap only works after it is granted (restart rice-shell then)
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        keysTaken = MediaKeys.shared.start()
        FileHandle.standardError.write("media keys: \(keysTaken ? "taken over (system HUD hidden)" : "not taken, Accessibility missing")\n".data(using: .utf8)!)
        MediaKeys.shared.handler = { [weak self] key, fine in self?.handle(key, fine: fine) }

        // Volume changed elsewhere (menu bar, another app): show it too
        let status = StatusService.shared
        sub = status.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = (status.volume, status.muted)
                if let last = self.lastVolume, last != now { self.show() }
                self.lastVolume = now
            }
        }
    }

    private func handle(_ key: MediaKeys.Key, fine: Bool) {
        let step: Float = fine ? 1 / 64 : 1 / 16
        let status = StatusService.shared
        switch key {
        case .soundUp: Volume.set(Float(status.volume) / 100 + step)
        case .soundDown: Volume.set(Float(status.volume) / 100 - step)
        case .mute: Volume.setMuted(!status.muted)
        case .brightnessUp, .brightnessDown:
            let current = Float(Brightness.value ?? Float(model.brightness))
            let next = min(1, max(0, current + (key == .brightnessUp ? step : -step)))
            Brightness.set(next)
            model.brightness = Double(next)
            show()
        }
    }

    func show() {
        if let b = Brightness.value { model.brightness = Double(b) }
        panel.open(activate: false)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Keep it while the pointer is on it (dragging a slider)
            if self.panel.frame.contains(NSEvent.mouseLocation) { self.show(); return }
            self.panel.close()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
