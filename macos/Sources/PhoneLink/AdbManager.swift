import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import SwiftUI

struct AdbDevice: Identifiable, Equatable {
    enum State: Equatable { case ready, unauthorized, offline }
    let serial: String
    let state: State
    let model: String
    /// False for Wi-Fi (wireless debugging or "adb tcpip").
    let usb: Bool
    var id: String { serial }
    var displayModel: String { model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: "-") }
}

struct AdbService: Equatable {
    let name: String
    let type: String
    let address: String
}

/// Finds the linked phone in adb, keeps wireless debugging connected, pairs devices and sets up the phone.
final class AdbManager: ObservableObject {
    static let shared = AdbManager()
    static let package = "com.mdobak.phonelink"

    @Published private(set) var adbPath: String?
    @Published private(set) var adbVersion: String?
    @Published private(set) var devices: [AdbDevice] = []
    /// The phone with the session token, else the phone chosen for use without the phone app.
    @Published private(set) var linkedSerial: String?
    @Published private(set) var otherSerials: Set<String> = []
    @Published private(set) var busy: SetupItem?
    @Published private(set) var setupErrors: [SetupItem: String] = [:]

    private var token: String?
    /// serial -> token found on it. A different token means a different phone.
    private var verified: [String: String] = [:]
    /// Avoids re-checking other phones every few seconds.
    private var rejected: [String: Date] = [:]
    private let queue = DispatchQueue(label: "phonelink.adb")
    private var lastAutoConnect = Date.distantPast

    init() { findAdb() }

