// Colours and size tokens. Colours come from the current mac-rice theme's scheme.txt
// (the same 120 Material roles caelestia uses); sizes from caelestia's tokens.hpp.

import AppKit
import SwiftUI

/// mac-rice checkout: the first ancestor of the executable that has themes/ (the binary may sit
/// in bin/ or inside bin/RiceShell.app/Contents/MacOS/).
let riceRoot: URL = {
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("themes").path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: expand("~/.local/share/mac-rice"))
}()
let binDir = riceRoot.appendingPathComponent("bin")

func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

final class Theme: ObservableObject {
    static let shared = Theme()

    @Published private(set) var colours: [String: String] = [:]
    @Published private(set) var mode = "dark"
    @Published private(set) var sessionGif = ""
    @Published private(set) var mediaGif = ""

    private init() {
        reload()
    }

    func reload() {
        let name = (try? String(contentsOfFile: expand("~/.local/state/mac-rice/theme"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "hyprlain"
        let dir = riceRoot.appendingPathComponent("themes/\(name)")
        var colours: [String: String] = [:]
        if let text = try? String(contentsOf: dir.appendingPathComponent("scheme.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 2 { colours[String(parts[0])] = String(parts[1]) }
            }
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("theme.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            mode = json["mode"] as? String ?? "dark"
            sessionGif = json["sessionGif"] as? String ?? ""
            mediaGif = json["mediaGif"] as? String ?? ""
        }
        self.colours = colours
    }

    subscript(role: String) -> Color { Color(nsColor: ns(role)) }

    func ns(_ role: String) -> NSColor {
        let v = UInt32(colours[role] ?? "888888", radix: 16) ?? 0x888888
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// caelestia tokens.hpp + border/bar config, in points.
enum T {
    // border (borderconfig.hpp)
    static let thickness: CGFloat = 10
    static let borderRounding: CGFloat = 25

    // bar
    static let barInner: CGFloat = 40
    static let barWidth: CGFloat = barInner + 2 * thickness

    // rounding / spacing / padding
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 28

    // font sizes
    static let fontSmall: CGFloat = 11
    static let fontSmaller: CGFloat = 12
    static let fontNormal: CGFloat = 13
    static let fontLarger: CGFloat = 15
    static let fontLarge: CGFloat = 18

    /// Height of the strip SketchyBar covers (the frame's top edge).
    static var top: CGFloat { Geometry(primaryScreen).bar }
}

/// The screen rice-shell draws on: the one with the menu bar (also with the lid closed).
var primaryScreen: NSScreen? { NSScreen.screens.first }

/// Top bar geometry for any Mac: with a notch the bar is the notch height (38 pt on the 14"),
/// without one the menu bar (24 pt) is too thin for the bar's pills, so the bar grows to
/// `minBar` and yabai reserves the difference (`external_bar`).
struct Geometry {
    static let minBar: CGFloat = 32

    let menuBar: CGFloat
    let notchWidth: CGFloat

    init(_ screen: NSScreen?) {
        guard let screen else { menuBar = 24; notchWidth = 0; return }
        let inset = screen.safeAreaInsets.top
        let visible = screen.frame.maxY - screen.visibleFrame.maxY
        menuBar = inset > 0 ? inset : visible > 0 ? visible : 24
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX + 10  // a little air either side of the cut-out
        } else {
            notchWidth = 0
        }
    }

    var bar: CGFloat { max(menuBar, Geometry.minBar) }
    var externalBar: CGFloat { bar - menuBar }

    /// `rice-shell screen-info`, sourced by sketchybarrc and yabairc.
    var shellVars: String {
        """
        RICE_BAR_HEIGHT=\(Int(bar))
        RICE_MENUBAR_HEIGHT=\(Int(menuBar))
        RICE_NOTCH_WIDTH=\(Int(notchWidth))
        RICE_EXTERNAL_BAR=\(Int(externalBar))
        """
    }
}

extension Font {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Google Sans Flex", size: size).weight(weight)
    }

    static func rubik(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom("Rubik", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        .custom("JetBrainsMono Nerd Font", size: size)
    }
}

/// Material Symbols Rounded glyph by ligature name, as caelestia's MaterialIcon.
struct MIcon: View {
    let name: String
    var size: CGFloat = 18
    var color: Color

    var body: some View {
        Text(name)
            .font(.custom("Material Symbols Rounded", size: size))
            .foregroundStyle(color)
            .fixedSize()
    }
}
