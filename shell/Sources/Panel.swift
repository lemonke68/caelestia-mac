// Panels that grow out of the frame, as caelestia's drawers: the side touching the
// frame flares out into it with concave corners, the free side has convex corners,
// all with border.rounding. Opening slides the panel out from behind the frame.

import AppKit
import SwiftUI

enum PanelEdge { case top, bottom, left, right }

/// Built in "edge" coordinates (u along the edge, v away from it), then mapped onto the
/// window, so one path serves all four edges. Body spans u ∈ [r, r + along], v ∈ [0, depth].
struct PanelShape: Shape {
    let edge: PanelEdge
    let along: CGFloat
    var depth: CGFloat
    let r: CGFloat

    // Lets a panel whose content changes size (the launcher) animate its height
    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch edge {
            case .top: return CGPoint(x: u, y: v)
            case .bottom: return CGPoint(x: u, y: rect.height - v)
            case .left: return CGPoint(x: v, y: u)
            case .right: return CGPoint(x: rect.width - v, y: u)
            }
        }
        let a = along, d = depth
        let r = min(r, d / 2)
        var path = Path()
        path.move(to: p(0, 0))
        path.addLine(to: p(a + 2 * r, 0))
        // concave flare into the frame, then the far convex corners
        path.addArc(tangent1End: p(a + r, 0), tangent2End: p(a + r, d), radius: r)
        path.addArc(tangent1End: p(a + r, d), tangent2End: p(r, d), radius: r)
        path.addArc(tangent1End: p(r, d), tangent2End: p(r, 0), radius: r)
        path.addArc(tangent1End: p(r, 0), tangent2End: p(0, 0), radius: r)
        path.closeSubpath()
        return path
    }
}

final class PanelState: ObservableObject {
    @Published var open = false
    /// Current depth when the content is smaller than the window (nil = full depth).
    @Published var depth: CGFloat?
}

struct PanelHost<Content: View>: View {
    @ObservedObject var state: PanelState
    @ObservedObject var theme = Theme.shared
    let edge: PanelEdge
    let along: CGFloat
    let depth: CGFloat
    let content: Content

    private var r: CGFloat { T.borderRounding }
    private var horizontal: Bool { edge == .top || edge == .bottom }

    var body: some View {
        let size = horizontal ? CGSize(width: along + 2 * r, height: depth)
                              : CGSize(width: depth, height: along + 2 * r)
        // Closed = pushed back behind the frame edge (the window clips it)
        let hidden = depth + 5
        let shift: CGSize = {
            guard !state.open else { return .zero }
            switch edge {
            case .top: return CGSize(width: 0, height: -hidden)
            case .bottom: return CGSize(width: 0, height: hidden)
            case .left: return CGSize(width: -hidden, height: 0)
            case .right: return CGSize(width: hidden, height: 0)
            }
        }()

        let d = state.depth ?? depth
        let anchor: Alignment = {
            switch edge {
            case .top: return .top
            case .bottom: return .bottom
            case .left: return .leading
            case .right: return .trailing
            }
        }()

        ZStack(alignment: anchor) {
            PanelShape(edge: edge, along: along, depth: d, r: r).fill(theme["surface"])
            content
                .frame(width: horizontal ? along : d, height: horizontal ? d : along)
                .clipped()
        }
        .frame(width: size.width, height: size.height, alignment: anchor)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: d)
        .offset(shift)
        .opacity(state.open ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: state.open)
    }
}

