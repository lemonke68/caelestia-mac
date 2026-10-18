// The caelestia border: a solid frame around the desktop with rounded inner corners.
// The left edge is the bar's width; the top edge is SketchyBar (menu bar height).

import AppKit
import SwiftUI

struct FrameShape: Shape {
    let top: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: 0, y: top, width: rect.width, height: rect.height - top))
        let inner = CGRect(x: T.barWidth, y: top,
                           width: rect.width - T.barWidth - T.thickness,
                           height: rect.height - top - T.thickness)
        path.addRoundedRect(in: inner, cornerSize: CGSize(width: T.borderRounding, height: T.borderRounding),
                            style: .continuous)
        return path
    }
}

struct FrameView: View {
    @ObservedObject var theme = Theme.shared
    let top: CGFloat

    var body: some View {
        FrameShape(top: top)
            .fill(theme["surface"], style: FillStyle(eoFill: true))
            .ignoresSafeArea()
    }
}

/// Above normal and floating windows, below SketchyBar and the panels.
let shellLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

func makeShellWindow(_ rect: NSRect, clickThrough: Bool) -> NSWindow {
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = shellLevel
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.ignoresMouseEvents = clickThrough
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.isReleasedWhenClosed = false
    return window
}

func makeFrameWindow(on screen: NSScreen) -> NSWindow {
    let window = makeShellWindow(screen.frame, clickThrough: true)
    window.contentView = NSHostingView(rootView: FrameView(top: T.top))
    window.setFrame(screen.frame, display: true)
    return window
}
