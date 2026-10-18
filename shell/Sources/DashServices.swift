// Data for the dashboard: now playing (media-control / MediaRemote), weather
// (open-meteo, like caelestia's Weather service), CPU / memory / storage, uptime.

import AppKit
import CoreLocation
import Darwin

// MARK: - Media

final class MediaService: ObservableObject {
    static let shared = MediaService()

    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var album: String?
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var appBundle: String?
    @Published private(set) var shuffle = false
    @Published private(set) var repeatOn = false
    private var elapsed: Double = 0
    private var elapsedAt = Date()

    private let tool = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]

    private init() { start() }

    var hasMedia: Bool { title != nil }

    /// launchd stops rice-shell with SIGTERM; take the media-control stream down with it,
    /// otherwise every restart leaves an orphaned perl adapter behind.
    func shutdown() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func position(at date: Date = Date()) -> Double {
        let p = elapsed + (playing ? date.timeIntervalSince(elapsedAt) : 0)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }

    func progress(at date: Date = Date()) -> Double { duration > 0 ? position(at: date) / duration : 0 }

    func send(_ command: String, _ args: String...) {
        guard let tool else { return }
        DispatchQueue.global().async { shell(tool, [command] + args) }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let target = fraction * duration
        elapsed = target
        elapsedAt = Date()
        send("seek", String(format: "%.2f", target))
    }

    private func start() {
        guard let tool else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = ["stream"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }  // restart if it dies
        }
        do { try task.run() } catch { return }
        process = task
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["type"] as? String == "data",
                  let payload = json["payload"] as? [String: Any] else { continue }
            if json["diff"] as? Bool == true {
                state.merge(payload) { _, new in new }
            } else {
                state = payload
            }
            apply()
        }
    }

    private func apply() {
        func str(_ k: String) -> String? { (state[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        title = str("title")
        artist = str("artist")
        album = str("album")
        appBundle = str("bundleIdentifier")
        playing = state["playing"] as? Bool ?? false
        duration = state["duration"] as? Double ?? 0
        elapsed = state["elapsedTime"] as? Double ?? 0
        if let ts = state["timestamp"] as? String,
           let date = ISO8601DateFormatter.withFractions.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) {
            elapsedAt = date
        } else {
            elapsedAt = Date()
        }
        shuffle = (state["shuffleMode"] as? Int ?? 1) > 1
        repeatOn = (state["repeatMode"] as? Int ?? 1) > 1
        LyricsService.shared.update(title: title, artist: artist, album: album, duration: duration)
        if let b64 = state["artworkData"] as? String, let data = Data(base64Encoded: b64) {
            artwork = NSImage(data: data)
        } else if state.isEmpty {
            artwork = nil
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Weather

/// Location: ~/.config/mac-rice/shell.json {"weather": {"location": "Москва"}} or by IP.
/// A VPN skews the IP lookup, hence the override (caelestia uses no_proxy for the same reason).
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var temp: String = "—"
    @Published private(set) var icon = "cloud_alert"
    @Published private(set) var description = "Загрузка погоды"
    @Published private(set) var city = ""
    @Published private(set) var feelsLike = "—"
    @Published private(set) var humidity = "—"
    @Published private(set) var wind = "—"
    @Published private(set) var sunrise = "—"
    @Published private(set) var sunset = "—"
    @Published private(set) var forecast: [DayForecast] = []
    private var lastFetch: Date?
    private var cachedLocation: (Double, Double, String)?

    private init() {}

    func reload(force: Bool = false) {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 15 * 60 { return }
        lastFetch = Date()
        Task.detached { await self.fetch() }
    }

    private func getJSON(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func location() async -> (Double, Double, String)? {
        let loc = await resolveLocation()
        if let loc { cachedLocation = loc }
        return loc
    }

    /// Order: shell.json "location" → CoreLocation (Wi-Fi, unaffected by VPN) → IP.
    private func resolveLocation() async -> (Double, Double, String)? {
        let config = (try? Data(contentsOf: URL(fileURLWithPath: expand("~/.config/mac-rice/shell.json"))))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let name = (config?["weather"] as? [String: Any])?["location"] as? String, !name.isEmpty {
            // "lat,lon" or a city name, like caelestia's services.weatherLocation
            let parts = name.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let lat = parts[0], let lon = parts[1] {
                return (lat, lon, await LocationService.shared.cityName(lat: lat, lon: lon) ?? "")
            }
            if let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let geo = await getJSON("https://geocoding-api.open-meteo.com/v1/search?count=1&language=ru&name=\(q)"),
               let first = (geo["results"] as? [[String: Any]])?.first,
               let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double {
                return (lat, lon, first["name"] as? String ?? name)
            }
        }
        if let loc = await LocationService.shared.current() {
            let (lat, lon) = (loc.coordinate.latitude, loc.coordinate.longitude)
            return (lat, lon, await LocationService.shared.cityName(lat: lat, lon: lon) ?? "")
        }
        if let ip = await getJSON("https://ipwho.is/?lang=ru&fields=latitude,longitude,city"),
           let lat = ip["latitude"] as? Double, let lon = ip["longitude"] as? Double {
            return (lat, lon, ip["city"] as? String ?? "")
        }
        return nil
    }

    private func fetch() async {
        // previous-runs-api answers /v1/forecast identically from another IP (the main one is
        // blocked in Russia without VPN) — same fallback as the Arch Weather.qml patch.
        let query = "/v1/forecast?timezone=auto&forecast_days=7&wind_speed_unit=ms"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"
        var json: [String: Any]?
        if let (lat, lon, _) = await location() {
            for host in ["api.open-meteo.com", "previous-runs-api.open-meteo.com"] where json?["current"] == nil {
                json = await getJSON("https://\(host)\(query)&latitude=\(lat)&longitude=\(lon)")
            }
        }
        let current = json?["current"] as? [String: Any]
        let city = cachedLocation?.2 ?? ""
        guard let current else {
            await MainActor.run { self.description = "Нет данных"; self.lastFetch = nil }
            return
        }
        let t = current["temperature_2m"] as? Double ?? 0
        let code = current["weather_code"] as? Int ?? 0
        let day = (current["is_day"] as? Int ?? 1) == 1
        let (icon, desc) = Self.describe(code, day: day)
        let daily = json?["daily"] as? [String: Any] ?? [:]
        let dates = daily["time"] as? [String] ?? []
        let codes = daily["weather_code"] as? [Int] ?? []
        let maxs = daily["temperature_2m_max"] as? [Double] ?? []
        let mins = daily["temperature_2m_min"] as? [Double] ?? []
        let days: [DayForecast] = dates.indices.compactMap { i in
            guard i < codes.count, i < maxs.count, i < mins.count,
                  let date = DayForecast.parser.date(from: dates[i]) else { return nil }
            return DayForecast(date: date, icon: Self.describe(codes[i], day: true).0,
                               max: Int(maxs[i].rounded()), min: Int(mins[i].rounded()))
        }
        let clocks = ["sunrise", "sunset"].map { key -> String in
            guard let iso = (daily[key] as? [String])?.first, let t = iso.split(separator: "T").last else { return "—" }
            return String(t)
        }
        await MainActor.run {
            self.temp = "\(Int(t.rounded()))°C"
            self.icon = icon
            self.description = desc
            self.city = city
            self.feelsLike = "\(Int((current["apparent_temperature"] as? Double ?? t).rounded()))°C"
            self.humidity = "\(current["relative_humidity_2m"] as? Int ?? 0)%"
            self.wind = String(format: "%.1f м/с", current["wind_speed_10m"] as? Double ?? 0)
            self.sunrise = clocks[0]
            self.sunset = clocks[1]
            self.forecast = days
        }
    }

    /// WMO weather codes → Material Symbols + Russian description.
    static func describe(_ code: Int, day: Bool) -> (String, String) {
        switch code {
        case 0: return (day ? "clear_day" : "clear_night", "Ясно")
        case 1: return (day ? "partly_cloudy_day" : "partly_cloudy_night", "Преимущественно ясно")
        case 2: return (day ? "partly_cloudy_day" : "partly_cloudy_night", "Переменная облачность")
        case 3: return ("cloud", "Пасмурно")
        case 45, 48: return ("foggy", "Туман")
        case 51, 53, 55: return ("rainy_light", "Морось")
        case 56, 57: return ("weather_mix", "Ледяная морось")
        case 61, 63: return ("rainy", "Дождь")
        case 65: return ("rainy_heavy", "Сильный дождь")
        case 66, 67: return ("weather_mix", "Ледяной дождь")
        case 71, 73: return ("weather_snowy", "Снег")
        case 75, 77: return ("snowing_heavy", "Сильный снег")
        case 80, 81, 82: return ("rainy", "Ливень")
        case 85, 86: return ("weather_snowy", "Снегопад")
        case 95, 96, 99: return ("thunderstorm", "Гроза")
        default: return ("cloud", "—")
        }
    }
}

struct DayForecast: Hashable {
    let date: Date
    let icon: String
    let max: Int
    let min: Int

    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Resources

final class ResourcesService: ObservableObject {
    static let shared = ResourcesService()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0
    @Published private(set) var storage: Double = 0
    private var lastTicks: [UInt32]?
    private var timer: Timer?

    private init() {}

    /// Sample only while something is showing the numbers.
    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        // CPU: delta of user+system+nice over total ticks
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let t = load.cpu_ticks
            let ticks = [t.0, t.1, t.2, t.3]  // user, system, idle, nice
            if let last = lastTicks {
                let d = zip(ticks, last).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                if total > 0 { cpu = (d[0] + d[1] + d[3]) / total }
            }
            lastTicks = ticks
        }

        // Memory: (active + wired + compressed) / physical, like Activity Monitor's "used"
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmOk = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmOk == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = Double(UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
            memory = used / Double(ProcessInfo.processInfo.physicalMemory)
        }

        // Storage of the system volume
        if let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = values.volumeTotalCapacity, total > 0,
           let free = values.volumeAvailableCapacityForImportantUsage {
            storage = 1 - Double(free) / Double(total)
        }
    }
}

// MARK: - Uptime

func uptimeString() -> String {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    var mib = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "" }
    let seconds = Int(Date().timeIntervalSince1970) - boot.tv_sec
    let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
    if days > 0 { return "\(days) д \(hours) ч" }
    if hours > 0 { return "\(hours) ч \(minutes) мин" }
    return "\(minutes) мин"
}

// MARK: - Location

/// One-shot CoreLocation fix (Wi-Fi based, so a VPN does not move it).
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var last: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var status: Int32 { manager.authorizationStatus.rawValue }
    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func current() async -> CLLocation? {
        if let last, Date().timeIntervalSince(last.timestamp) < 3600 { return last }
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                self.waiters.append(cont)
                guard self.waiters.count == 1 else { return }
                switch self.manager.authorizationStatus {
                case .notDetermined: self.manager.requestWhenInUseAuthorization()
                case .denied, .restricted: self.finish(nil)
                default: self.manager.requestLocation()
                }
                // Never hang the weather on a missing answer
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.finish(nil) }
            }
        }
    }

    func cityName(lat: Double, lon: Double) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: lat, longitude: lon), preferredLocale: Locale(identifier: "ru_RU"))
        return placemarks?.first?.locality
    }

    private func finish(_ location: CLLocation?) {
        if let location { last = location }
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: location ?? last) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !waiters.isEmpty else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
