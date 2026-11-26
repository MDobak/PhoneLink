import AppKit
import SwiftUI

// MARK: - Model

/// Facts about the phone. Nil shows as a dash.
struct DeviceInfo {
    // Header
    var deviceName: String?
    var model: String?
    var modelNumber: String?
    // Battery
    var level: Int?
    var status: Int?
    var plug: String?
    var currentMA: Int?
    var voltageMV: Int?
    var health: Int?
    var temperature: Double?
    var cycles: Int?
    var designMAh: Int?
    var maxCapacity: Int?
    var maxCapacityEstimated = false
    var technology: String?
    // Software
    var android: String?
    var sdk: Int?
    var oneUI: String?
    var securityPatch: String?
    var build: String?
    var kernel: String?
    var playUpdate: String?
    // Hardware
    var chip: String?
    var memTotal: Int64?
    var memAvailable: Int64?
    var storageTotal: Int64?
    var storageUsed: Int64?
    var storageFree: Int64?
    var resolution: String?
    var refreshRate: Double?
    var maxRefreshRate: Double?
    // Network
    var carrier: String?
    var networkType: String?
    var wifiName: String?
    var wifiDetails: String?
    var ipAddress: String?
    // Other
    var uptime: TimeInterval?

    var charging: Bool { status == 2 || status == 5 }

    /// Watts, when the phone reports voltage and current and is charging.
    var chargeWatts: Double? {
        guard charging, let v = voltageMV, let c = currentMA, c > 0 else { return nil }
        return Double(v) * Double(c) / 1_000_000
    }

    static let demo: DeviceInfo = {
        var i = DeviceInfo()
        i.deviceName = "Emma's Galaxy"; i.model = "Galaxy S24 Ultra"; i.modelNumber = "SM-S928B"
        i.level = 78; i.status = 2; i.plug = "USB"; i.currentMA = 2140; i.voltageMV = 4180; i.health = 2
        i.temperature = 31.4; i.cycles = 212; i.designMAh = 5000; i.maxCapacity = 96; i.technology = "Li-ion"
        i.android = "16"; i.sdk = 36; i.oneUI = "8.5"; i.securityPatch = "2026-10-01"
        i.build = "BP4A.251205.006.S928BXXS6DZJ1"; i.kernel = "6.1.145"; i.playUpdate = "2026-09-01"
        i.chip = "Snapdragon 8 Gen 3"; i.memTotal = 11_623_120_896; i.memAvailable = 4_310_000_000
        i.storageTotal = 494_000_000_000; i.storageUsed = 301_500_000_000; i.storageFree = 192_500_000_000
        i.resolution = "1440 × 3120"; i.refreshRate = 120; i.maxRefreshRate = 120
        i.carrier = "T-Mobile"; i.networkType = "5G"; i.wifiName = "Home"; i.wifiDetails = "5 GHz · Wi-Fi 6 · 576 Mb/s"
        i.ipAddress = "192.168.1.24"; i.uptime = 278_000
        return i
    }()
}

/// Reads device facts with read-only shell commands over USB or Wireless debugging.
final class DeviceInfoModel: ObservableObject {
    static let shared = DeviceInfoModel()

    @Published private(set) var info = DeviceInfo()
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var updated: Date?
    private let queue = DispatchQueue(label: "phonelink.deviceinfo")
    private var serialLoaded: String?

