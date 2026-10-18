// Data for the Performance tab: CPU / GPU usage and temperatures, memory, storage,
// network throughput and battery details. Sampled only while the tab is visible.

import AppKit
import Darwin
import IOKit
import IOKit.ps

// MARK: - IOHID temperature sensors (private, loaded with dlsym)

private enum HID {
    typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(p, to: T.self)
    }

    static let create = sym("IOHIDEventSystemClientCreate", ClientCreate.self)
    static let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self)
    static let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self)
    static let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self)
    static let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self)
    static let floatValue = sym("IOHIDEventGetFloatValue", FloatValue.self)

    static let temperatureType: Int64 = 15  // kIOHIDEventTypeTemperature

    /// Sensor name → °C for every Apple Silicon temperature sensor.
    static func temperatures() -> [String: Double] {
        guard let create, let setMatching, let copyServices, let copyProperty, let copyEvent, let floatValue,
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return [:] }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [:] }
        var out: [String: Double] = [:]
        for s in services {
            guard let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(s, temperatureType, 0, 0)?.takeRetainedValue() else { continue }
            let t = floatValue(event, Int32(temperatureType << 16))
            if t > 0 && t < 150 { out[name] = t }
        }
        return out
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

/// Binary units with Russian suffixes: 0 Б, 512 Б, 8.6 ГБ.
func formatBytes(_ bytes: Double) -> String {
    let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
    var v = max(0, bytes)
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v)) \(units[i])" : String(format: v < 10 ? "%.2f %@" : v < 100 ? "%.1f %@" : "%.0f %@", v, units[i])
}

// MARK: - Service

final class PerfService: ObservableObject {
    static let shared = PerfService()

    let cpuName = sysctlString("machdep.cpu.brand_string") ?? "CPU"
    @Published private(set) var gpuName = "GPU"
    @Published private(set) var gpu: Double = 0
    @Published private(set) var cpuTemp: Double = 0
    @Published private(set) var gpuTemp: Double = 0
    @Published private(set) var memUsed: Double = 0
    @Published private(set) var memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskUsed: Double = 0
    @Published private(set) var diskTotal: Double = 0
    @Published private(set) var down: Double = 0  // bytes/s
    @Published private(set) var up: Double = 0
    @Published private(set) var batteryMinutes: Int?  // to empty, or to full while charging
    @Published private(set) var batteryHealth: String?

    private var timer: Timer?
    private var lastNet: (UInt64, UInt64, Date)?
    private let queue = DispatchQueue(label: "rice.perf")

    private init() {}

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        queue.async {
            let temps = HID.temperatures()
            func avg(_ match: (String) -> Bool) -> Double {
                let v = temps.filter { match($0.key) }.map(\.value)
                return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
            }
            // M1-family PMU sensors: "tdie*" = CPU die, "TP*g" = GPU
            let cpuT = avg { $0.contains("tdie") || $0.hasPrefix("pACC") || $0.hasPrefix("eACC") }
            let gpuT = avg { ($0.contains(" TP") && $0.hasSuffix("g")) || $0.hasPrefix("GPU") }
            let (gpuUse, gpuName) = Self.gpuStats()
            let (used, total) = Self.disk()
            let net = Self.netBytes()
            DispatchQueue.main.async {
                self.cpuTemp = cpuT
                self.gpuTemp = gpuT
                self.gpu = gpuUse
                if let gpuName { self.gpuName = gpuName }
                self.memUsed = ResourcesService.shared.memory * self.memTotal
                self.diskUsed = used
                self.diskTotal = total
                let now = Date()
                if let (rx, tx, at) = self.lastNet {
                    let dt = now.timeIntervalSince(at)
                    if dt > 0 {
                        self.down = Double(net.0 &- rx) / dt
                        self.up = Double(net.1 &- tx) / dt
                    }
                }
                self.lastNet = (net.0, net.1, now)
                self.sampleBattery()
            }
        }
    }

    private static func gpuStats() -> (Double, String?) {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return (0, nil) }
        defer { IOObjectRelease(iter) }
        var usage = 0.0
        var name: String?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            if let stats = dict["PerformanceStatistics"] as? [String: Any],
               let u = stats["Device Utilization %"] as? Int {
                usage = Double(u) / 100
            }
            if let cores = dict["gpu-core-count"] as? Int {
                let chip = (sysctlString("machdep.cpu.brand_string") ?? "Apple").replacingOccurrences(of: "Apple ", with: "")
                name = "\(chip) · \(cores) ядер"
            }
        }
        return (usage, name)
    }

    private static func disk() -> (Double, Double) {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return (0, 0) }
        return (Double(total) - Double(free), Double(total))
    }

    /// Bytes in / out on the primary interface (en0); utun would double-count VPN traffic.
    private static func netBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = ptr.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: a.ifa_name) == "en0",
                  let data = a.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        return (rx, tx)
    }

    private func sampleBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let src = list.first,
              let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { return }
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
        batteryMinutes = minutes > 0 ? minutes : nil
        batteryHealth = d[kIOPSBatteryHealthKey] as? String
    }
}

