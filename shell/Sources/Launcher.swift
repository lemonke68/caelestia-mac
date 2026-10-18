// Launcher on the bottom edge, after caelestia modules/launcher: search field at the
// bottom, results grow upwards (launcher.maxShown 7 × itemHeight 57, itemWidth 600).
//
//   text         apps (fuzzy, most launched first)
//   2+2*3        calculator, Enter copies the result
//   >            commands: >calc, >theme <name>, >wallpaper, >lock, >sleep, >session, …
//
// alt + Space toggles it. ↑/↓ move, Enter runs, Tab completes a command, Esc closes.

import AppKit
import Combine
import SwiftUI

// MARK: - Items

struct LaunchItem: Identifiable {
    enum Kind { case app(URL), calc(String), action(() -> Void), complete(String) }

    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let symbol: String?  // Material Symbols name when there is no app icon
    let kind: Kind
}

// MARK: - App index

final class AppIndex {
    struct App {
        let url: URL
        let name: String
        let category: String
        let bundleID: String
    }

    static let shared = AppIndex()
    private(set) var apps: [App] = []
    private var counts: [String: Int] = [:]
    private let countsPath = expand("~/.local/state/mac-rice/launcher.json")

    private init() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: countsPath)),
           let c = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            counts = c
        }
        reload()
    }

    func reload() {
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", expand("~/Applications")]
        var seen = Set<String>()
        var found: [App] = []
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                let bundle = Bundle(url: url)
                let id = bundle?.bundleIdentifier ?? url.path
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let cat = (bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String) ?? ""
                found.append(App(url: url, name: name, category: Self.category(cat), bundleID: id))
            }
        }
        apps = found
    }

    func count(_ id: String) -> Int { counts[id] ?? 0 }

    func launched(_ id: String) {
        counts[id, default: 0] += 1
        if let data = try? JSONSerialization.data(withJSONObject: counts) {
            try? data.write(to: URL(fileURLWithPath: countsPath))
        }
    }

    private static func category(_ uti: String) -> String {
        let map = [
            "developer-tools": "Разработка", "music": "Музыка", "productivity": "Продуктивность",
            "utilities": "Утилиты", "graphics-design": "Графика", "photography": "Фото",
            "video": "Видео", "social-networking": "Общение", "games": "Игры", "entertainment": "Развлечения",
            "business": "Бизнес", "education": "Обучение", "finance": "Финансы", "reference": "Справка",
            "news": "Новости", "lifestyle": "Стиль жизни", "weather": "Погода", "travel": "Путешествия",
        ]
        let key = uti.replacingOccurrences(of: "public.app-category.", with: "")
        return map.first { key.hasPrefix($0.key) }?.value ?? "Приложение"
    }
}

/// The same keys on the other layout: "яут" → "zen", "ghbdtn" → "привет".
func swapLayout(_ s: String) -> String {
    let en = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
    let ru = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")
    var map: [Character: Character] = [:]
    for (a, b) in zip(en, ru) { map[a] = b; map[b] = a }
    return String(s.map { map[$0] ?? $0 })
}

/// Fuzzy score: prefix > word start > substring > in-order letters. nil = no match.
func fuzzyScore(_ query: String, _ text: String) -> Double? {
    let q = query.lowercased(), t = text.lowercased()
    if q.isEmpty { return 0 }
    if t.hasPrefix(q) { return 100 - Double(t.count - q.count) * 0.1 }
    let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
    let initials = String(words.compactMap(\.first))
    if initials.hasPrefix(q) { return 70 }
    if t.contains(q) { return 60 }
    var it = t.makeIterator()
    var gaps = 0
    for ch in q {
        var found = false
        while let c = it.next() {
            if c == ch { found = true; break }
            gaps += 1
        }
        if !found { return nil }
    }
    return max(1, 40 - Double(gaps))
}

// MARK: - Calculator (own parser: NSExpression raises uncatchable exceptions on bad input)

enum Calc {
    static func looksLikeMath(_ s: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/%^() ×÷")
        return s.rangeOfCharacter(from: .decimalDigits) != nil
            && s.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/%^×÷")) != nil
            && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func evaluate(_ input: String) -> Double? {
        var p = Parser(Array(input.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .filter { !$0.isWhitespace }))
        guard let v = p.expr(), p.done else { return nil }
        return v.isFinite ? v : nil
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.10g", v)
    }

    struct Parser {
        let s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }
        var done: Bool { i == s.count }

        mutating func peek() -> Character? { i < s.count ? s[i] : nil }

        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                guard let r = power() else { return nil }
                v = c == "*" ? v * r : c == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
            }
            return v
        }

        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return pow(b, e)
            }
            return b
        }

        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return atom()
        }

        mutating func atom() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return start == i ? nil : Double(String(s[start..<i]))
        }
    }
}

// MARK: - Model