final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Owns one panel window: positioning against the frame, open/close, focus, keys,
/// closing on a click elsewhere.
final class Panel<Content: View> {
    let state: PanelState
    private let window: PanelWindow
    private let edge: PanelEdge
    private var previousApp: NSRunningApplication?
    private var monitors: [Any] = []
    var onKey: ((NSEvent) -> Bool)?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    /// `center` is the panel's centre along its edge, in screen coordinates (x for top/bottom, y for left/right).
    init(edge: PanelEdge, along: CGFloat, depth: CGFloat, center: CGFloat, screen: NSScreen, content: Content,
         state: PanelState = PanelState()) {
        self.edge = edge
        self.state = state
        let r = T.borderRounding
        let f = screen.frame
        let length = along + 2 * r
        let rect: NSRect
        switch edge {
        case .right:
            rect = NSRect(x: f.maxX - T.thickness - depth, y: center - length / 2, width: depth, height: length)
        case .left:
            rect = NSRect(x: f.minX + T.barWidth, y: center - length / 2, width: depth, height: length)
        case .top:
            rect = NSRect(x: center - length / 2, y: f.maxY - T.top - depth, width: length, height: depth)
        case .bottom:
            rect = NSRect(x: center - length / 2, y: f.minY + T.thickness, width: length, height: depth)
        }
        window = PanelWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: shellLevel.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PanelHost(state: state, edge: edge, along: along,
                                                               depth: depth, content: content))
        window.setFrame(rect, display: false)
    }

    var isOpen: Bool { state.open }
    var frame: NSRect { window.frame }

    func toggle() {
        // Open by our state but not on screen here (seen after long uptimes): the next hotkey
        // would only "close" an invisible panel. Reset and open it instead.
        if isOpen && !(window.isVisible && window.isOnActiveSpace) {
            log("panel: open but not visible (visible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace)), reopening")
            state.open = false
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors = []
        }
        isOpen ? close() : open()
    }

    /// activate = take keyboard focus (hotkeys); hover-opened panels leave focus where it is.
    func open(activate: Bool = true) {
        guard !isOpen else { return }
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        if activate {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        } else {
            previousApp = nil
        }
        onOpen?()
        DispatchQueue.main.async { self.state.open = true }

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.window === self.window else { return event }
            if event.keyCode == 53 { self.close(); return nil }  // Esc
            return self.onKey?(event) == true ? nil : event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        // A click on the transparent part of our own window (panel shorter than its window) also closes
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, let d = self.state.depth else { return event }
            let p = event.locationInWindow, size = self.window.frame.size
            let fromEdge: CGFloat = {
                switch self.edge {
                case .bottom: return p.y
                case .top: return size.height - p.y
                case .left: return p.x
                case .right: return size.width - p.x
                }
            }()
            if fromEdge > d { self.close(); return nil }
            return event
        } as Any)
    }

    func close() {
        guard isOpen else { return }
        state.open = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        onClose?()
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.window.orderOut(nil)
        }
    }
}

/// Opens a panel while the pointer rests on a trigger strip (a screen edge, the notch) and
/// closes it once the pointer has left both the strip and the panel — caelestia's showOnHover.
/// Panels opened by hotkey are left alone.
final class EdgeHover {
    private let trigger: NSRect
    private let isOpen: () -> Bool
    private let panelFrame: () -> NSRect
    private let open: () -> Void
    private let close: () -> Void
    private(set) var openedByHover = false
    private var dwell: DispatchWorkItem?
    private var leave: DispatchWorkItem?
    private var monitors: [Any] = []

    init(trigger: NSRect, isOpen: @escaping () -> Bool, panelFrame: @escaping () -> NSRect,
         open: @escaping () -> Void, close: @escaping () -> Void) {
        self.trigger = trigger
        self.isOpen = isOpen
        self.panelFrame = panelFrame
        self.open = open
        self.close = close
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.moved() }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { handler($0); return $0 } as Any)
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    /// The panel was closed some other way (Esc, hotkey, click): forget the hover state.
    func reset() { openedByHover = false }

    private func onTrigger(_ p: NSPoint) -> Bool { trigger.contains(p) }

    private func moved() {
        let p = NSEvent.mouseLocation
        if !isOpen() {
            leave?.cancel()
            leave = nil
            guard onTrigger(p) else { dwell?.cancel(); dwell = nil; return }
            guard dwell == nil else { return }
            // Short dwell so just crossing the edge does not pop the panel
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dwell = nil
                guard self.onTrigger(NSEvent.mouseLocation), !self.isOpen() else { return }
                self.openedByHover = true
                self.open()
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        dwell = nil
        guard openedByHover else { return }
        if onTrigger(p) || panelFrame().contains(p) { leave?.cancel(); leave = nil; return }
        guard leave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.leave = nil
            let q = NSEvent.mouseLocation
            if !self.onTrigger(q) && !self.panelFrame().contains(q) { self.close() }
        }
        leave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