// MARK: - Lyrics (NetEase + LRCLIB, in Feishin's configured order)

struct LyricLine: Hashable {
    let time: Double
    let text: String
}

final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var status = "Нет текста"
    private var key = ""

    private init() {}

    /// Called with the current track; fetches once per track.
    func update(title: String?, artist: String?, album: String?, duration: Double) {
        let k = "\(title ?? "")|\(artist ?? "")"
        guard k != key else { return }
        key = k
        lines = []
        guard let title, let artist else { status = "Нет текста"; return }
        status = "Ищу текст…"
        Task.detached {
            let result = await Self.fetch(title: title, artist: artist, album: album, duration: duration)
            await MainActor.run {
                guard self.key == k else { return }
                self.lines = result
                self.status = result.isEmpty ? "Текст не найден" : ""
            }
        }
    }

    func index(at position: Double) -> Int? {
        guard lines.first?.time ?? -1 >= 0 else { return nil }  // plain lyrics
        return lines.lastIndex { $0.time <= position + 0.25 }
    }

    /// Same sources and order as Feishin's settings ("lyrics": ["NetEase", "lrclib.net"]).
    private static var sources: [String] {
        let path = expand("~/Library/Application Support/feishin/config.json")
        let config = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return config?["lyrics"] as? [String] ?? ["NetEase", "lrclib.net"]
    }

    private static func fetch(title: String, artist: String, album: String?, duration: Double) async -> [LyricLine] {
        for source in sources {
            let lrc: String?
            switch source.lowercased() {
            case "netease": lrc = await netease(title: title, artist: artist, duration: duration)
            case "lrclib.net", "lrclib": lrc = await lrclib(title: title, artist: artist, album: album, duration: duration)
            default: lrc = nil
            }
            let lines = lrc.map(parse) ?? []
            if !lines.isEmpty { return lines }
        }
        return []
    }

    private static func json(_ url: URL) async -> Any? {
        var req = URLRequest(url: url)
        req.setValue("rice-shell (mac-rice)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func url(_ base: String, _ items: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    /// Words of a title/artist, lowercased, punctuation dropped: "X - Slow & Hard" ≈ "X (SLOW & HARD)".
    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    private static func netease(title: String, artist: String, duration: Double) async -> String? {
        guard let search = await json(url("https://music.163.com/api/search/get",
                                          ["s": "\(artist) \(title)", "type": "1", "limit": "10", "offset": "0"])) as? [String: Any],
              let songs = (search["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return nil }
        // Best match on title, artist and length (Feishin's orderSearchResults does the same idea)
        let scored = songs.compactMap { song -> (Int, Double)? in
            guard let id = song["id"] as? Int, let name = song["name"] as? String else { return nil }
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " ")
            var score = similarity(name, title) * 2 + similarity(artists, artist)
            if duration > 0, let ms = song["duration"] as? Double {
                score -= min(1, abs(ms / 1000 - duration) / 30)
            }
            return (id, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 1.2 else { return nil }
        let lyric = await json(url("https://music.163.com/api/song/lyric",
                                   ["id": String(best.0), "lv": "-1", "kv": "-1", "tv": "-1"])) as? [String: Any]
        return (lyric?["lrc"] as? [String: Any])?["lyric"] as? String
    }

    private static func lrclib(title: String, artist: String, album: String?, duration: Double) async -> String? {
        var items = ["track_name": title, "artist_name": artist]
        if let album { items["album_name"] = album }
        if duration > 0 { items["duration"] = String(Int(duration.rounded())) }
        if let hit = await json(url("https://lrclib.net/api/get", items)) as? [String: Any],
           let lrc = (hit["syncedLyrics"] as? String) ?? (hit["plainLyrics"] as? String) {
            return lrc
        }
        let list = await json(url("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist])) as? [[String: Any]]
        return list?.compactMap { ($0["syncedLyrics"] as? String) ?? ($0["plainLyrics"] as? String) }.first
    }

    /// "[mm:ss.xx] text" lines (NetEase also writes "[00:00.00-1]"). Plain lyrics without
    /// stamps come back with time -1: shown, never highlighted.
    private static func parse(_ lrc: String) -> [LyricLine] {
        let credits = ["作词", "作曲", "编曲", "制作", "混音", "录音", "母带"]
        var synced: [LyricLine] = []
        var plain: [LyricLine] = []
        for raw in lrc.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let stamp = line[line.index(after: line.startIndex)..<close]
                let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let parts = stamp.split(separator: ":")
                guard parts.count == 2, let m = Double(parts[0]),
                      let s = Double(parts[1].prefix { "0123456789.".contains($0) }) else { continue }  // [ar:…] tags
                if credits.contains(where: { text.hasPrefix($0) }) { continue }
                synced.append(LyricLine(time: m * 60 + s, text: text.isEmpty ? "♪" : text))
            } else if !line.isEmpty {
                plain.append(LyricLine(time: -1, text: line))
            }
        }
        return synced.isEmpty ? plain : synced.sorted { $0.time < $1.time }
    }
}
