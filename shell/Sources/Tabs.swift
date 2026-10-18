// Dashboard tabs Media, Performance and Weather, after caelestia modules/dashboard
// (Media.qml + media/, Performance.qml + performance/, WeatherTab.qml), fitted into
// the Dashboard tab's 839 × 372 so the panel never has to resize.

import AppKit
import SwiftUI

private let gridW = DashSize.gridW
private let gridH = DashSize.gridH

func mmss(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Media

struct MediaTab: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var media = MediaService.shared

    var body: some View {
        if media.hasMedia {
            HStack(spacing: T.xl) {
                MediaCover()
                MediaDetails().frame(maxWidth: .infinity)
                LyricsView().frame(width: 280)
            }
            .padding(T.l)
            .frame(width: gridW, height: gridH)
        } else {
            VStack(spacing: T.s) {
                ZStack {
                    WavyShape(lobes: 2, amplitude: 0.12).fill(theme["primaryContainer"])
                    MIcon(name: "queue_music", size: 48, color: theme["onPrimaryContainer"])
                }
                .frame(width: 104, height: 104)
                Text("Ничего не играет").font(.body(24)).foregroundStyle(theme["onSurface"])
                Text("Включи что-нибудь, и оно появится здесь").font(.body(T.fontLarger))
                    .foregroundStyle(theme["onSurfaceVariant"])
            }
            .frame(width: gridW, height: gridH)
        }
    }
}

/// Cookie-shaped cover with the visualiser ring around it (CoverVisualiser.qml).
struct MediaCover: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var media = MediaService.shared
    @State private var spin = 0.0

    var body: some View {
        let size: CGFloat = 200
        let shape = WavyShape(lobes: 9, amplitude: 0.05)  // MaterialShape.Cookie9Sided
        ZStack {
            shape.fill(theme["surfaceContainerHigh"])
            if let art = media.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                MIcon(name: "art_track", size: 64, color: theme["onSurfaceVariant"])
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .rotationEffect(.degrees(spin))
        .onAppear {
            withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) { spin = 360 }
        }
        .background(VisualiserRing(coverSize: size * 1.05, size: 280))
        .frame(width: 280)
    }
}

struct MediaDetails: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var media = MediaService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: T.xs) {
            Text(media.title ?? "").font(.body(22, .medium)).foregroundStyle(theme["onSurface"])
            Text(media.artist ?? "Неизвестный исполнитель").font(.body(16)).foregroundStyle(theme["onSurfaceVariant"])
            Text(media.album ?? "Неизвестный альбом").font(.body(16)).foregroundStyle(theme["secondary"])

            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                HStack(spacing: T.s) {
                    Text(mmss(media.position(at: ctx.date))).font(.body(T.fontSmaller)).monospacedDigit()
                        .foregroundStyle(theme["onSurfaceVariant"]).frame(width: 40, alignment: .leading)
                    SeekBar(value: media.progress(at: ctx.date)) { media.seek(to: $0) }
                    Text(media.duration > 0 ? mmss(media.duration) : "--:--").font(.body(T.fontSmaller)).monospacedDigit()
                        .foregroundStyle(theme["onSurfaceVariant"]).frame(width: 40, alignment: .trailing)
                }
            }
            .padding(.top, T.xl + 4)

            HStack(spacing: T.xs) {
                Spacer()
                MediaButton(icon: "shuffle") { media.send("toggle-shuffle") }
                MediaButton(icon: "skip_previous") { media.send("previous-track") }
                MediaButton(icon: media.playing ? "pause" : "play_arrow", primary: true) { media.send("toggle-play-pause") }
                MediaButton(icon: "skip_next") { media.send("next-track") }
                MediaButton(icon: "repeat") { media.send("toggle-repeat") }
                Spacer()
            }
            .padding(.top, 20)
        }
        .lineLimit(1)
    }
}