final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var items: [LaunchItem] = []
    @Published var selected = 0
    var close: () -> Void = {}

    static let maxShown = 7
    static let itemHeight: CGFloat = 57
    static let itemWidth: CGFloat = 600

    func reset() {
        AppIndex.shared.reload()
        query = ""
        refresh()
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
    }

    func run(_ index: Int? = nil) {
        let i = index ?? selected
        guard items.indices.contains(i) else { return }
        switch items[i].kind {
        case .app(let url):
            AppIndex.shared.launched(items[i].id)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            close()
        case .calc(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            close()
        case .action(let action):
            close()
            action()
        case .complete(let text):
            query = text
        }
    }

    /// Tab: complete the selected command.
    func complete() {
        guard items.indices.contains(selected), case .complete(let text) = items[selected].kind else { return }
        query = text
    }

    private func refresh() {
        selected = 0
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(">") {
            items = actions(String(q.dropFirst()))
        } else if Calc.looksLikeMath(q), let v = Calc.evaluate(q) {
            items = [calcItem(q, v)] + apps(q)
        } else {
            items = apps(q)
        }
        items = Array(items.prefix(Self.maxShown))
    }

    private func calcItem(_ expr: String, _ v: Double) -> LaunchItem {
        let r = Calc.format(v)
        return LaunchItem(id: "calc", title: r, subtitle: "\(expr) = \(r) · Enter — скопировать",
                          icon: nil, symbol: "calculate", kind: .calc(r))
    }

    private func apps(_ q: String) -> [LaunchItem] {
        let index = AppIndex.shared
        let swapped = swapLayout(q)
        let scored: [(AppIndex.App, Double)] = index.apps.compactMap { app in
            // Typed on the wrong layout? Try the other one too, slightly lower
            let direct = fuzzyScore(q, app.name)
            let other = fuzzyScore(swapped, app.name).map { $0 - 5 }
            guard let s = [direct, other].compactMap({ $0 }).max() else { return nil }
            return (app, s + Double(min(index.count(app.bundleID), 50)) * (q.isEmpty ? 1 : 0.2))
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedCompare($1.0.name) == .orderedAscending }
            .map { app, _ in
                LaunchItem(id: app.bundleID, title: app.name, subtitle: app.category,
                           icon: NSWorkspace.shared.icon(forFile: app.url.path), symbol: nil, kind: .app(app.url))
            }
    }

    // MARK: Commands

    private func run(_ path: String, _ args: [String] = []) {
        DispatchQueue.global().async { shell(path, args) }
    }

    private var bin: String { binDir.path }

    private func actions(_ raw: String) -> [LaunchItem] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : ""

        // >calc <expr>
        if cmd == "calc" {
            if let v = Calc.evaluate(arg) { return [calcItem(arg, v)] }
            return [LaunchItem(id: "calc-hint", title: "Калькулятор", subtitle: "Введите выражение: 2^10, (3+4)*5, 7%3",
                               icon: nil, symbol: "calculate", kind: .complete(">calc "))]
        }

        // >theme <name>
        if cmd == "theme" || cmd == "scheme" {
            let themes = (try? FileManager.default.contentsOfDirectory(atPath: riceRoot.appendingPathComponent("themes").path))?
                .filter { !$0.hasPrefix(".") }.sorted() ?? []
            return themes.compactMap { name in
                guard fuzzyScore(arg, name) != nil else { return nil }
                return LaunchItem(id: "theme-\(name)", title: name, subtitle: "Применить тему",
                                  icon: nil, symbol: "palette",
                                  kind: .action { [weak self] in self?.run("\(self?.bin ?? "")/theme-switch", [name]) })
            }
        }

        let all: [(String, String, String, LaunchItem.Kind)] = [
            ("calc", "Калькулятор", "calculate", .complete(">calc ")),
            ("theme", "Тема", "palette", .complete(">theme ")),
            ("wallpaper", "Обои", "wallpaper", .action { [weak self] in self?.run("\(self?.bin ?? "")/rice-picker") }),
            ("dashboard", "Дашборд", "dashboard", .action { Shell.post("toggle", "dashboard") }),
            ("session", "Сессия", "power_settings_new", .action { Shell.post("toggle", "session") }),
            ("lock", "Заблокировать", "lock",
             .action { osascript("tell application \"System Events\" to keystroke \"q\" using {command down, control down}") }),
            ("sleep", "Сон", "bedtime", .action { [weak self] in self?.run("/usr/bin/pmset", ["sleepnow"]) }),
        ]
        // >light / >dark: the first installed theme in that mode, if there is one
        let modes: [(String, String, String, LaunchItem.Kind)] = [("light", "Светлая", "light_mode"), ("dark", "Тёмная", "dark_mode")]
            .compactMap { mode, title, symbol in
                guard let name = Self.theme(mode: mode) else { return nil }
                return (mode, "\(title) тема (\(name))", symbol,
                        .action { [weak self] in self?.run("\(self?.bin ?? "")/theme-switch", [name]) })
            }
        return (all + modes).compactMap { key, title, symbol, kind in
            guard fuzzyScore(cmd, key) != nil || fuzzyScore(text, title) != nil else { return nil }
            return LaunchItem(id: "action-\(key)", title: title, subtitle: ">\(key)", icon: nil, symbol: symbol, kind: kind)
        }
    }
}

