// Dashboard hanging from the notch, after caelestia modules/dashboard (Tabs + Dash.qml).
//
//   ┌ weather 275 ┬ user 340 ──────────────┬ media 200 ┐
//   ├ time 110 ┬ calendar ┬ resources ─────┤           │
//   └──────────┴──────────┴────────────────┴───────────┘
//
// Opens when the pointer rests on the notch (caelestia dashboard.showOnHover) and closes
// once it leaves both the notch and the panel; alt + O toggles it with keyboard focus.

import AppKit
import SwiftUI

enum DashTab: Int, CaseIterable {
    case dashboard, media, performance, weather

    var icon: String {
        switch self {
        case .dashboard: return "dashboard"
        case .media: return "queue_music"
        case .performance: return "speed"
        case .weather: return "cloud"
        }
    }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .media: return "Media"
        case .performance: return "Performance"
        case .weather: return "Weather"
        }
    }
}

final class DashModel: ObservableObject {
    @Published var tab: DashTab = .dashboard
    @Published var month = Date()
}

enum DashSize {
    static let gap = T.m
    static let weatherW: CGFloat = 275
    static let userW: CGFloat = 340
    static let timeW: CGFloat = 110
    static let mediaW: CGFloat = 200
    static let resourcesW: CGFloat = 90
    static let row0H: CGFloat = 100
    static let row1H: CGFloat = 260
    static let tabsH: CGFloat = 44

    static var leftW: CGFloat { weatherW + gap + userW }
    static var calendarW: CGFloat { leftW - timeW - resourcesW - 2 * gap }
    static var gridW: CGFloat { leftW + gap + mediaW }
    static var gridH: CGFloat { row0H + gap + row1H }
    static var along: CGFloat { gridW + 2 * T.l }
    static var depth: CGFloat { T.l + tabsH + gap + gridH + T.l }
}

struct DashboardView: View {
    @ObservedObject var model: DashModel
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(spacing: DashSize.gap) {
            TabsView(model: model)
            Group {
                switch model.tab {
                case .dashboard: DashGrid(model: model)
                case .media: MediaTab()
                case .performance: PerformanceTab()
                case .weather: WeatherTab()
                }
            }
            .frame(width: DashSize.gridW, height: DashSize.gridH)
        }
        .padding(T.l)
    }
}

struct TabsView: View {
    @ObservedObject var model: DashModel
    @ObservedObject var theme = Theme.shared
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                ForEach(DashTab.allCases, id: \.self) { tab in
                    let active = model.tab == tab
                    VStack(spacing: 2) {
                        MIcon(name: tab.icon, size: 20, color: active ? theme["primary"] : theme["onSurfaceVariant"])
                        Text(tab.title)
                            .font(.body(T.fontSmaller, active ? .medium : .regular))
                            .foregroundStyle(active ? theme["primary"] : theme["onSurfaceVariant"])
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.tab = tab } }
                    .overlay(alignment: .bottom) {
                        if active {
                            Capsule().fill(theme["primary"]).frame(height: 3).padding(.horizontal, 30)
                                .offset(y: 8)
                                .matchedGeometryEffect(id: "indicator", in: ns)
                        }
                    }
                }
            }
            Rectangle().fill(theme["outlineVariant"]).frame(height: 1).padding(.top, 3)
        }
        .frame(height: DashSize.tabsH)
    }
}

// MARK: - Grid

struct DashCard<Content: View>: View {
    @ObservedObject var theme = Theme.shared
    let radius: CGFloat
    let content: Content

    init(radius: CGFloat, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme["surfaceContainer"]))
    }
}

struct DashGrid: View {
    @ObservedObject var model: DashModel
    let gap = DashSize.gap

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    DashCard(radius: T.xl * 1.5) { WeatherSmall() }
                        .frame(width: DashSize.weatherW, height: DashSize.row0H)
                    DashCard(radius: T.xl) { UserCard() }
                        .frame(width: DashSize.userW, height: DashSize.row0H)
                }
                HStack(spacing: gap) {
                    DashCard(radius: T.l) { DateTimeCard() }
                        .frame(width: DashSize.timeW, height: DashSize.row1H)
                    DashCard(radius: T.xl) { CalendarCard(model: model) }
                        .frame(width: DashSize.calendarW, height: DashSize.row1H)
                    DashCard(radius: T.l) { ResourcesCard() }
                        .frame(width: DashSize.resourcesW, height: DashSize.row1H)
                }
            }
            DashCard(radius: T.xl * 2) { MediaCard() }
                .frame(width: DashSize.mediaW, height: DashSize.gridH)
        }
    }
}