/// Track + fill + knob; drag or click to seek.
struct SeekBar: View {
    @ObservedObject var theme = Theme.shared
    let value: Double
    let onSeek: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        GeometryReader { geo in
            let v = drag ?? value
            ZStack(alignment: .leading) {
                Capsule().fill(theme["secondaryContainer"]).frame(height: 6)
                Capsule().fill(theme["primary"]).frame(width: max(6, geo.size.width * v), height: 6)
                Capsule().fill(theme["primary"]).frame(width: 4, height: 18)
                    .offset(x: max(0, geo.size.width * v - 2))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag = min(1, max(0, $0.location.x / geo.size.width)) }
                .onEnded { _ in if let d = drag { onSeek(d) }; drag = nil })
        }
        .frame(height: 20)
    }
}

struct LyricsView: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var lyrics = LyricsService.shared
    @ObservedObject var media = MediaService.shared

    var body: some View {
        if lyrics.lines.isEmpty {
            VStack(spacing: T.s) {
                MIcon(name: "lyrics", size: 32, color: theme["outline"])
                Text(lyrics.status).font(.body(T.fontNormal)).foregroundStyle(theme["outline"])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: T.xl, style: .continuous).fill(theme["surfaceContainer"]))
        } else {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let current = lyrics.index(at: media.position(at: ctx.date))
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: T.s) {
                            Color.clear.frame(height: gridH / 2 - 30)
                            ForEach(lyrics.lines.indices, id: \.self) { i in
                                Text(lyrics.lines[i].text)
                                    .font(.body(i == current ? 17 : 14, i == current ? .semibold : .regular))
                                    .foregroundStyle(i == current ? theme["primary"] : theme["onSurfaceVariant"])
                                    .opacity(i == current ? 1 : 0.55)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(i)
                                    .onTapGesture {
                                        if media.duration > 0 { media.seek(to: lyrics.lines[i].time / media.duration) }
                                    }
                            }
                            Color.clear.frame(height: gridH / 2)
                        }
                        .padding(.horizontal, T.m)
                    }
                    .onChange(of: current) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(new, anchor: .center) }
                    }
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                }
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

// MARK: - Performance

struct PerformanceTab: View {
    @ObservedObject var perf = PerfService.shared
    @ObservedObject var res = ResourcesService.shared
    @ObservedObject var theme = Theme.shared
    let gap = DashSize.gap

    var body: some View {
        let colW: CGFloat = 300
        let heroH = (gridH - gap) / 2
        let smallH = (gridH - 2 * gap) / 3
        HStack(spacing: gap) {
            VStack(spacing: gap) {
                HeroCard(icon: "memory", label: "CPU", sub: perf.cpuName, usage: res.cpu,
                         temp: perf.cpuTemp, accent: theme["primary"])
                    .frame(height: heroH)
                HeroCard(icon: "desktop_windows", label: "GPU", sub: perf.gpuName, usage: perf.gpu,
                         temp: perf.gpuTemp, accent: theme["secondary"])
                    .frame(height: heroH)
            }
            .frame(width: colW)
            VStack(spacing: gap) {
                UsageCard(icon: "hard_drive", title: "Диск", used: perf.diskUsed, total: perf.diskTotal,
                          accent: theme["secondary"], radius: 48)
                    .frame(height: smallH)
                NetworkCard().frame(height: smallH)
                UsageCard(icon: "memory_alt", title: "Память", used: perf.memUsed, total: perf.memTotal,
                          accent: theme["tertiary"], radius: T.m)
                    .frame(height: smallH)
            }
            .frame(width: colW)
            BatteryTank().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: gridW, height: gridH)
    }
}