    func refresh() {
        if PhoneLink.isDemo { info = .demo; loaded = true; updated = Date(); return }
        guard let serial = PhoneLink.shared.adbSerial, !loading, PhoneLink.shared.route(.deviceInfo).isAvailable else { return }
        if serialLoaded != serial { info = DeviceInfo(); loaded = false }
        loading = true
        queue.async { [weak self] in
            let out = AdbManager.shell(serial, [Self.fullScript], timeout: 25)?.output
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                // The phone changed while the script ran: get the facts of the new phone.
                guard PhoneLink.shared.adbSerial == serial else { self.refresh(); return }
                guard let out else { return }
                var i = DeviceInfo()
                Self.parse(out, into: &i)
                if i.deviceName == nil, !PhoneLink.shared.phoneName.isEmpty { i.deviceName = PhoneLink.shared.phoneName }
                self.info = i
                self.loaded = true
                self.serialLoaded = serial
                self.updated = Date()
            }
        }
    }

    func refreshBattery() {
        if PhoneLink.isDemo { return }
        guard let serial = PhoneLink.shared.adbSerial, loaded, !loading, serialLoaded == serial else { return }
        queue.async { [weak self] in
            let out = AdbManager.shell(serial, [Self.batteryScript], timeout: 15)?.output
            DispatchQueue.main.async {
                guard let self, let out, !self.loading, self.serialLoaded == serial else { return }
                var i = self.info
                Self.parse(out, into: &i)
                self.info = i
                self.updated = Date()
            }
        }
    }

    // MARK: Shell scripts

    private static let props = [
        "ro.product.model", "ro.product.manufacturer", "ro.product.marketname", "ro.product.vendor.marketname",
        "ro.config.marketing_name", "ro.build.version.release", "ro.build.version.sdk", "ro.build.version.oneui",
        "ro.build.version.security_patch", "ro.build.display.id", "ro.soc.model", "ro.soc.manufacturer",
        "ro.board.platform", "gsm.operator.alpha", "gsm.network.type",
    ]

    private static let batteryScript = """
    echo @@battery; dumpsys battery 2>/dev/null | grep -vE '^[0-9][0-9]-[0-9][0-9] '
    echo @@cycle; cat /sys/class/power_supply/battery/cycle_count /sys/class/power_supply/battery/battery_cycle 2>/dev/null
    """

    private static let fullScript = """
        for p in \(props.joined(separator: " ")); do echo "@$p=$(getprop $p)"; done
        echo "@name=$(settings get global device_name 2>/dev/null)"
        echo "@kernel=$(uname -r)"
        \(batteryScript)
        echo @@cap; dumpsys batterystats 2>/dev/null | grep -m1 'Estimated battery capacity'
        echo @@uptime; cat /proc/uptime
        echo @@df; df -k /data 2>/dev/null | tail -1
        echo @@mem; grep -E 'MemTotal|MemAvailable' /proc/meminfo
        echo @@display; dumpsys display 2>/dev/null | grep -m1 -o 'mActiveSfDisplayMode=DisplayMode{[^}]*}'
        dumpsys display 2>/dev/null | grep -m1 -o 'supportedRefreshRates \\[[^]]*\\]'
        echo @@wifi; dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo'
        echo @@ip; ip -4 addr show wlan0 2>/dev/null | grep -m1 inet
        echo @@tel; dumpsys telephony.registry 2>/dev/null | grep 'mServiceState=' | grep -m1 IN_SERVICE
        echo @@play; dumpsys package com.google.android.modulemetadata 2>/dev/null | grep -m1 versionName
        echo @@end
        """

    // MARK: Parsing

    private static func first(_ pattern: String, in s: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let range = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[range])
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != "null", t != "unknown" else { return nil }
        return t
    }

    private static func parse(_ out: String, into i: inout DeviceInfo) {
        var sections: [String: String] = [:]
        var p: [String: String] = [:]
        var current = ""
        for line in out.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if l.hasPrefix("@@") { current = String(l.dropFirst(2)); continue }
            if l.hasPrefix("@"), let eq = l.firstIndex(of: "=") {
                p[String(l[l.index(after: l.startIndex)..<eq])] = String(l[l.index(after: eq)...])
                continue
            }
            if !current.isEmpty { sections[current, default: ""] += line + "\n" }
        }

        if !p.isEmpty { parseProps(p, into: &i) }
        if let b = sections["battery"] { parseBattery(b, cycle: sections["cycle"], into: &i) }
        if let c = sections["cap"], let v = first(#"(\d+)\s*mAh"#, in: c).flatMap(Int.init), v > 0 { i.designMAh = v }
        if i.maxCapacity == nil, i.maxCapacityEstimated == false, let d = i.designMAh, let b = sections["battery"],
           let cc = first(#"(?m)^\s*Charge counter: (\d+)"#, in: b).flatMap(Double.init), let lvl = i.level, lvl >= 40, cc > 0 {
            // Estimate the full charge capacity from the charge counter (µAh) and the level.
            let full = cc / 1000 / (Double(lvl) / 100)
            i.maxCapacity = min(100, Int((full / Double(d) * 100).rounded()))
            i.maxCapacityEstimated = true
        }
        if let u = sections["uptime"], let v = u.split(separator: " ").first.flatMap({ Double($0) }) { i.uptime = v }
        if let d = sections["df"] {
            let f = d.split(whereSeparator: { $0 == " " || $0 == "\n" })
            if f.count >= 4, let t = Int64(f[1]), let u = Int64(f[2]), let a = Int64(f[3]) {
                i.storageTotal = t * 1024; i.storageUsed = u * 1024; i.storageFree = a * 1024
            }
        }
        if let m = sections["mem"] {
            i.memTotal = first(#"MemTotal:\s+(\d+)"#, in: m).flatMap(Int64.init).map { $0 * 1024 }
            i.memAvailable = first(#"MemAvailable:\s+(\d+)"#, in: m).flatMap(Int64.init).map { $0 * 1024 }
        }
        if let d = sections["display"] {
            if let w = first(#"width=(\d+)"#, in: d), let h = first(#"height=(\d+)"#, in: d) { i.resolution = "\(w) × \(h)" }
            i.refreshRate = first(#"peakRefreshRate=([\d.]+)"#, in: d).flatMap(Double.init)
            if let list = first(#"supportedRefreshRates \[([^\]]*)\]"#, in: d) {
                i.maxRefreshRate = list.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.max()
            }
        }
        if let w = sections["wifi"] { parseWifi(w, into: &i) }
        if i.ipAddress == nil, let ip = sections["ip"], let v = first(#"inet ([\d.]+)"#, in: ip) { i.ipAddress = v }
        if let t = sections["tel"] { parseTelephony(t, props: p, into: &i) }
        if let pl = sections["play"], let v = first(#"versionName=(\d{4}-\d{2}-\d{2})"#, in: pl) ?? first(#"versionName=(\S+)"#, in: pl) {
            i.playUpdate = v
        }
    }

    private static func parseProps(_ p: [String: String], into i: inout DeviceInfo) {
        i.modelNumber = nonEmpty(p["ro.product.model"])
        i.model = nonEmpty(p["ro.product.marketname"]) ?? nonEmpty(p["ro.product.vendor.marketname"])
            ?? nonEmpty(p["ro.config.marketing_name"]) ?? i.modelNumber.flatMap(friendlyModel) ?? i.modelNumber
        if let n = nonEmpty(p["name"]) { i.deviceName = n }
        i.android = nonEmpty(p["ro.build.version.release"])
        i.sdk = nonEmpty(p["ro.build.version.sdk"]).flatMap { Int($0) }
        if let v = nonEmpty(p["ro.build.version.oneui"]).flatMap({ Int($0) }), v > 0 {
            let major = v / 10000, minor = (v / 100) % 100, patch = v % 100
            i.oneUI = patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
        }
        i.securityPatch = nonEmpty(p["ro.build.version.security_patch"])
        i.build = nonEmpty(p["ro.build.display.id"])
        if let k = nonEmpty(p["kernel"]) { i.kernel = k.split(separator: "-").first.map(String.init) ?? k }
        let soc = nonEmpty(p["ro.soc.model"])
        let platform = nonEmpty(p["ro.board.platform"])
        if let soc, let name = chipNames[soc.uppercased()] { i.chip = name }
        else if let soc { i.chip = [nonEmpty(p["ro.soc.manufacturer"]).map { $0 == "QTI" ? "Qualcomm" : $0 }, soc].compactMap { $0 }.joined(separator: " ") }
        else { i.chip = platform }
        if let c = nonEmpty(p["gsm.operator.alpha"]) {
            let names = c.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var unique: [String] = []
            for n in names where !unique.contains(n) { unique.append(n) }
            i.carrier = unique.isEmpty ? nil : unique.joined(separator: ", ")
        }
    }

    private static func parseBattery(_ b: String, cycle: String?, into i: inout DeviceInfo) {
        func int(_ key: String) -> Int? { first("(?m)^\\s*\(key): (-?\\d+)", in: b).flatMap { Int($0) } }
        func bool(_ key: String) -> Bool { first("(?m)^\\s*\(key): (\\w+)", in: b) == "true" }
        if let l = int("level"), let s = int("scale"), s > 0 { i.level = l * 100 / s }
        i.status = int("status")
        i.health = int("health")
        i.voltageMV = int("voltage")
        i.temperature = int("temperature").map { Double($0) / 10 }
        i.currentMA = int("current now")
        i.technology = first(#"(?m)^\s*technology: (\S+)"#, in: b)
        i.plug = bool("AC powered") ? "Power adapter" : bool("USB powered") ? "USB" : bool("Wireless powered") ? "Wireless"
            : bool("Dock powered") ? "Dock" : nil
        // Samsung: the battery health in percent and the total discharge in percent (100 = one cycle).
        if let a = first(#"mSavedBatteryAsoc: \[(\d+)\]"#, in: b).flatMap(Int.init), a > 0, a <= 100 {
            i.maxCapacity = a; i.maxCapacityEstimated = false
        }
        if let c = cycle?.split(separator: "\n").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }).first(where: { $0 > 0 }) {
            i.cycles = c
        } else if let c = first(#"(?mi)^\s*cycle.?count: (\d+)"#, in: b).flatMap(Int.init), c > 0 {
            i.cycles = c
        } else if let u = first(#"mSavedBatteryUsage: \[(\d+)\]"#, in: b).flatMap(Int.init), u > 0 {
            i.cycles = u / 100
        }
    }

    private static func parseWifi(_ w: String, into i: inout DeviceInfo) {
        guard w.contains("COMPLETED") else { return }
        if let s = first(#"SSID: "([^"]*)""#, in: w), !s.isEmpty { i.wifiName = s }
        if let ip = first(#"IP: /([\d.]+)"#, in: w) { i.ipAddress = ip }
        var parts: [String] = []
        if let f = first(#"Frequency: (\d+)MHz"#, in: w).flatMap(Int.init) {
            parts.append(f >= 5925 ? "6 GHz" : f >= 4900 ? "5 GHz" : "2.4 GHz")
        }
        if let std = first(#"Wi-Fi standard: (\w+)"#, in: w) {
            let names = ["11be": "Wi-Fi 7", "11ax": "Wi-Fi 6", "11ac": "Wi-Fi 5", "11n": "Wi-Fi 4"]
            if let n = names[std] { parts.append(n) }
        }
        if let s = first(#"Rx Link speed: (\d+)Mbps"#, in: w) ?? first(#"Link speed: (\d+)Mbps"#, in: w) { parts.append("\(s) Mb/s") }
        i.wifiDetails = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func parseTelephony(_ t: String, props p: [String: String], into i: inout DeviceInfo) {
        if i.carrier == nil, let c = first(#"mOperatorAlphaShort=([^,]+)"#, in: t) { i.carrier = c }
        let data = first(#"getRilDataRadioTechnology=\d+\((\w+)\)"#, in: t)
        let voice = first(#"getRilVoiceRadioTechnology=\d+\((\w+)\)"#, in: t)
        var rat = data
        if rat == nil || rat == "IWLAN" || rat == "Unknown" { rat = voice }
        var name = rat.flatMap(networkName)
        if name == "LTE", t.contains("nrState=CONNECTED") { name = "5G" }
        if name == nil, let g = nonEmpty(p["gsm.network.type"])?.split(separator: ",").first { name = networkName(String(g)) }
        i.networkType = name
    }

    private static func networkName(_ rat: String) -> String? {
        switch rat.uppercased() {
        case "NR": return "5G"
        case "LTE", "LTE_CA": return "LTE"
        case "HSPAP", "HSPA", "HSDPA", "HSUPA", "UMTS", "TD_SCDMA", "EVDO_0", "EVDO_A", "EVDO_B", "EHRPD": return "3G"
        case "EDGE", "GPRS", "GSM", "1XRTT", "CDMA", "IS95A", "IS95B": return "2G"
        default: return nil
        }
    }

    private static let chipNames = [
        "SM8750": "Snapdragon 8 Elite", "SM8650": "Snapdragon 8 Gen 3", "SM8635": "Snapdragon 8s Gen 3",
        "SM8550": "Snapdragon 8 Gen 2", "SM8475": "Snapdragon 8+ Gen 1", "SM8450": "Snapdragon 8 Gen 1",
        "SM8350": "Snapdragon 888", "SM8250": "Snapdragon 865", "S5E9945": "Exynos 2400", "S5E9955": "Exynos 2500",
        "S5E9925": "Exynos 2200", "S5E8845": "Exynos 1480", "S5E8835": "Exynos 1380",
    ]

    private static func friendlyModel(_ m: String) -> String? {
        let names: [(String, String)] = [
            ("SM-S938", "Galaxy S25 Ultra"), ("SM-S937", "Galaxy S25 Edge"), ("SM-S936", "Galaxy S25+"), ("SM-S931", "Galaxy S25"),
            ("SM-S928", "Galaxy S24 Ultra"), ("SM-S926", "Galaxy S24+"), ("SM-S921", "Galaxy S24"), ("SM-S721", "Galaxy S24 FE"),
            ("SM-S918", "Galaxy S23 Ultra"), ("SM-S916", "Galaxy S23+"), ("SM-S911", "Galaxy S23"), ("SM-S711", "Galaxy S23 FE"),
            ("SM-F966", "Galaxy Z Fold7"), ("SM-F766", "Galaxy Z Flip7"), ("SM-F956", "Galaxy Z Fold6"), ("SM-F741", "Galaxy Z Flip6"),
            ("SM-F946", "Galaxy Z Fold5"), ("SM-F731", "Galaxy Z Flip5"), ("SM-A566", "Galaxy A56"), ("SM-A556", "Galaxy A55"),
            ("SM-A366", "Galaxy A36"), ("SM-A356", "Galaxy A35"),
        ]
        return names.first { m.uppercased().hasPrefix($0.0) }?.1
    }
}

// MARK: - Formatting

private enum Fmt {
    static let dash = "—"

    static func bytes(_ v: Int64?) -> String {
        guard let v else { return dash }
        return ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    /// Marketing memory size (for example 12 GB) from the total the kernel can use.
    static func ramSize(_ v: Int64) -> String {
        let gb = Double(v) / 1_073_741_824
        let sizes: [Double] = [1, 1.5, 2, 3, 4, 6, 8, 10, 12, 16, 18, 20, 24, 32, 64]
        let s = sizes.first { $0 >= gb } ?? gb.rounded(.up)
        return s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s)) GB" : "\(s) GB"
    }

    static func temperature(_ c: Double) -> String {
        Measurement(value: c, unit: UnitTemperature.celsius).formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func uptime(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        return f.string(from: t) ?? dash
    }

    static func hz(_ v: Double) -> String { "\(Int(v.rounded())) Hz" }
}

// MARK: - Views

struct DeviceSummary: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var model = DeviceInfoModel.shared

    var body: some View {
        let i = model.info
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "smartphone")
                .font(.system(size: 96, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(i.deviceName ?? (link.phoneName.isEmpty ? "Phone" : link.phoneName))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let m = i.model {
                Text(m).font(.body).foregroundStyle(.secondary)
            }
            if let n = i.modelNumber, n != i.model {
                Text(n).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            if let a = i.android {
                Text(["Android \(a)", i.oneUI.map { "One UI \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
            if let u = model.updated {
                Text("Updated \(u.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Device")
        .overlay { if model.loading && !model.loaded { ProgressView().controlSize(.small).offset(y: 120) } }
    }
}

struct DeviceDetail: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var features = PhoneFeatures.shared
    @ObservedObject private var model = DeviceInfoModel.shared
    private let dash = Fmt.dash

    var body: some View {
        Group {
            if let reason = features.reason(.deviceInfo) {
                ContentUnavailableView {
                    Label("Device Information Not Available", systemImage: "smartphone")
                } description: {
                    Text(reason)
                }
            } else {
                form
            }
        }
        .navigationTitle("Device")
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(model.loading || !features.available(.deviceInfo))
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: link.adbSerial) { _, s in if s != nil { model.refresh() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                model.refreshBattery()
            }
        }
    }

    private var form: some View {
        let i = model.info
        return Form {
            Section("Battery") {
                LabeledContent("Level") {
                    HStack(spacing: 6) {
                        if let l = i.level {
                            Image(systemName: batterySymbol(level: l, charging: i.charging))
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)
                            Text("\(l)%").monospacedDigit()
                        } else { Text(dash) }
                    }
                }
                LabeledContent("State", value: stateText(i))
                if let w = i.chargeWatts {
                    LabeledContent("Charging Power", value: Measurement(value: w, unit: UnitPower.watts).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))))
                }
                LabeledContent("Condition", value: healthText(i.health))
                LabeledContent("Maximum Capacity") {
                    if let m = i.maxCapacity {
                        Text(i.maxCapacityEstimated ? "About \(m)%" : "\(m)%").monospacedDigit()
                    } else { Text(dash) }
                }
                .help("The capacity of the battery compared to when it was new.")
                LabeledContent("Cycle Count", value: i.cycles.map { "\($0)" } ?? dash)
                LabeledContent("Design Capacity", value: i.designMAh.map { "\($0.formatted()) mAh" } ?? dash)
                LabeledContent("Temperature", value: i.temperature.map(Fmt.temperature) ?? dash)
                LabeledContent("Voltage", value: i.voltageMV.map { Measurement(value: Double($0) / 1000, unit: UnitElectricPotentialDifference.volts).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(2)))) } ?? dash)
            }

            Section("Software") {
                LabeledContent("Android Version", value: i.android.map { v in i.sdk.map { "\(v) (API \($0))" } ?? v } ?? dash)
                if i.oneUI != nil || i.modelNumber?.hasPrefix("SM-") == true {
                    LabeledContent("One UI Version", value: i.oneUI ?? dash)
                }
                LabeledContent("Security Update", value: patchText(i.securityPatch))
                LabeledContent("Google Play System Update", value: patchText(i.playUpdate))
                LabeledContent("Build Number") { Text(i.build ?? dash).textSelection(.enabled) }
                LabeledContent("Kernel Version", value: i.kernel ?? dash)
            }

            Section("Hardware") {
                LabeledContent("Chip", value: i.chip ?? dash)
                LabeledContent("Memory") {
                    if let t = i.memTotal {
                        Text(i.memAvailable.map { "\(Fmt.ramSize(t)) (\(Fmt.bytes($0)) available)" } ?? Fmt.ramSize(t))
                    } else { Text(dash) }
                }
                LabeledContent("Display") {
                    if let r = i.resolution {
                        Text(i.maxRefreshRate.map { "\(r), up to \(Fmt.hz($0))" } ?? r)
                    } else { Text(dash) }
                }
                LabeledContent("Refresh Rate Now", value: i.refreshRate.map(Fmt.hz) ?? dash)
                storage(i)
            }

            Section("Network") {
                LabeledContent("Carrier", value: i.carrier ?? dash)
                LabeledContent("Mobile Network", value: i.networkType ?? dash)
                LabeledContent("Wi-Fi") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(i.wifiName ?? dash)
                        if let d = i.wifiDetails { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                LabeledContent("IP Address") { Text(i.ipAddress ?? dash).textSelection(.enabled) }
            }

            Section("Other") {
                LabeledContent("Time Since Restart", value: i.uptime.map(Fmt.uptime) ?? dash)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func storage(_ i: DeviceInfo) -> some View {
        if let t = i.storageTotal, let u = i.storageUsed, t > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Storage")
                    Spacer()
                    Text("\(Fmt.bytes(i.storageFree ?? (t - u))) available of \(Fmt.bytes(t))")
                        .foregroundStyle(.secondary)
                }
                Gauge(value: Double(min(u, t)), in: 0...Double(t)) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(Double(u) / Double(t) > 0.9 ? .orange : .accentColor)
                    .accessibilityLabel("Storage used")
                    .accessibilityValue("\(Fmt.bytes(u)) used of \(Fmt.bytes(t))")
                Text("\(Fmt.bytes(u)) used").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent("Storage", value: dash)
        }
    }

    private func stateText(_ i: DeviceInfo) -> String {
        let s: String
        switch i.status {
        case 2: s = "Charging"
        case 3: s = "On battery"
        case 4: s = "Plugged in, not charging"
        case 5: s = "Fully charged"
        default: return dash
        }
        if let p = i.plug, i.status != 3 { return "\(s) (\(p))" }
        return s
    }

    private func healthText(_ h: Int?) -> String {
        switch h {
        case 2: return "Good"
        case 3: return "Overheating"
        case 4: return "Dead"
        case 5: return "Over voltage"
        case 6: return "Failure"
        case 7: return "Too cold"
        default: return dash
        }
    }

    private static let patchDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func patchText(_ s: String?) -> String {
        guard let s else { return dash }
        guard let d = Self.patchDate.date(from: s) else { return s }
        return d.formatted(.dateTime.day().month(.wide).year())
    }
}