// MARK: - Cards

struct WeatherSmall: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var weather = WeatherService.shared

    var body: some View {
        HStack(spacing: 20) {
            MIcon(name: weather.icon, size: 28 * 1.6, color: theme["secondary"])
            VStack(spacing: T.xs) {
                Text(weather.temp).font(.body(26, .semibold)).foregroundStyle(theme["primary"])
                Text(weather.description)
                    .font(.body(T.fontSmall))
                    .foregroundStyle(theme["onSurface"])
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(weather.city)
    }
}

struct UserCard: View {
    @ObservedObject var theme = Theme.shared

    private var face: NSImage? { NSImage(contentsOfFile: expand("~/.face")) }

    var body: some View {
        let h = DashSize.row0H - 2 * T.l
        HStack(spacing: 0) {
            // Logo in a gem, overlapping the picture (User.qml)
            ZStack {
                WavyShape(lobes: 6, amplitude: 0.08).fill(theme["primaryContainer"])
                Image(systemName: "apple.logo").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme["onPrimaryContainer"])
            }
            .frame(width: 30 + 2 * T.s, height: 30 + 2 * T.s)
            .zIndex(1)

            ZStack {
                Capsule().fill(theme["surfaceContainerHighest"])
                if let face {
                    Image(nsImage: face).resizable().aspectRatio(contentMode: .fill).clipShape(Capsule())
                } else {
                    MIcon(name: "person", size: 28, color: theme["onSurfaceVariant"])
                }
            }
            .frame(width: h, height: h)
            .padding(.leading, -(20 + 28) / 2)

            VStack(alignment: .leading, spacing: T.s) {
                HStack(spacing: T.xs) {
                    MIcon(name: "select_window", size: T.fontSmall, color: theme["onSecondaryContainer"])
                    Text("yabai…").font(.body(T.fontSmall).italic()).foregroundStyle(theme["onSecondaryContainer"])
                }
                .padding(.horizontal, T.m)
                .padding(.vertical, T.s)
                .background(Capsule().fill(theme["secondaryContainer"]))

                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    HStack(spacing: T.s) {
                        ZStack {
                            WavyShape(lobes: 2, amplitude: 0.12).fill(theme["tertiaryContainer"])
                            MIcon(name: "clock_arrow_up", size: 16, color: theme["onTertiaryContainer"])
                        }
                        .frame(width: 30, height: 30)
                        Text("аптайм \(uptimeString())")
                            .font(.body(T.fontSmall))
                            .foregroundStyle(theme["onSurface"])
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, T.s)
            Spacer(minLength: 0)
        }
        .padding(T.l)
    }
}

struct DateTimeCard: View {
    @ObservedObject var theme = Theme.shared

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: ctx.date)
            VStack(spacing: -10) {
                Text(String(format: "%02d", comps.hour ?? 0)).font(.rubik(28, .semibold)).foregroundStyle(theme["secondary"])
                Text("•••").font(.rubik(28 * 0.9)).foregroundStyle(theme["primary"])
                Text(String(format: "%02d", comps.minute ?? 0)).font(.rubik(28, .semibold)).foregroundStyle(theme["secondary"])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CalendarCard: View {
    @ObservedObject var model: DashModel
    @ObservedObject var theme = Theme.shared

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ru_RU")
        c.firstWeekday = 2
        return c
    }

    private func shift(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: model.month) {
            withAnimation(.easeOut(duration: 0.2)) { model.month = d }
        }
    }

    var body: some View {
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: model.month))!
        let offset = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -offset, to: monthStart)!
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }
        let title: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = "LLLL yyyy"
            return f.string(from: monthStart).capitalized
        }()
        let weekdays = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]

        VStack(spacing: T.xs) {
            HStack {
                MIcon(name: "chevron_left", size: 18, color: theme["onSurface"]).fontWeight(.bold)
                    .frame(width: 28, height: 28).contentShape(Rectangle()).onTapGesture { shift(-1) }
                Spacer()
                Text(title).font(.body(T.fontLarger, .medium)).foregroundStyle(theme["primary"])
                    .onTapGesture { withAnimation { model.month = Date() } }
                Spacer()
                MIcon(name: "chevron_right", size: 18, color: theme["onSurface"]).fontWeight(.bold)
                    .frame(width: 28, height: 28).contentShape(Rectangle()).onTapGesture { shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(weekdays.indices, id: \.self) { i in
                    Text(weekdays[i]).font(.body(T.fontSmall, .medium))
                        .foregroundStyle(i >= 5 ? theme["tertiary"] : theme["onSurface"])
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(days, id: \.self) { day in
                    let inMonth = cal.isDate(day, equalTo: monthStart, toGranularity: .month)
                    let today = cal.isDateInToday(day)
                    let weekend = cal.isDateInWeekend(day)
                    Text("\(cal.component(.day, from: day))")
                        .font(.body(T.fontSmall, today ? .semibold : .regular))
                        .foregroundStyle(today ? theme["onPrimary"]
                                         : !inMonth ? theme["outline"].opacity(0.6)
                                         : weekend ? theme["tertiary"] : theme["onSurfaceVariant"])
                        .frame(width: 24, height: 22)
                        .background {
                            if today { WavyShape(lobes: 8, amplitude: 0.09).fill(theme["primary"]).frame(width: 28, height: 28) }
                        }
                }
            }
        }
        .padding(T.l)
        .scrollWheelMonths { shift($0) }
    }
}