struct HeroCard: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let label: String
    let sub: String
    let usage: Double
    let temp: Double
    let accent: Color

    var body: some View {
        HStack(spacing: T.l) {
            VStack(alignment: .leading, spacing: T.xs) {
                HStack(spacing: T.s) {
                    MIcon(name: icon, size: 22, color: accent)
                    Text(label).font(.body(16, .medium)).foregroundStyle(accent)
                }
                Text(sub).font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"]).lineLimit(1)
                Spacer()
                HStack(spacing: T.xs) {
                    MIcon(name: temp > 90 ? "thermometer_alert" : "thermometer", size: 18,
                          color: temp > 90 ? theme["error"] : accent)
                    Text(temp > 0 ? "\(Int(temp.rounded()))°C" : "—").font(.body(T.fontNormal)).foregroundStyle(theme["onSurface"])
                }
                ProgressLine(value: temp / 100, color: temp > 90 ? theme["error"] : accent)
            }
            ZStack {
                WavyShape(lobes: 8, amplitude: 0.06).fill(accent.opacity(0.18))
                WavyShape(lobes: 8, amplitude: 0.06)
                    .trim(from: 0, to: max(0.001, usage))
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(0))
                VStack(spacing: 0) {
                    Text("\(Int((usage * 100).rounded()))%").font(.body(22, .semibold)).foregroundStyle(accent)
                    Text("загрузка").font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
                }
            }
            .frame(width: 100, height: 100)
            .animation(.easeOut(duration: 0.4), value: usage)
        }
        .padding(T.l)
        .background(RoundedRectangle(cornerRadius: T.xl, style: .continuous).fill(theme["surfaceContainer"]))
    }
}

struct ProgressLine: View {
    @ObservedObject var theme = Theme.shared
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme["secondaryContainer"])
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct UsageCard: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let title: String
    let used: Double
    let total: Double
    let accent: Color
    let radius: CGFloat

    var body: some View {
        let frac = total > 0 ? used / total : 0
        HStack(spacing: T.m) {
            ZStack {
                Circle().stroke(theme["secondaryContainer"], lineWidth: 6)
                Circle().trim(from: 0, to: max(0.001, frac))
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                MIcon(name: icon, size: 20, color: accent)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body(T.fontLarger, .medium)).foregroundStyle(theme["onSurface"])
                Text("\(Int((frac * 100).rounded()))% занято").font(.body(T.fontSmall)).foregroundStyle(accent)
                Text(total > 0 ? "\(formatBytes(used)) / \(formatBytes(total))" : "—")
                    .font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.l)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: min(radius, 40), style: .continuous).fill(theme["surfaceContainer"]))
        .animation(.easeOut(duration: 0.4), value: frac)
    }
}

struct NetworkCard: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var perf = PerfService.shared

    var body: some View {
        HStack(spacing: T.m) {
            MIcon(name: "swap_vert", size: 26, color: theme["primary"])
            VStack(alignment: .leading, spacing: 4) {
                Text("Сеть").font(.body(T.fontLarger, .medium)).foregroundStyle(theme["onSurface"])
                HStack(spacing: T.xs) {
                    MIcon(name: "download", size: 16, color: theme["tertiary"])
                    Text("\(formatBytes(perf.down))/с").font(.body(T.fontSmaller, .medium)).foregroundStyle(theme["tertiary"])
                }
                HStack(spacing: T.xs) {
                    MIcon(name: "upload", size: 16, color: theme["secondary"])
                    Text("\(formatBytes(perf.up))/с").font(.body(T.fontSmaller, .medium)).foregroundStyle(theme["secondary"])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.l)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: T.xl, style: .continuous).fill(theme["surfaceContainer"]))
    }
}

struct BatteryTank: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var status = StatusService.shared
    @ObservedObject var perf = PerfService.shared

    private var statusText: String {
        let state = status.charging ? "Заряжается" : "Разряжается"
        guard let m = perf.batteryMinutes else { return state }
        return "\(state) · \(m / 60) ч \(m % 60) мин"
    }

    var body: some View {
        let level = Double(status.battery ?? 0) / 100
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: T.l, style: .continuous).fill(theme["secondaryContainer"])
                RoundedRectangle(cornerRadius: T.l, style: .continuous).fill(theme["secondary"])
                    .frame(height: max(T.l * 2, geo.size.height * level))
                    .animation(.easeOut(duration: 0.6), value: level)
                VStack(alignment: .leading, spacing: T.xs) {
                    MIcon(name: "battery_full", size: 24, color: theme["onSecondaryContainer"])
                    Text("Батарея").font(.body(T.fontNormal, .medium)).foregroundStyle(theme["onSecondaryContainer"])
                    Text(statusText).font(.body(T.fontSmall)).foregroundStyle(theme["onSecondaryContainer"].opacity(0.8))
                    if let health = perf.batteryHealth {
                        Text("Состояние: \(health == "Good" ? "хорошее" : health)").font(.body(T.fontSmall))
                            .foregroundStyle(theme["onSecondaryContainer"].opacity(0.8))
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        if status.charging { MIcon(name: "bolt", size: 26, color: theme["onSecondary"]) }
                        Text("\(status.battery ?? 0)%").font(.body(30, .semibold)).foregroundStyle(theme["onSecondary"])
                    }
                }
                .padding(T.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: T.l, style: .continuous))
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            // Battery nub
            RoundedRectangle(cornerRadius: T.xs).fill(theme["secondary"]).frame(width: 46, height: 8)
        }
    }
}