// MARK: - Views

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var state: PanelState
    @ObservedObject var theme = Theme.shared
    @FocusState private var focused: Bool

    static let padding: CGFloat = T.l
    static let searchHeight: CGFloat = 48
    static let bottomPadding: CGFloat = max(0, min(T.l - T.thickness, T.l))

    static func depth(rows: Int) -> CGFloat {
        let list = CGFloat(max(rows, 1)) * LauncherModel.itemHeight
        return padding + list + padding + searchHeight + bottomPadding
    }

    var body: some View {
        VStack(spacing: Self.padding) {
            Spacer(minLength: 0)
            if model.items.isEmpty {
                HStack(spacing: T.m) {
                    MIcon(name: "manage_search", size: 30, color: theme["onSurfaceVariant"])
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ничего не найдено").font(.body(T.fontLarger)).foregroundStyle(theme["onSurfaceVariant"])
                        Text("Попробуйте другой запрос").font(.body(T.fontSmall)).foregroundStyle(theme["outline"])
                    }
                }
                .frame(height: LauncherModel.itemHeight)
            } else {
                // Best match sits next to the search field, so the list reads bottom-up
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()).reversed(), id: \.element.id) { i, item in
                        LaunchRow(item: item, selected: i == model.selected)
                            .onTapGesture { model.run(i) }
                            .onHover { if $0 { model.selected = i } }
                    }
                }
            }
            searchBar
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, Self.padding)
        .padding(.bottom, Self.bottomPadding)
        .onChange(of: state.open) { _, open in if open { DispatchQueue.main.async { focused = true } } }
    }

    private var searchBar: some View {
        HStack(spacing: T.s) {
            MIcon(name: "search", size: 22, color: theme["onSurfaceVariant"])
            TextField("", text: $model.query,
                      prompt: Text("Введите «>» для команд").foregroundColor(theme["onSurfaceVariant"]))
                .textFieldStyle(.plain)
                .font(.body(T.fontLarger))
                .foregroundStyle(theme["onSurface"])
                .focused($focused)
            if !model.query.isEmpty {
                MIcon(name: "close", size: 20, color: theme["onSurfaceVariant"])
                    .onTapGesture { model.query = "" }
            }
        }
        .padding(.horizontal, T.l)
        .frame(height: Self.searchHeight)
        .background(Capsule().fill(theme["surfaceContainer"]))
    }
}

struct LaunchRow: View {
    @ObservedObject var theme = Theme.shared
    let item: LaunchItem
    let selected: Bool

    var body: some View {
        let h = LauncherModel.itemHeight
        HStack(spacing: T.m) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    ZStack {
                        Circle().fill(theme["secondaryContainer"])
                        MIcon(name: item.symbol ?? "help_outline", size: 22, color: theme["onSecondaryContainer"])
                    }
                    .padding(4)
                }
            }
            .frame(width: h * 0.8, height: h * 0.8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body(T.fontNormal + 1)).foregroundStyle(theme["onSurface"])
                Text(item.subtitle).font(.body(T.fontSmall)).foregroundStyle(theme["outline"])
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.m)
        .frame(height: h)
        .background(
            RoundedRectangle(cornerRadius: T.l, style: .continuous)
                .fill(theme["surfaceContainerHigh"]).opacity(selected ? 1 : 0)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Controller

final class LauncherController {
    let model = LauncherModel()
    let panel: Panel<LauncherView>
    private var sub: Any?

    init(screen: NSScreen) {
        let maxDepth = LauncherView.depth(rows: LauncherModel.maxShown)
        let along = LauncherModel.itemWidth + 2 * LauncherView.padding
        let state = PanelState()
        let innerLeft = screen.frame.minX + T.barWidth
        let innerRight = screen.frame.maxX - T.thickness
        panel = Panel(edge: .bottom, along: along, depth: maxDepth, center: (innerLeft + innerRight) / 2,
                      screen: screen, content: LauncherView(model: model, state: state), state: state)
        model.close = { [weak self] in self?.panel.close() }
        panel.onOpen = { [weak self] in self?.model.reset() }
        panel.onKey = { [weak self] event in
            guard let self else { return false }
            switch event.keyCode {
            case 126: self.model.move(1); return true   // ↑ (list is bottom-up)
            case 125: self.model.move(-1); return true  // ↓
            case 36, 76: self.model.run(); return true  // Enter
            case 48: self.model.complete(); return true // Tab
            default: return false
            }
        }
        // Panel height follows the number of rows
        sub = model.$items.sink { [weak state] items in
            state?.depth = LauncherView.depth(rows: min(items.count, LauncherModel.maxShown))
        }
    }

    func toggle() { panel.toggle() }
}

extension LauncherModel {
    static func theme(mode: String) -> String? {
        let dir = riceRoot.appendingPathComponent("themes")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        return names.first { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name)/theme.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["mode"] as? String == mode
        }
    }
}