struct ResourcesCard: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var res = ResourcesService.shared

    var body: some View {
        VStack(spacing: T.m) {
            Ring(value: res.cpu, icon: "memory", color: theme["primary"])
            Ring(value: res.memory, icon: "memory_alt", color: theme["tertiary"])
            Ring(value: res.storage, icon: "hard_disk", color: theme["secondary"])
        }
        .padding(T.l)
    }
}

struct Ring: View {
    @ObservedObject var theme = Theme.shared
    let value: Double
    let icon: String
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(theme["secondaryContainer"], lineWidth: 6)
            Circle().trim(from: 0, to: max(0.001, value))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            MIcon(name: icon, size: 20, color: color)
        }
        .padding(3)
        .help("\(Int(value * 100))%")
    }
}

struct MediaCard: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var media = MediaService.shared

    var body: some View {
        let cover: CGFloat = 124
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ZStack {
                    // 180° progress arc over the top of the cover (Media.qml)
                    Circle().trim(from: 0, to: 0.5)
                        .stroke(theme["secondaryContainer"], style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(180))
                    Circle().trim(from: 0, to: 0.5 * media.progress(at: ctx.date))
                        .stroke(theme["primary"], style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(180))
                    ZStack {
                        Circle().fill(theme["surfaceContainerHigh"])
                        if let art = media.artwork {
                            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            MIcon(name: "art_track", size: 48, color: theme["onSurfaceVariant"])
                        }
                    }
                    .frame(width: cover, height: cover)
                    .clipShape(Circle())
                }
                .frame(width: cover + 2 * (T.xs + 6), height: cover + 2 * (T.xs + 6))
            }
            .padding(.top, T.m)

            VStack(spacing: T.s) {
                Text(media.title ?? "Ничего не играет").font(.body(T.fontLarger, .medium)).foregroundStyle(theme["primary"])
                Text(media.album ?? "—").font(.body(T.fontSmall)).foregroundStyle(theme["outline"])
                Text(media.artist ?? "—").font(.body(T.fontNormal)).foregroundStyle(theme["secondary"])
            }
            .lineLimit(1)
            .frame(width: DashSize.mediaW - 32)
            .padding(.top, T.m)

            HStack(spacing: T.xs) {
                MediaButton(icon: "skip_previous") { media.send("previous-track") }
                MediaButton(icon: media.playing ? "pause" : "play_arrow", primary: true) { media.send("toggle-play-pause") }
                MediaButton(icon: "skip_next") { media.send("next-track") }
            }
            .padding(.top, T.m)

            ThemeGif(path: theme.mediaGif)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, T.l)
                .padding(.top, T.s)
                .padding(.bottom, T.l)
        }
    }
}

struct MediaButton: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    var primary = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        MIcon(name: icon, size: 22, color: primary ? theme["onPrimary"] : theme["onSurface"])
            .frame(width: primary ? 52 : 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: hover ? 12 : 20, style: .continuous)
                    .fill(primary ? theme["primary"] : theme["surfaceContainerHigh"])
            )
            .animation(.spring(response: 0.3), value: hover)
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

