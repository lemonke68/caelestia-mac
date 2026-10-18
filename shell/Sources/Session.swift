// Session panel on the right edge, after caelestia modules/session/Content.qml:
// logout, shutdown, the theme's session gif, hibernate (sleep here), reboot.
// Buttons are 80 pt (sizes.session.button); ↑/↓ or Tab move focus, Enter runs.

import AppKit
import SwiftUI

struct SessionAction {
    let icon: String
    let run: () -> Void
}

func osascript(_ source: String) {
    shell("/usr/bin/osascript", ["-e", source])
}

final class SessionModel: ObservableObject {
    @Published var focus = 0

    // Index 2 is the gif, not a button
    let actions: [SessionAction?] = [
        SessionAction(icon: "logout") { osascript("tell application \"loginwindow\" to «event aevtrlgo»") },
        SessionAction(icon: "power_settings_new") { osascript("tell application \"System Events\" to shut down") },
        nil,
        SessionAction(icon: "downloading") { shell("/usr/bin/pmset", ["sleepnow"]) },
        SessionAction(icon: "cached") { osascript("tell application \"System Events\" to restart") },
    ]

    var buttonIndices: [Int] { actions.indices.filter { actions[$0] != nil } }

    func move(_ delta: Int) {
        let idx = buttonIndices
        guard let pos = idx.firstIndex(of: focus) else { focus = idx[0]; return }
        focus = idx[(pos + delta + idx.count) % idx.count]
    }

    func run(_ i: Int) {
        guard let action = actions[i] else { return }
        DispatchQueue.global().async { action.run() }
    }
}

struct SessionView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var theme = Theme.shared
    let onRun: () -> Void

    static let button: CGFloat = 80
    static let padding: CGFloat = T.l
    static let rightPadding: CGFloat = max(0, min(T.l - T.thickness, T.l))
    static let spacing: CGFloat = T.l
    static var depth: CGFloat { padding + button + rightPadding }
    static var along: CGFloat { padding * 2 + button * 5 + spacing * 4 }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(model.actions.indices, id: \.self) { i in
                if let action = model.actions[i] {
                    SessionButton(icon: action.icon, focused: model.focus == i) {
                        model.focus = i
                        onRun()
                        model.run(i)
                    }
                } else {
                    SessionGif(path: theme.sessionGif)
                        .frame(width: Self.button, height: Self.button)
                }
            }
        }
        .padding(.leading, Self.padding)
        .padding(.trailing, Self.rightPadding)
        .padding(.vertical, Self.padding)
    }
}

struct SessionButton: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let focused: Bool
    let action: () -> Void
    @State private var pressed = false
    @State private var hover = false

    var body: some View {
        let radius: CGFloat = pressed ? T.m : focused ? T.xl : 20
        MIcon(name: icon, size: 24 * 1.3, color: focused ? theme["onSecondaryContainer"] : theme["onSurface"])
            .frame(width: SessionView.button, height: SessionView.button)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(focused ? theme["secondaryContainer"] : theme["surfaceContainer"])
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme["onSurface"]).opacity(hover ? 0.08 : 0)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: radius)
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false; action() })
    }
}

struct SessionGif: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> FillView {
        let view = FillView(frame: .zero, background: .clear, gravity: .resizeAspect)
        load(into: view)
        context.coordinator.path = path
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
            guard let frames = Frames(path: path, maxPixel: Int(SessionView.button * 2)) else { return }
            DispatchQueue.main.async { view.show(frames) }
        }
    }
}

/// Session panel + opening by hover on the right screen edge beside it.
final class SessionController {
    let panel: Panel<SessionView>
    private var hover: EdgeHover?

    init(screen: NSScreen) {
        let panel = makeSessionPanel(on: screen)
        self.panel = panel
        let f = panel.frame
        let r = T.borderRounding
        // The frame's right border next to the panel's body
        let strip = NSRect(x: screen.frame.maxX - T.thickness - 1, y: f.minY + r, width: T.thickness + 1, height: f.height - 2 * r)
        hover = EdgeHover(trigger: strip, isOpen: { panel.isOpen }, panelFrame: { panel.frame },
                          open: { panel.open(activate: false) }, close: { panel.close() })
        panel.onClose = { [weak self] in self?.hover?.reset() }
    }

    func toggle() { panel.toggle() }
}

func makeSessionPanel(on screen: NSScreen) -> Panel<SessionView> {
    let model = SessionModel()
    var panel: Panel<SessionView>!
    let view = SessionView(model: model) { panel?.close() }
    let innerTop = screen.frame.maxY - T.top
    let innerBottom = screen.frame.minY + T.thickness
    panel = Panel(edge: .right, along: SessionView.along, depth: SessionView.depth,
                  center: (innerTop + innerBottom) / 2, screen: screen, content: view)
    panel.onOpen = { model.focus = 0 }
    panel.onKey = { event in
        switch event.keyCode {
        case 126: model.move(-1); return true                              // ↑
        case 125: model.move(1); return true                               // ↓
        case 48: model.move(event.modifierFlags.contains(.shift) ? -1 : 1); return true  // Tab
        case 36, 76: panel.close(); model.run(model.focus); return true     // Enter
        default: return false
        }
    }
    return panel
}
