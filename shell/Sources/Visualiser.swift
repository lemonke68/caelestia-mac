// Audio visualiser around the Media tab cover, after caelestia media/CoverVisualiser.qml
// (cava, services.visualiserBars 60). System output is captured with a Core Audio process
// tap (macOS 14.2+, asks for "System Audio Recording" once), turned into 60 log-spaced
// bands with an FFT, then smoothed cava-style (fast rise, gravity fall, auto gain).
// It only runs while the Media tab is on screen.

import Accelerate
import AudioToolbox
import CoreAudio
import SwiftUI

final class AudioViz: ObservableObject {
    static let shared = AudioViz()
    static let bands = 60

    @Published private(set) var bars = [Float](repeating: 0, count: AudioViz.bands)

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var users = 0
    private let queue = DispatchQueue(label: "rice.viz", qos: .userInteractive)

    // FFT state (touched only on `queue`)
    private let n = 2048
    private lazy var log2n = vDSP_Length(log2(Double(n)))
    private lazy var fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    private lazy var window: [Float] = {
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var ring = [Float]()
    private var sampleRate: Double = 48000
    private var smooth = [Float](repeating: 0, count: AudioViz.bands)
    private var fall = [Float](repeating: 0, count: AudioViz.bands)
    private var peak: Float = 1e-3
    private var lastPublish = Date.distantPast

    func acquire() {
        users += 1
        if users == 1 { queue.async { self.start() } }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 {
            queue.async { self.stop() }
            bars = [Float](repeating: 0, count: Self.bands)
        }
    }

    // MARK: Capture

    private func defaultOutputUID() -> String? {
        guard let device = Volume.device else { return nil }
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }

    private func start() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, let output = defaultOutputUID() else {
            FileHandle.standardError.write("visualiser: no audio tap (permission?)\n".data(using: .utf8)!)
            return
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "rice-shell visualiser",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else {
            stop()
            return
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else { stop(); return }
        AudioDeviceStart(aggregate, proc)
    }

    private func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        ring.removeAll()
    }

    // MARK: Analysis

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        for f in 0..<frames {
            var s: Float = 0
            for c in 0..<channels { s += samples[f * channels + c] }
            ring.append(s / Float(channels))
        }
        if ring.count > n { ring.removeFirst(ring.count - n) }
        guard ring.count == n, Date().timeIntervalSince(lastPublish) > 1.0 / 40 else { return }
        lastPublish = Date()
        analyse()
    }

    private func analyse() {
        guard let fft else { return }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        // 60 log-spaced bands, 50 Hz – 12 kHz (cava's default range)
        let bands = Self.bands
        let binHz = sampleRate / Double(n)
        let lo = log10(50.0), hi = log10(12000.0)
        var values = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let f0 = pow(10, lo + (hi - lo) * Double(b) / Double(bands))
            let f1 = pow(10, lo + (hi - lo) * Double(b + 1) / Double(bands))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, min(n / 2, Int(f1 / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            // Gentle tilt so highs are not drowned by bass, like cava's EQ
            values[b] = sqrt(sum / Float(i1 - i0)) * (1 + Float(b) / Float(bands))
        }

        // Auto gain: follow the loudest band, decay slowly
        peak = max(values.max() ?? 0, peak * 0.995, 1e-3)
        for b in 0..<bands {
            let v = min(1, values[b] / peak)
            if v > smooth[b] {
                smooth[b] = smooth[b] * 0.3 + v * 0.7
                fall[b] = 0
            } else {
                fall[b] += 0.004  // gravity
                smooth[b] = max(v, smooth[b] - fall[b])
            }
        }
        // monstercat-style neighbour smoothing
        var out = smooth
        for b in 0..<bands {
            for d in 1...3 {
                let k = Float(pow(1.5, Double(d)))
                if b - d >= 0 { out[b] = max(out[b], smooth[b - d] / k) }
                if b + d < bands { out[b] = max(out[b], smooth[b + d] / k) }
            }
        }
        DispatchQueue.main.async { self.bars = out }
    }
}

/// Bars around the cover: start just outside the cookie shape, grow outward.
struct VisualiserRing: View {
    @ObservedObject var viz = AudioViz.shared
    @ObservedObject var theme = Theme.shared
    let coverSize: CGFloat
    let size: CGFloat

    var body: some View {
        Canvas { ctx, canvas in
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let spacing = T.m
            let start = coverSize / 2 + spacing
            let maxLen = (size - coverSize) / 2 - spacing - 2
            let count = viz.bars.count
            let width = 360 / CGFloat(count) - T.s / 4
            for (i, v) in viz.bars.enumerated() {
                let a = (CGFloat(i) * 360 / CGFloat(count) + 90) * .pi / 180
                let len = max(1.5, CGFloat(v) * maxLen)
                var path = Path()
                path.move(to: CGPoint(x: c.x + start * cos(a), y: c.y + start * sin(a)))
                path.addLine(to: CGPoint(x: c.x + (start + len) * cos(a), y: c.y + (start + len) * sin(a)))
                ctx.stroke(path, with: .color(theme["primary"]),
                           style: StrokeStyle(lineWidth: min(4, width), lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .onAppear { viz.acquire() }
        .onDisappear { viz.release() }
    }
}
