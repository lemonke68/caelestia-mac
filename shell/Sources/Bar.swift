// Vertical bar, after caelestia modules/bar: logo, workspaces, active window,
// clock, power. Status icons live in SketchyBar (top) instead. Entries are spaced by spacing.medium with padding.large
// above the first and below the last (Bar.qml).

import AppKit
import SwiftUI

struct BarView: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var spaces = SpacesService.shared
    var body: some View {
        VStack(spacing: T.m) {
            OsIcon()
            WorkspacesView()
            Spacer(minLength: T.m)
            ActiveWindowView()
            Spacer(minLength: T.m)
            ClockView()
            PowerButton()
        }
        .padding(.vertical, T.l)
        .frame(width: T.barWidth)
        .frame(maxHeight: .infinity)
    }
}

struct OsIcon: View {
    @ObservedObject var theme = Theme.shared

    var body: some View {
        Image(systemName: "apple.logo")
            .font(.system(size: T.fontLarge * 1.1, weight: .semibold))
            .foregroundStyle(theme["primary"])
            .frame(height: round(T.fontLarge * 1.6))
    }
}

// MARK: - Workspaces

struct WorkspacesView: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var spaces = SpacesService.shared

    private var slots: [Int] {
        let count = max(SpacesService.minShown, spaces.spaces.map(\.index).max() ?? 0)
        return Array(1...count)
    }

    var body: some View {
        VStack(spacing: T.xs) {
            ForEach(slots, id: \.self) { i in
                WorkspaceSlot(index: i, info: spaces.spaces.first { $0.index == i })
            }
        }
        .padding(T.xs)
        .frame(width: T.barInner)
        .background(Capsule().fill(theme["surfaceContainer"]))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: spaces.spaces)
    }
}

struct WorkspaceSlot: View {
    @ObservedObject var theme = Theme.shared
    let index: Int
    let info: SpaceInfo?

    private var focused: Bool { info?.focused ?? false }
    private var occupied: Bool { !(info?.appPIDs.isEmpty ?? true) }
    private var side: CGFloat { T.barInner - T.s }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(index)")
                .font(.rubik(T.fontNormal, focused ? .semibold : .medium))
                .foregroundStyle(focused ? theme["onPrimary"]
                                 : occupied ? theme["onSurface"] : theme["outline"])
                .frame(width: side, height: side)
                .background(Circle().fill(theme["primary"]).opacity(focused ? 1 : 0))

            // Window icons under occupied workspaces (bar.workspaces.showWindows)
            if let pids = info?.appPIDs, !pids.isEmpty {
                VStack(spacing: 2) {
                    ForEach(pids, id: \.self) { pid in
                        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .opacity(focused ? 1 : 0.7)
                        }
                    }
                }
                .padding(.bottom, T.xs)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { SpacesService.shared.focus(index) }
    }
}

// MARK: - Active window

struct ActiveWindowView: View {
    @ObservedObject var theme = Theme.shared
    @ObservedObject var spaces = SpacesService.shared

    private let maxLength: CGFloat = 260

    var body: some View {
        let title = spaces.activeTitle
        let font = NSFont(name: "Google Sans Flex", size: T.fontSmaller) ?? .systemFont(ofSize: T.fontSmaller)
        let width = min(maxLength, ceil((title as NSString).size(withAttributes: [.font: font, .kern: 1.4]).width) + 2)

        VStack(spacing: T.s) {
            if let icon = NSRunningApplication(processIdentifier: spaces.activePID)?.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            // Rotated title, read top to bottom
            Text(title)
                .font(.body(T.fontSmaller))
                .kerning(1.4)
                .foregroundStyle(theme["secondary"])
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .rotationEffect(.degrees(90))
                .frame(width: 18, height: width)
        }
        .animation(.easeOut(duration: 0.2), value: title)
    }
}

// MARK: - Clock

struct ClockView: View {
    @ObservedObject var theme = Theme.shared

    var body: some View {
        // HH:mm only, so a tick per minute (was the bulk of idle CPU at 1 s)
        TimelineView(.everyMinute) { context in
            let date = context.date
            let colour = theme["tertiary"]
            VStack(spacing: T.xs) {
                MIcon(name: "calendar_month", size: T.fontLarge, color: colour)
                VStack(spacing: 0) {
                    Text(format(date, "EEEEEE").capitalized)
                        .font(.body(T.fontSmall * 0.9 * 1.1))
                    Text(format(date, "d"))
                        .font(.rubik(T.fontSmall * 1.1 * 1.1, .semibold))
                }
                .foregroundStyle(colour)
                Rectangle().fill(theme["outlineVariant"]).frame(width: T.barInner - T.s, height: 1)
                    .padding(.vertical, 2)
                VStack(spacing: -2) {
                    Text(format(date, "HH"))
                    Text(format(date, "mm"))
                }
                .font(.rubik(T.fontSmall * 1.1 * 1.25, .medium))
                .foregroundStyle(colour)
            }
            .padding(.vertical, T.xs)
            .frame(width: T.barInner)
        }
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

struct PowerButton: View {
    @ObservedObject var theme = Theme.shared
    @State private var hover = false

    var body: some View {
        MIcon(name: "power_settings_new", size: T.fontLarge, color: theme["error"])
            .fontWeight(.bold)
            .frame(width: T.fontLarge + T.s, height: T.fontLarge + T.s)
            .background(Circle().fill(theme["error"]).opacity(hover ? 0.12 : 0))
            .onHover { hover = $0 }
            .onTapGesture { Shell.post("toggle", "session") }
    }
}

func makeBarWindow(on screen: NSScreen) -> NSWindow {
    let rect = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                      width: T.barWidth, height: screen.frame.height - T.top)
    let window = makeShellWindow(rect, clickThrough: false)
    window.contentView = NSHostingView(rootView: BarView())
    window.setFrame(rect, display: true)
    return window
}