    private static let defaultPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/opt/local/bin/adb",
                               NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
                               NSHomeDirectory() + "/platform-tools/adb"]

    static var path: String? {
        if let p = UserDefaults.standard.string(forKey: "adbPath"), FileManager.default.isExecutableFile(atPath: p) { return p }
        return defaultPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func findAdb() {
        let p = Self.path
        DispatchQueue.global(qos: .utility).async {
            let v = p.flatMap { _ in Self.run(["version"], timeout: 5)?.output }
                .flatMap { $0.split(separator: "\n").first { $0.hasPrefix("Version ") } }
                .map { String($0.dropFirst(8)).split(separator: "-").first.map(String.init) ?? "" }
            DispatchQueue.main.async { self.adbPath = p; self.adbVersion = v }
        }
    }

    @MainActor func chooseAdb() {
        let panel = NSOpenPanel()
        panel.message = "Choose the platform-tools folder."
        panel.prompt = "Use"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.hasDirectoryPath { url.appendPathComponent("adb") }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            PhoneLink.shared.banner = "This folder does not contain Android Platform-Tools. Choose the platform-tools folder."
            return
        }
        UserDefaults.standard.set(url.path, forKey: "adbPath")
        findAdb()
        // refreshAdb does nothing when no feature uses debugging.
        if PhoneRouter.usesDebugging { PhoneLink.shared.refreshAdb() } else { refresh() }
    }

    struct Result { let status: Int32; let output: String }

    /// Blocks; do not call on the main thread. Returns nil if adb did not start or timed out.
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 15) -> Result? {
        AdbProcess().run(args, timeout: timeout)
    }

    static func shell(_ serial: String, _ args: [String], timeout: TimeInterval = 15) -> Result? {
        run(["-s", serial, "shell"] + args, timeout: timeout)
    }

    /// Quotes one argument for the phone shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func listDevices() -> [AdbDevice] {
        guard let out = run(["devices", "-l"], timeout: 8)?.output else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let state: AdbDevice.State
            switch parts[1] {
            case "device": state = .ready
            case "unauthorized": state = .unauthorized
            default: state = .offline
            }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? ""
            return AdbDevice(serial: String(parts[0]), state: state, model: model, usb: parts.contains { $0.hasPrefix("usb:") })
        }
    }

    static func mdnsServices() -> [AdbService] {
        guard let out = run(["mdns", "services"], timeout: 8)?.output else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard p.count >= 3, p[1].hasPrefix("_adb") else { return nil }
            return AdbService(name: String(p[0]), type: String(p[1]).trimmingCharacters(in: CharacterSet(charactersIn: ".")), address: String(p[2]))
        }
    }

    func sessionStarted(token: String) {
        queue.async { self.token = token; self.verified = [:]; self.rejected = [:] }
    }

    /// ro.serialno of the last session's phone, used to reach it over adb while the session is down.
    /// Safe because the session handshake only accepts the paired phone.
    static var pairedPhoneID: String? { UserDefaults.standard.string(forKey: "pairedPhoneID") }

    func sessionEnded() {
        queue.async { self.token = nil; self.verified = [:]; self.rejected = [:] }
        DispatchQueue.main.async { self.linkedSerial = nil; self.otherSerials = [] }
    }

    /// A device is the linked phone only if its Phone Link has this session's token.
    /// The model name only narrows which devices to check.
    func refresh(model: String = "", done: ((_ linked: String?, _ direct: String?) -> Void)? = nil) {
        queue.async {
            var list = Self.path == nil ? [] : Self.listDevices()
            if UserDefaults.standard.bool(forKey: "adbAutoConnect"), Date().timeIntervalSince(self.lastAutoConnect) > 30 {
                self.lastAutoConnect = Date()
                if self.autoConnect(known: list) { list = Self.listDevices() }
            }
            var linked: [AdbDevice] = []
            var others = Set<String>()
            let want = Self.norm(model)
            for d in list where d.state == .ready {
                guard let token = self.token else { break }
                if let t = self.verified[d.serial] {
                    if t == token { linked.append(d) } else { others.insert(d.serial) }
                    continue
                }
                if !want.isEmpty, !d.model.isEmpty, Self.norm(d.model) != want { others.insert(d.serial); continue }
                if let r = self.rejected[d.serial], Date().timeIntervalSince(r) < 30 { others.insert(d.serial); continue }
                let found = Self.readToken(d.serial)
                if found == token { self.verified[d.serial] = token; linked.append(d) }
                else {
                    if let found { self.verified[d.serial] = found } else { self.rejected[d.serial] = Date() }
                    others.insert(d.serial)
                }
            }
            // A phone on both cable and Wi-Fi shows up twice. The cable is faster.
            let best = linked.first { $0.usb } ?? linked.first
            let direct = self.findDirect(&list)
            if let direct { others.remove(direct.serial) }
            let inUse = best ?? direct
            if let best {
                let s = self.serialNumbers[best.serial] ?? Self.serialNumber(best.serial)
                if let s, !s.isEmpty {
                    self.serialNumbers[best.serial] = s
                    if Self.pairedPhoneID != s { UserDefaults.standard.set(s, forKey: "pairedPhoneID") }
                }
            }
            let known = Set(list.map(\.serial))
            self.verified = self.verified.filter { known.contains($0.key) }
            self.serialNumbers = self.serialNumbers.filter { known.contains($0.key) }
            if let best, !best.usb, let host = best.serial.split(separator: ":").first, best.serial.contains(":") {
                Self.remember(host: String(host))
            }
            DispatchQueue.main.async {
                if self.devices != list { self.devices = list }
                if self.linkedSerial != inUse?.serial { self.linkedSerial = inUse?.serial }
                if self.otherSerials != others { self.otherSerials = others }
                done?(best?.serial, direct?.serial)
            }
        }
    }

    /// Moves the local ends of adb forwards, so that a second copy of the app (the screenshot tool) can run beside the first.
    static let portOffset = UInt16(ProcessInfo.processInfo.environment["PHONELINK_ADB_PORT_OFFSET"] ?? "") ?? 0

    static var directPhoneID: String? { UserDefaults.standard.string(forKey: "directPhone") }
    /// Only devices with this model get the serial number check.
    static var directPhoneModel: String { UserDefaults.standard.string(forKey: "directPhoneModel") ?? "" }
    static var directPhoneName: String? { UserDefaults.standard.string(forKey: "directPhoneName") }

    /// adb serial -> ro.serialno. The adb serial of a wireless debugging connection changes. On queue.
    private var serialNumbers: [String: String] = [:]
    private var lastDirectConnect = Date.distantPast

    /// Runs on the adb queue. Only talks to devices with the same model, and only connects to the
    /// wireless debugging service with the chosen phone's serial number.
    private func findDirect(_ list: inout [AdbDevice]) -> AdbDevice? {
        guard let want = Self.directPhoneID, !want.isEmpty else { return nil }
        func match(_ list: [AdbDevice]) -> AdbDevice? {
            let model = Self.norm(Self.directPhoneModel)
            var found: [AdbDevice] = []
            for d in list where d.state == .ready {
                if d.serial == want || d.serial.hasPrefix("adb-\(want)-") { found.append(d); continue }
                if let s = serialNumbers[d.serial] { if s == want { found.append(d) }; continue }
                guard !model.isEmpty, Self.norm(d.model) == model else { continue }
                if let s = Self.serialNumber(d.serial) {
                    serialNumbers[d.serial] = s
                    if s == want { found.append(d) }
                }
            }
            return found.first { $0.usb } ?? found.first
        }
        if let d = match(list) { return d }
        // Wireless debugging uses a new port after a restart.
        guard Date().timeIntervalSince(lastDirectConnect) > 30 else { return nil }
        lastDirectConnect = Date()
        let have = Set(list.map(\.serial))
        let services = Self.mdnsServices().filter {
            $0.type == "_adb-tls-connect._tcp" && $0.name.hasPrefix("adb-\(want)-") && !have.contains($0.address)
        }
        guard let s = services.first, Self.run(["connect", s.address], timeout: 6)?.output.contains("connected to") == true else { return nil }
        list = Self.listDevices()
        return match(list)
    }

    private static func serialNumber(_ serial: String) -> String? {
        guard let out = shell(serial, ["getprop", "ro.serialno"], timeout: 6), out.status == 0 else { return nil }
        let s = out.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    func useWithoutApp(_ d: AdbDevice, done: @escaping (String?) -> Void) {
        queue.async {
            guard let id = Self.serialNumber(d.serial) else {
                DispatchQueue.main.async { done("The phone did not answer. Unlock it and try again.") }
                return
            }
            var name = Self.shell(d.serial, ["settings", "get", "global", "device_name"], timeout: 6)?.output
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty || name == "null" { name = d.displayModel }
            self.serialNumbers[d.serial] = id
            UserDefaults.standard.set(id, forKey: "directPhone")
            UserDefaults.standard.set(d.model, forKey: "directPhoneModel")
            UserDefaults.standard.set(name, forKey: "directPhoneName")
            DispatchQueue.main.async {
                done(nil)
                PhoneLink.shared.directPhoneChanged()
            }
        }
    }

    func stopUsingWithoutApp() {
        for k in ["directPhone", "directPhoneModel", "directPhoneName", "directCaps"] { UserDefaults.standard.removeObject(forKey: k) }
        PhoneLink.shared.directPhoneChanged()
    }

    private static let remoteApk = "/data/local/tmp/phonelink.apk"
    private static let apkLock = NSLock()
    private static var pushedApk: [String: String] = [:]
    private static let bundledApk: (url: URL, size: Int, sha: String)? = {
        guard let url = Bundle.main.url(forResource: "phonelink-agent", withExtension: "apk"),
              let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        return (url, d.count, sha)
    }()

    static var bundledAppURL: URL? { bundledApk?.url }

    /// Copies the bundled helper APK to the phone if it differs, so the helpers work without the phone app.
    /// Falls back to the installed Phone Link app. Blocks; do not call on the main thread.
    static func classpath(_ serial: String) -> String {
        let installed = "$(pm path \(package) | head -1 | cut -d: -f2)"
        guard let apk = bundledApk else { return installed }
        apkLock.lock()
        defer { apkLock.unlock() }
        if pushedApk[serial] == apk.sha { return remoteApk }
        let out = shell(serial, ["stat -c %s \(remoteApk) 2>/dev/null; sha256sum \(remoteApk) 2>/dev/null"], timeout: 10)?.output ?? ""
        let words = Set(out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).map(String.init))
        if !(words.contains(String(apk.size)) && words.contains(apk.sha)) {
            guard run(["-s", serial, "push", apk.url.path, remoteApk], timeout: 120)?.status == 0 else { return installed }
        }
        pushedApk[serial] = apk.sha
        return remoteApk
    }

    private static func norm(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }).uppercased() }

    private static func readToken(_ serial: String) -> String? {
        guard let out = shell(serial, ["dumpsys", "activity", "service", package + "/.LinkService"], timeout: 8)?.output,
              let r = out.range(of: "phonelink-token=") else { return nil }
        let t = out[r.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return t.isEmpty || t == "none" ? nil : String(t)
    }

    var linkedDevice: AdbDevice? { devices.first { $0.serial == linkedSerial } }

    func loadDemo() {
        devices = [AdbDevice(serial: "R5CX21DEMO", state: .ready, model: "SM_S928B", usb: true)]
        linkedSerial = "R5CX21DEMO"
    }

    /// Only hosts that were the linked phone get "adb connect", because connecting to an unknown phone
    /// shows a prompt on that phone.
    private static func remember(host: String) {
        var hosts = UserDefaults.standard.stringArray(forKey: "adbKnownHosts") ?? []
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        UserDefaults.standard.set(Array(hosts.suffix(8)), forKey: "adbKnownHosts")
    }

    private func autoConnect(known: [AdbDevice]) -> Bool {
        let hosts = Set(UserDefaults.standard.stringArray(forKey: "adbKnownHosts") ?? [])
        // An offline entry (e.g. after a Wi-Fi change) can block the reconnect, so only ready devices count.
        let have = Set(known.filter { $0.state == .ready }.map(\.serial))
        let stale = known.filter { $0.state == .offline }.map(\.serial)
        var added = false
        for s in Self.mdnsServices() where !have.contains(s.address) && !have.contains(where: { $0.hasPrefix(s.name + ".") }) {
            for old in stale where old == s.address || old.hasPrefix(s.name + ".") { _ = Self.run(["disconnect", old], timeout: 3) }
            let ok: Bool
            switch s.type {
            case "_adb-tls-connect._tcp": ok = true
            case "_adb._tcp": ok = s.address.split(separator: ":").first.map { hosts.contains(String($0)) } ?? false
            default: ok = false
            }
            guard ok, let r = Self.run(["connect", s.address], timeout: 6) else { continue }
            if r.output.contains("connected to") { added = true }
        }
        return added
    }

    /// Only phones paired with this Mac accept.
    func connectWireless(done: @escaping () -> Void) {
        queue.async {
            self.lastAutoConnect = Date()
            _ = self.autoConnect(known: Self.listDevices())
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Android leaves tcpip mode when the phone restarts.
    func switchToWifi(done: @escaping (String?) -> Void) {
        guard let serial = linkedSerial, linkedDevice?.usb == true else { done("Connect the phone with a USB cable first."); return }
        queue.async {
            let ipOut = Self.shell(serial, ["ip", "-f", "inet", "addr", "show", "wlan0"])?.output ?? ""
            guard let ip = ipOut.split(separator: "\n").compactMap({ line -> String? in
                let w = line.split(separator: " ")
                guard let i = w.firstIndex(of: "inet"), i + 1 < w.count else { return nil }
                return w[i + 1].split(separator: "/").first.map(String.init)
            }).first else { DispatchQueue.main.async { done("The phone is not on a Wi-Fi network.") }; return }
            guard Self.run(["-s", serial, "tcpip", "5555"], timeout: 10)?.status == 0 else {
                DispatchQueue.main.async { done("adb could not start wireless mode on the phone.") }; return
            }
            Thread.sleep(forTimeInterval: 2)
            var ok = false
            for _ in 0..<5 where !ok {
                ok = Self.run(["connect", ip + ":5555"], timeout: 6)?.output.contains("connected to") == true
                if !ok { Thread.sleep(forTimeInterval: 1) }
            }
            if ok { Self.remember(host: ip) }
            DispatchQueue.main.async {
                done(ok ? nil : "The Mac could not connect to the phone at \(ip). Make sure that both are on the same network.")
                PhoneLink.shared.refreshAdb()
            }
        }
    }

    func pair(address: String, code: String, done: @escaping (String?) -> Void) {
        queue.async {
            let r = Self.run(["pair", address, code], timeout: 20)
            let ok = r?.output.contains("Successfully paired") == true
            if ok { self.connectAfterPairing() }
            DispatchQueue.main.async {
                done(ok ? nil : Self.pairError(r?.output))
                if ok { PhoneLink.shared.refreshAdb() }
            }
        }
    }

    private static func pairError(_ out: String?) -> String {
        guard let out, !out.isEmpty else { return "The phone did not answer. Make sure that the phone and this Mac are on the same network." }
        if out.localizedCaseInsensitiveContains("wrong password") || out.localizedCaseInsensitiveContains("protocol fault") {
            return "The code is not correct, or it expired. Get a new code on the phone."
        }
        return "Pairing failed: " + out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connectAfterPairing() {
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 1)
            lastAutoConnect = .distantPast
            if autoConnect(known: Self.listDevices()) { return }
        }
    }

    /// The phone scans the code, then advertises a pairing service with the name from the code.
    final class QRPairing: ObservableObject {
        enum Phase: Equatable { case waiting, pairing, paired, failed(String) }
        let name = "phonelink-" + String(UUID().uuidString.prefix(6))
        let password = String((0..<10).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        @Published var phase: Phase = .waiting
        private var cancelled = false

        var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

        var image: NSImage? {
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(payload.utf8)
            f.correctionLevel = "M"
            guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                  let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width / 2, height: ci.extent.height / 2))
        }

        func start() {
            DispatchQueue.global(qos: .userInitiated).async {
                let end = Date().addingTimeInterval(180)
                while !self.cancelled, Date() < end {
                    if let s = AdbManager.mdnsServices().first(where: { $0.name == self.name && $0.type == "_adb-tls-pairing._tcp" }) {
                        DispatchQueue.main.async { self.phase = .pairing }
                        AdbManager.shared.pair(address: s.address, code: self.password) { err in
                            self.phase = err.map { .failed($0) } ?? .paired
                        }
                        return
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
                if !self.cancelled { DispatchQueue.main.async { self.phase = .failed("The phone did not scan the code. Try again.") } }
            }
        }

        func cancel() { cancelled = true }
    }

    enum SetupItem: String, CaseIterable, Identifiable {
        case messages, contacts, calls, notifications, control, files, photos, sound, background, wireless
        var id: String { rawValue }

        var title: String {
            switch self {
            case .messages: "Messages"
            case .contacts: "Contacts"
            case .calls: "Calls and Call History"
            case .notifications: "Notifications"
            case .control: "Screen Control"
            case .files: "Files"
            case .photos: "Photos"
            case .sound: "Screen Sound"
            case .background: "Background Use"
            case .wireless: "Automatic Wireless Connection"
            }
        }

        var detail: String {
            switch self {
            case .messages: "Read and send SMS and MMS messages."
            case .contacts: "Show names for numbers."
            case .calls: "Make and answer calls, and see call history."
            case .notifications: "Show phone notifications on this Mac."
            case .control: "Control the phone with the mouse and keyboard."
            case .files: "Browse and copy files on the phone."
            case .photos: "Show recent photos."
            case .sound: "Play phone sound during screen sharing."
            case .background: "Keep the connection when the phone screen is off."
            case .wireless: "Turn on Wireless debugging on the same Wi-Fi network as this Mac."
            }
        }

        var symbol: String {
            switch self {
            case .messages: "message.fill"
            case .contacts: "person.crop.circle.fill"
            case .calls: "phone.fill"
            case .notifications: "bell.badge.fill"
            case .control: "cursorarrow.click.2"
            case .files: "folder.fill"
            case .photos: "photo.fill"
            case .sound: "speaker.wave.2.fill"
            case .background: "moon.fill"
            case .wireless: "wifi"
            }
        }

        var tint: Color {
            switch self {
            case .messages, .calls: .green
            case .contacts: .gray
            case .notifications: .red
            case .control: .blue
            case .files: .cyan
            case .photos: .orange
            case .sound: .pink
            case .background: .indigo
            case .wireless: .teal
            }
        }

        var permKeys: [String] {
            switch self {
            case .messages: ["sms"]
            case .contacts: ["contacts"]
            case .calls: ["phone", "callLog"]
            case .notifications: ["notifications", "postNotifications"]
            case .control: ["control"]
            case .files: ["files"]
            case .photos: ["photos"]
            case .sound: ["audio"]
            case .background: ["background"]
            case .wireless: ["adbWifi"]
            }
        }

        var grants: [String] {
            switch self {
            case .messages: ["READ_SMS", "SEND_SMS"]
            case .contacts: ["READ_CONTACTS"]
            case .calls: ["CALL_PHONE", "READ_PHONE_STATE", "READ_CALL_LOG", "ANSWER_PHONE_CALLS"]
            case .notifications: ["POST_NOTIFICATIONS"]
            case .photos: ["READ_MEDIA_IMAGES"]
            case .sound: ["RECORD_AUDIO"]
            // Same grant as PhoneLink.maybeGrantWirelessDebugging.
            case .wireless: ["WRITE_SECURE_SETTINGS"]
            default: []
            }
        }
    }

    static func isOn(_ item: SetupItem, perms: [String: Bool]) -> Bool? {
        let v = item.permKeys.map { perms[$0] }
        if v.contains(where: { $0 == false }) { return false }
        if v.contains(where: { $0 == nil }) { return nil }
        return true
    }

    func turnOn(_ items: [SetupItem]) {
        guard let serial = linkedSerial, !items.isEmpty else { return }
        queue.async {
            for item in items {
                DispatchQueue.main.async { self.busy = item; self.setupErrors[item] = nil }
                let err = Self.apply(item, serial: serial)
                DispatchQueue.main.async { self.setupErrors[item] = err }
            }
            DispatchQueue.main.async { self.busy = nil }
            // The accessibility service needs a moment to start.
            Thread.sleep(forTimeInterval: 1.5)
            PhoneLink.shared.send(["t": "status"])
        }
    }

    private static func apply(_ item: SetupItem, serial: String) -> String? {
        let pkg = package
        var cmds: [[String]] = item.grants.map { ["pm", "grant", pkg, "android.permission." + $0] }
        switch item {
        case .notifications: cmds.append(["cmd", "notification", "allow_listener", pkg + "/" + pkg + ".NotifListener"])
        case .files: cmds = [["appops", "set", "--uid", pkg, "MANAGE_EXTERNAL_STORAGE", "allow"]]
        case .background: cmds = [["dumpsys", "deviceidle", "whitelist", "+" + pkg]]
        case .control:
            let svc = pkg + "/" + pkg + ".InputService"
            guard let cur = shell(serial, ["settings", "get", "secure", "enabled_accessibility_services"])?.output
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return "The phone did not answer." }
            if !cur.split(separator: ":").contains(Substring(svc)) {
                let value = cur.isEmpty || cur == "null" ? svc : cur + ":" + svc
                cmds = [["settings", "put", "secure", "enabled_accessibility_services", value]]
            } else { cmds = [] }
            cmds.append(["settings", "put", "secure", "accessibility_enabled", "1"])
        default: break
        }
        for c in cmds {
            // "adb shell" joins arguments with spaces, so quote each one.
            guard let r = shell(serial, [c.map(quote).joined(separator: " ")]) else { return "The phone did not answer." }
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status != 0 || out.contains("Exception") || out.hasPrefix("Error") {
                if out.contains("SecurityException") || out.contains("not allowed") {
                    return "The phone blocked this change. Turn it on in Phone Link on the phone, or turn on \"USB debugging (Security settings)\" in Developer options."
                }
                return out.split(separator: "\n").first.map(String.init) ?? "The change failed."
            }
        }
        return nil
    }
}

/// A cancellable adb command. Share one instance across the steps of a transfer:
/// after cancel(), the running step stops and later steps do not start.
final class AdbProcess {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func cancel() {
        lock.lock()
        stopped = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Call off the main thread. tick runs every interval seconds for progress.
    /// Returns nil if adb did not start, timed out or was cancelled.
    func run(_ args: [String], timeout: TimeInterval? = nil, interval: TimeInterval = 0.25,
             tick: (() -> Void)? = nil) -> AdbManager.Result? {
        guard let adb = AdbManager.path else { return nil }
        // Output goes to a file because an adb server started by adb keeps a pipe open.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("phonelink-adb-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let h = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? h.close(); try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        p.standardOutput = h
        p.standardError = h
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }

        lock.lock()
        if stopped { lock.unlock(); return nil }
        do { try p.run() } catch { lock.unlock(); return nil }
        process = p
        lock.unlock()

        let end = timeout.map { Date().addingTimeInterval($0) }
        var timedOut = false
        while done.wait(timeout: .now() + interval) == .timedOut {
            if let end, Date() > end { timedOut = true; p.terminate(); done.wait(); break }
            tick?()
        }
        lock.lock(); process = nil; lock.unlock()
        if timedOut || cancelled { return nil }
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return AdbManager.Result(status: p.terminationStatus, output: text)
    }
}
