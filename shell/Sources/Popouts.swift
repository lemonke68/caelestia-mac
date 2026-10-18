// Wi-Fi and Bluetooth popouts under SketchyBar's icons, after caelestia
// modules/bar/popouts (Network.qml, Bluetooth.qml, networkWidth 320): a power switch and
// the networks / paired devices; click one to connect. SketchyBar's click_script runs
// `rice-shell popout wifi|bluetooth <x>` with the icon's centre.

import AppKit
import Combine
import CoreLocation
import CoreWLAN
import IOBluetooth
import SwiftUI

// MARK: - Wi-Fi

struct WiFiNet: Identifiable, Hashable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int
    let secure: Bool
    let saved: Bool
}

final class WiFiService: ObservableObject {
    static let shared = WiFiService()

    @Published private(set) var power = false
    @Published private(set) var current: String?
    @Published private(set) var networks: [WiFiNet] = []
    @Published private(set) var scanning = false
    @Published private(set) var busy: String?
    @Published var askPassword: String?
    @Published private(set) var error: String?
    @Published private(set) var namesHidden = false  // no Location permission → SSIDs come back nil

    private let queue = DispatchQueue(label: "rice.wifi")
    private var lastScan: Set<CWNetwork> = []
    private var iface: CWInterface? { CWWiFiClient.shared().interface() }

    func refresh() {
        power = iface?.powerOn() ?? false
        current = iface?.ssid()
    }

    func open() {
        error = nil
        askPassword = nil
        LocationService.shared.requestAccess()
        refresh()
        scan()
    }

    func scan() {
        guard let iface, iface.powerOn() else { networks = []; return }
        scanning = true
        queue.async {
            let found = (try? iface.scanForNetworks(withSSID: nil)) ?? []
            let profiles = (iface.configuration()?.networkProfiles.array as? [CWNetworkProfile]) ?? []
            let saved = Set(profiles.compactMap(\.ssid))
            var best: [String: CWNetwork] = [:]
            var hidden = 0
            for n in found {
                guard let ssid = n.ssid, !ssid.isEmpty else { hidden += 1; continue }
                if let b = best[ssid], b.rssiValue >= n.rssiValue { continue }
                best[ssid] = n
            }
            let current = iface.ssid()
            let nets = best.values.map {
                WiFiNet(ssid: $0.ssid!, rssi: $0.rssiValue, secure: !$0.supportsSecurity(.none), saved: saved.contains($0.ssid!))
            }.sorted {
                if ($0.ssid == current) != ($1.ssid == current) { return $0.ssid == current }
                if $0.saved != $1.saved { return $0.saved }
                return $0.rssi > $1.rssi
            }
            DispatchQueue.main.async {
                self.lastScan = found
                self.networks = nets
                self.current = current
                self.namesHidden = nets.isEmpty && hidden > 0
                self.scanning = false
            }
        }
    }

    func setPower(_ on: Bool) {
        try? iface?.setPower(on)
        power = on
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh(); self.scan() }
        } else {
            networks = []
            current = nil
        }
    }

    func connect(_ net: WiFiNet, password: String? = nil) {
        guard net.ssid != current else { return }
        guard let iface, let target = lastScan.first(where: { $0.ssid == net.ssid }) else { return }
        // Open networks and saved ones (password in the keychain) connect straight away
        if net.secure && !net.saved && password == nil {
            askPassword = net.ssid
            return
        }
        busy = net.ssid
        error = nil
        askPassword = nil
        queue.async {
            var failed = false
            do {
                try iface.associate(to: target, password: password)
            } catch {
                // Saved networks: let networksetup take the password from the keychain
                let out = String(data: shell("/usr/sbin/networksetup", ["-setairportnetwork", "en0", net.ssid]), encoding: .utf8) ?? ""
                failed = !out.isEmpty
            }
            DispatchQueue.main.async {
                self.busy = nil
                if failed { self.error = "Не удалось подключиться к \(net.ssid)" }
                self.refresh()
                self.scan()
            }
        }
    }
}

extension LocationService {
    /// Ask once; Wi-Fi names (and weather by location) depend on it.
    func requestAccess() {
        guard status == CLAuthorizationStatus.notDetermined.rawValue else { return }
        Task { _ = await self.current() }  // triggers the prompt
    }
}

// MARK: - Bluetooth

struct BTDevice: Identifiable, Hashable {
    let id: String  // address
    let name: String
    let connected: Bool
    let icon: String
}

final class BluetoothService: ObservableObject {
    static let shared = BluetoothService()

    @Published private(set) var power = false
    @Published private(set) var devices: [BTDevice] = []
    @Published private(set) var busy: String?

    private let queue = DispatchQueue(label: "rice.bluetooth")