/// A theme gif (session / media sprite), aspect-fit.
struct ThemeGif: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> FillView {
        let view = FillView(frame: .zero, background: .clear, gravity: .resizeAspect)
        context.coordinator.path = path
        load(into: view)
        return view
    }

    func updateNSView(_ view: FillView, context: Context) {
        guard context.coordinator.path != path else { return }
        context.coordinator.path = path
        load(into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var path = "" }

    private func load(into view: FillView) {
        let path = expand(path)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let frames = Frames(path: path, maxPixel: 400) else { return }
            DispatchQueue.main.async { view.show(frames) }
        }
    }
}

/// Approximation of Material 3 expressive shapes (Gem, ClamShell, Sunny…):
/// a circle whose radius wobbles with `lobes` bumps.
struct WavyShape: Shape {
    let lobes: Int
    let amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2 / (1 + amplitude)
        var path = Path()
        let steps = 120
        for i in 0...steps {
            let a = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let r = base * (1 + amplitude * cos(CGFloat(lobes) * a))
            let p = CGPoint(x: c.x + r * cos(a - .pi / 2), y: c.y + r * sin(a - .pi / 2))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

extension View {
    /// One wheel notch (or ~40 pt of trackpad travel) = one month.
    func scrollWheelMonths(_ action: @escaping (Int) -> Void) -> some View {
        background(ScrollCatcher(action: action))
    }
}

struct ScrollCatcher: NSViewRepresentable {
    let action: (Int) -> Void

    final class CatcherView: NSView {
        var action: ((Int) -> Void)?
        private var accum: CGFloat = 0
        override func scrollWheel(with event: NSEvent) {
            let d = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                accum += d
                if abs(accum) >= 40 { action?(accum > 0 ? -1 : 1); accum = 0 }
            } else if d != 0 {
                action?(d > 0 ? -1 : 1)
            }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.action = action }
}

// MARK: - Controller

/// Panel + notch hover logic.
final class DashboardController {
    let model = DashModel()
    let panel: Panel<DashboardView>
    private var hover: EdgeHover?

    init(screen: NSScreen) {
        let f = screen.frame
        let left = screen.auxiliaryTopLeftArea?.width ?? (f.width - 200) / 2
        let right = screen.auxiliaryTopRightArea?.minX ?? (f.width + 200) / 2
        let notch = NSRect(x: f.minX + left, y: f.maxY - T.top, width: right - left, height: T.top)
        panel = Panel(edge: .top, along: DashSize.along, depth: DashSize.depth,
                      center: notch.midX, screen: screen, content: DashboardView(model: model))
        panel.onOpen = { [weak self] in
            WeatherService.shared.reload()
            ResourcesService.shared.setActive(true)
            PerfService.shared.setActive(true)
            self?.model.month = Date()
        }
        panel.onClose = { [weak self] in
            ResourcesService.shared.setActive(false)
            PerfService.shared.setActive(false)
            self?.hover?.reset()
        }
        panel.onKey = { [weak self] event in
            guard let self else { return false }
            switch event.keyCode {
            case 123: self.cycleTab(-1); return true  // ←
            case 124: self.cycleTab(1); return true   // →
            default: return false
            }
        }
        let panel = self.panel
        hover = EdgeHover(trigger: notch.insetBy(dx: -6, dy: -2), isOpen: { panel.isOpen },
                          panelFrame: { panel.frame.insetBy(dx: T.borderRounding, dy: 0) },
                          open: { panel.open(activate: false) }, close: { panel.close() })
    }

    func toggle() {
        if panel.isOpen { panel.close() } else { panel.open(activate: true) }
    }

    /// `rice-shell dashboard media|performance|weather|dashboard`: open straight on a tab.
    func show(tab name: String) {
        guard let tab = DashTab.allCases.first(where: { $0.title.lowercased() == name.lowercased() }) else { return }
        model.tab = tab
        if !panel.isOpen { panel.open(activate: true) }
    }

    private func cycleTab(_ d: Int) {
        let n = DashTab.allCases.count
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            model.tab = DashTab(rawValue: (model.tab.rawValue + d + n) % n)!
        }
    }
}