// MARK: - Weather

struct WeatherTab: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var w = WeatherService.shared

    private var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date()).capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.m) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(w.city.isEmpty ? "Загрузка…" : w.city).font(.body(26, .semibold)).foregroundStyle(theme["onSurface"])
                    Text(today).font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
                }
                Spacer()
                SunInfo(icon: "wb_twilight", label: "Восход", value: w.sunrise)
                SunInfo(icon: "bedtime", label: "Закат", value: w.sunset).padding(.leading, 20)
            }
            .padding(.horizontal, T.l)

            HStack(spacing: T.m) {
                HStack(spacing: 20) {
                    MIcon(name: w.icon, size: 28 * 2.2, color: theme["secondary"])
                    VStack(alignment: .leading, spacing: -4) {
                        Text(w.temp).font(.body(46, .medium)).foregroundStyle(theme["primary"])
                        Text(w.description).font(.body(T.fontNormal)).foregroundStyle(theme["onSurfaceVariant"])
                    }
                }
                .padding(.horizontal, T.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: T.xl * 2, style: .continuous).fill(theme["surfaceContainer"]))
                WeatherStat(icon: "water_drop", label: "Влажность", value: w.humidity)
                WeatherStat(icon: "thermostat", label: "Ощущается", value: w.feelsLike)
                WeatherStat(icon: "air", label: "Ветер", value: w.wind)
            }
            .frame(height: 100)

            Text("Прогноз на 7 дней").font(.body(T.fontNormal, .semibold)).foregroundStyle(theme["onSurface"])
                .padding(.leading, T.m)

            HStack(spacing: T.m) {
                ForEach(Array(w.forecast.prefix(7).enumerated()), id: \.offset) { i, day in
                    ForecastDay(day: day, first: i == 0)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: gridW, height: gridH)
    }
}

struct SunInfo: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: T.s) {
            MIcon(name: icon, size: 24, color: theme["primary"])
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
                Text(value).font(.body(T.fontNormal, .semibold)).foregroundStyle(theme["onSurface"])
            }
        }
    }
}

struct WeatherStat: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: T.xs) {
            MIcon(name: icon, size: 22, color: theme["primary"])
            Text(value).font(.body(T.fontLarger, .semibold)).foregroundStyle(theme["onSurface"])
            Text(label).font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
        }
        .frame(width: 112)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: T.l, style: .continuous).fill(theme["surfaceContainer"]))
    }
}

struct ForecastDay: View {
    @ObservedObject var theme = Theme.shared
    let day: DayForecast
    let first: Bool

    private func fmt(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = pattern
        return f.string(from: day.date)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(first ? "Сегодня" : fmt("EEEEEE").capitalized).font(.body(T.fontNormal, .semibold))
                .foregroundStyle(theme["primary"])
            Text(fmt("d MMM")).font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
            MIcon(name: day.icon, size: 30, color: theme["secondary"]).padding(.vertical, 2)
            Text("\(day.max)° / \(day.min)°").font(.body(T.fontSmaller, .medium)).foregroundStyle(theme["onSurface"])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: T.l, style: .continuous).fill(theme["surfaceContainer"]))
    }
}