    private typealias SetPower = @convention(c) (Int32) -> Void
    private static let setPowerFn: SetPower? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                     "IOBluetoothPreferenceSetControllerPowerState")
        .map { unsafeBitCast($0, to: SetPower.self) }

    func refresh() {
        power = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        devices = paired.map {
            BTDevice(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? $0.addressString ?? "Устройство",
                     connected: $0.isConnected(), icon: Self.icon($0))
        }.sorted { $0.connected != $1.connected ? $0.connected : $0.name < $1.name }
    }

    func setPower(_ on: Bool) {
        Self.setPowerFn?(on ? 1 : 0)
        power = on
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func toggle(_ d: BTDevice) {
        guard let device = IOBluetoothDevice(addressString: d.id) else { return }
        busy = d.id
        queue.async {
            if device.isConnected() { device.closeConnection() } else { device.openConnection() }
            DispatchQueue.main.async {
                self.busy = nil
                self.refresh()
            }
        }
    }

    private static func icon(_ d: IOBluetoothDevice) -> String {
        let name = (d.name ?? "").lowercased()
        if name.contains("mouse") || name.contains("мыш") { return "mouse" }
        if name.contains("keyboard") || name.contains("клав") { return "keyboard" }
        if name.contains("buds") || name.contains("airpods") || name.contains("headphone") { return "headphones" }
        switch d.deviceClassMajor {
        case 0x04: return "headphones"  // audio
        case 0x05: return d.deviceClassMinor & 0x10 != 0 ? "keyboard" : d.deviceClassMinor & 0x20 != 0 ? "mouse" : "gamepad"
        case 0x02: return "smartphone"
        case 0x01: return "computer"
        default: return "bluetooth"
        }
    }
}

// MARK: - Views

struct PopoutHeader: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let title: String
    let on: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: T.s) {
            MIcon(name: icon, size: 22, color: on ? theme["primary"] : theme["onSurfaceVariant"])
            Text(title).font(.body(T.fontLarger, .medium)).foregroundStyle(theme["onSurface"])
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: toggle))
                .toggleStyle(.switch)
                .tint(theme["primary"])
                .labelsHidden()
        }
        .frame(height: 40)
    }
}

struct PopoutRow: View {
    @ObservedObject var theme = Theme.shared
    let icon: String
    let title: String
    let subtitle: String?
    let active: Bool
    let busy: Bool
    let trailing: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: T.m) {
            MIcon(name: icon, size: 20, color: active ? theme["primary"] : theme["onSurfaceVariant"])
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.body(T.fontNormal, active ? .semibold : .regular))
                    .foregroundStyle(active ? theme["primary"] : theme["onSurface"]).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.body(T.fontSmall)).foregroundStyle(theme["outline"])
                }
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
            } else if let trailing {
                MIcon(name: trailing, size: 18, color: theme["outline"])
            }
        }
        .padding(.horizontal, T.m)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: T.m, style: .continuous)
            .fill(active ? theme["secondaryContainer"] : theme["surfaceContainerHigh"]).opacity(active || hover ? 1 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

enum PopoutSize {
    static let width: CGFloat = 320
    static let rows = 7
    static func depth(rows: Int, extra: CGFloat = 0) -> CGFloat {
        T.l + 40 + T.s + CGFloat(max(rows, 1)) * 44 + extra + T.l
    }
}

struct WiFiPopout: View {
    @ObservedObject var wifi = WiFiService.shared
    @ObservedObject var theme = Theme.shared
    @State private var password = ""

    private func signal(_ rssi: Int) -> String {
        let s = max(0, min(100, (rssi + 100) * 2))
        return s >= 80 ? "signal_wifi_4_bar" : s >= 60 ? "network_wifi_3_bar"
            : s >= 40 ? "network_wifi_2_bar" : s >= 20 ? "network_wifi_1_bar" : "signal_wifi_0_bar"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s) {
            PopoutHeader(icon: wifi.power ? "wifi" : "wifi_off", title: "Wi-Fi", on: wifi.power) { wifi.setPower($0) }
            if !wifi.power {
                Text("Wi-Fi выключен").font(.body(T.fontNormal)).foregroundStyle(theme["outline"]).frame(height: 44)
            } else if wifi.namesHidden {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS скрывает названия сетей без доступа к геолокации.")
                        .font(.body(T.fontSmall)).foregroundStyle(theme["onSurfaceVariant"])
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Открыть настройки геолокации").font(.body(T.fontSmall, .medium)).foregroundStyle(theme["primary"])
                        .onTapGesture {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                        }
                }
                .frame(height: 44)
            } else if wifi.networks.isEmpty {
                HStack(spacing: T.s) {
                    ProgressView().controlSize(.small)
                    Text("Поиск сетей…").font(.body(T.fontNormal)).foregroundStyle(theme["outline"])
                }
                .frame(height: 44)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(wifi.networks) { net in
                            PopoutRow(icon: signal(net.rssi), title: net.ssid,
                                      subtitle: net.ssid == wifi.current ? "Подключено" : net.saved ? "Сохранена" : nil,
                                      active: net.ssid == wifi.current, busy: wifi.busy == net.ssid,
                                      trailing: net.secure ? "lock" : nil) { wifi.connect(net) }
                        }
                    }
                }
            }
            if let ssid = wifi.askPassword {
                HStack(spacing: T.s) {
                    SecureField("Пароль для \(ssid)", text: $password)
                        .textFieldStyle(.plain)
                        .font(.body(T.fontNormal))
                        .onSubmit { connectWithPassword(ssid) }
                    MIcon(name: "arrow_forward", size: 20, color: theme["primary"])
                        .onTapGesture { connectWithPassword(ssid) }
                }
                .padding(.horizontal, T.m)
                .frame(height: 40)
                .background(Capsule().fill(theme["surfaceContainer"]))
            }
            if let error = wifi.error {
                Text(error).font(.body(T.fontSmall)).foregroundStyle(theme["error"])
            }
        }
        .padding(T.l)
    }

    private func connectWithPassword(_ ssid: String) {
        guard let net = wifi.networks.first(where: { $0.ssid == ssid }) else { return }
        wifi.connect(net, password: password)
        password = ""
    }
}

struct BluetoothPopout: View {
    @ObservedObject var bt = BluetoothService.shared
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: T.s) {
            PopoutHeader(icon: bt.power ? "bluetooth" : "bluetooth_disabled", title: "Bluetooth", on: bt.power) { bt.setPower($0) }
            if !bt.power {
                Text("Bluetooth выключен").font(.body(T.fontNormal)).foregroundStyle(theme["outline"]).frame(height: 44)
            } else if bt.devices.isEmpty {
                Text("Нет сопряжённых устройств").font(.body(T.fontNormal)).foregroundStyle(theme["outline"]).frame(height: 44)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(bt.devices) { d in
                            PopoutRow(icon: d.icon, title: d.name, subtitle: d.connected ? "Подключено" : nil,
                                      active: d.connected, busy: bt.busy == d.id,
                                      trailing: d.connected ? "link_off" : "link") { bt.toggle(d) }
                        }
                    }
                }
            }
        }
        .padding(T.l)
    }
}

// MARK: - Controller

final class PopoutController {
    private let screen: NSScreen
    private var panel: Panel<AnyView>?
    private var kind: String?
    private var closedAt = Date.distantPast
    private var subs: [Any] = []

    init(screen: NSScreen) { self.screen = screen }

    /// `x` is the clicked SketchyBar item's centre in screen coordinates.
    func toggle(_ kind: String, x: CGFloat) {
        if let panel, panel.isOpen {
            let same = self.kind == kind
            panel.close()
            if same { return }
        }
        // The click that closed the popout (global monitor) must not reopen it right away
        if self.kind == kind && Date().timeIntervalSince(closedAt) < 0.4 { return }

        let state = PanelState()
        let maxDepth = PopoutSize.depth(rows: PopoutSize.rows, extra: 70)
        let along = PopoutSize.width
        let half = along / 2 + T.borderRounding
        let center = min(max(x, screen.frame.minX + T.barWidth + half), screen.frame.maxX - T.thickness - half)
        let content: AnyView
        subs = []
        switch kind {
        case "wifi":
            let wifi = WiFiService.shared
            wifi.open()
            content = AnyView(WiFiPopout())
            let update = {
                let rows = wifi.power ? max(1, min(wifi.networks.count, PopoutSize.rows)) : 1
                let extra: CGFloat = (wifi.askPassword != nil ? 48 : 0) + (wifi.error != nil ? 20 : 0)
                state.depth = PopoutSize.depth(rows: rows, extra: extra)
            }
            update()
            subs.append(wifi.objectWillChange.sink { DispatchQueue.main.async(execute: update) })
        case "bluetooth":
            let bt = BluetoothService.shared
            bt.refresh()
            content = AnyView(BluetoothPopout())
            let update = {
                state.depth = PopoutSize.depth(rows: bt.power ? max(1, min(bt.devices.count, PopoutSize.rows)) : 1)
            }
            update()
            subs.append(bt.objectWillChange.sink { DispatchQueue.main.async(execute: update) })
        default:
            return
        }
        let p = Panel(edge: .top, along: along, depth: maxDepth, center: center, screen: screen,
                      content: content, state: state)
        p.onClose = { [weak self] in self?.closedAt = Date() }
        panel = p
        self.kind = kind
        p.open(activate: true)
    }
}
