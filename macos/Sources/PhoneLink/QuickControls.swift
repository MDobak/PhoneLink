import AppKit
import Combine
import SwiftUI

enum ControlKind {
    case toggle
    /// A click cycles Sound, Vibrate, Silent.
    case ringer
    case action
}

enum ControlNeed {
    /// "controls" from the app session.
    case app
    /// "controls" from the shell helper.
    case debugging
    case appOrDebugging
    /// Older features (hotspot, Find Phone, Lock Phone) with no "controls" message.
    case feature
}

enum RingerMode: String, CaseIterable, Identifiable {
    case normal, vibrate, silent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Sound"
        case .vibrate: "Vibrate"
        case .silent: "Silent"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "bell.fill"
        case .vibrate: "iphone.gen3.radiowaves.left.and.right"
        case .silent: "bell.slash.fill"
        }
    }

    var next: RingerMode {
        switch self {
        case .normal: .vibrate
        case .vibrate: .silent
        case .silent: .normal
        }
    }
}

struct QuickControl: Identifiable, Hashable {
    let id: String
    let title: String
    /// Bluetooth has no SF Symbol; the tile draws BluetoothRune.
    let symbol: String
    var offSymbol: String? = nil
    let kind: ControlKind
    let need: ControlNeed

    static let all: [QuickControl] = [
        QuickControl(id: "dnd", title: "Do Not Disturb", symbol: "moon.fill", kind: .toggle, need: .app),
        QuickControl(id: "ringer", title: "Sound Mode", symbol: "bell.fill", kind: .ringer, need: .appOrDebugging),
        QuickControl(id: "torch", title: "Flashlight", symbol: "flashlight.on.fill", offSymbol: "flashlight.off.fill", kind: .toggle, need: .app),
        QuickControl(id: "bluetooth", title: "Bluetooth", symbol: "", kind: .toggle, need: .debugging),
        QuickControl(id: "data", title: "Mobile Data", symbol: "antenna.radiowaves.left.and.right", kind: .toggle, need: .debugging),
        QuickControl(id: "powerSaving", title: "Power Saving", symbol: "battery.25percent", kind: .toggle, need: .debugging),
        QuickControl(id: "darkMode", title: "Dark Mode", symbol: "circle.lefthalf.filled", kind: .toggle, need: .debugging),
        QuickControl(id: "location", title: "Location", symbol: "location.fill", kind: .toggle, need: .debugging),
        QuickControl(id: "rotation", title: "Auto-Rotate", symbol: "rectangle.portrait.rotate", kind: .toggle, need: .debugging),
        QuickControl(id: "hotspot", title: "Personal Hotspot", symbol: "personalhotspot", kind: .toggle, need: .feature),
        QuickControl(id: "findPhone", title: "Find Phone", symbol: "bell.and.waves.left.and.right.fill", kind: .toggle, need: .feature),
        QuickControl(id: "lock", title: "Lock Phone", symbol: "lock.fill", kind: .action, need: .feature),
    ]

    private static let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static func find(_ id: String) -> QuickControl? { byId[id] }

    static let defaultPins = ["dnd", "ringer", "findPhone", "hotspot"]
    static let maxPins = 8
}

/// UserDefaults key "pinnedControls". Demo mode does not save: the demo app shares settings with the real app.
final class ControlPins: ObservableObject {
    static let shared = ControlPins()
    private static let key = "pinnedControls"

    @Published private(set) var ids: [String]

    private init() {
        if PhoneLink.isDemo, let env = ProcessInfo.processInfo.environment["PHONELINK_DEMO_PINS"] {
            ids = env.split(separator: ",").map(String.init).filter { QuickControl.find($0) != nil }
        } else if let saved = UserDefaults.standard.stringArray(forKey: Self.key) {
            var seen = Set<String>()
            ids = Array(saved.filter { QuickControl.find($0) != nil && seen.insert($0).inserted }.prefix(QuickControl.maxPins))
        } else {
            ids = QuickControl.defaultPins
        }
    }

    var isFull: Bool { ids.count >= QuickControl.maxPins }
    var controls: [QuickControl] { ids.compactMap(QuickControl.find) }
    var others: [QuickControl] { QuickControl.all.filter { !ids.contains($0.id) } }

    func add(_ id: String) {
        guard !isFull, !ids.contains(id), QuickControl.find(id) != nil else { return }
        ids.append(id)
        save()
    }

    func remove(_ id: String) {
        ids.removeAll { $0 == id }
        save()
    }

    func move(fromOffsets from: IndexSet, toOffset to: Int) {
        ids.move(fromOffsets: from, toOffset: to)
        save()
    }

    func move(_ id: String, before target: String) {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let i = ids.firstIndex(of: id) else { return }
        let j = i + delta
        guard ids.indices.contains(j) else { return }
        ids.swapAt(i, j)
        save()
    }

    func reset() {
        ids = QuickControl.defaultPins
        if !PhoneLink.isDemo { UserDefaults.standard.removeObject(forKey: Self.key) }
    }

    private func save() {
        if !PhoneLink.isDemo { UserDefaults.standard.set(ids, forKey: Self.key) }
    }
}

enum VolumeStream: String, CaseIterable, Identifiable {
    case media, call, ring, notification, alarm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: "Media"
        case .call: "Call"
        case .ring: "Ring"
        case .notification: "Notifications"
        case .alarm: "Alarm"
        }
    }
}

/// Phone controls and volume. The app session and the shell helper each send "controls" with only what they can set now.
/// For each id the app wins if it reports it. Main thread.
final class QuickControls: ObservableObject {
    static let shared = QuickControls()

    struct Value: Equatable {
        var on: Bool?
        var mode: RingerMode?
    }

    struct Volume: Equatable {
        var level: Int
        var min: Int
        var max: Int
    }

    @Published private var items: [PhonePath: [String: Value]] = [:]
    @Published private var volumes: [PhonePath: [String: Volume]] = [:]
    /// Optimistic values: the tile changes at once, then follows the phone reply.
    @Published private var pending: [String: Value] = [:]
    @Published private var pendingVolume: [String: Int] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var status: String?
    @Published private var appReported = false
    @Published private var demoHotspot = false

    private var pendingTokens: [String: Int] = [:]
    private var nextToken = 0
    /// App errors do not carry the id, so remember the last one set per side.
    private var lastSet: [PhonePath: String] = [:]
    private var statusToken = 0
    private var pollTimer: Timer?
    private var menuOpen = false
    private var bag = Set<AnyCancellable>()

    private var link: PhoneLink { PhoneLink.shared }
    private var agent: AdbAgent { AdbAgent.shared }

    private init() {
        PhoneLink.shared.$sessionConnected.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            guard let self, !PhoneLink.isDemo else { return }
            // Ask once per session so the menu has the controls when it opens.
            if on { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }; return }
            self.items[.app] = nil
            self.volumes[.app] = nil
            self.appReported = false
        }.store(in: &bag)
        AdbAgent.shared.$ready.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            guard let self, !on, !PhoneLink.isDemo else { return }
            self.items[.shell] = nil
            self.volumes[.shell] = nil
        }.store(in: &bag)
        PhoneLink.shared.$shellCaps.map { $0.contains("controls") }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] can in
            if can { self?.refreshShell() }
        }.store(in: &bag)
    }

    // MARK: Sides

    private var appLive: Bool { PhoneLink.isDemo || link.sessionConnected }
    private var shellLive: Bool { PhoneLink.isDemo || (agent.ready && link.shellCaps.contains("controls")) }

    private func sides(_ f: PhoneFeature) -> [PhonePath] {
        switch f.choice {
        case .none: return []
        case .app: return [.app]
        case .shell: return PhoneRouter.usesDebugging ? [.shell] : [.app, .shell]
        case .auto: return [.app, .shell]
        }
    }

    private func live(_ p: PhonePath) -> Bool { p == .app ? appLive : shellLive }

    func side(for id: String) -> PhonePath? {
        sides(.quickControls).first { live($0) && items[$0]?[id] != nil }
    }

    func side(forStream s: VolumeStream) -> PhonePath? {
        sides(.volume).first { live($0) && volumes[$0]?[s.rawValue] != nil }
    }

    func value(_ id: String) -> Value? {
        if let p = pending[id] { return p }
        guard let s = side(for: id) else { return nil }
        return items[s]?[id]
    }

    var hasReportedControls: Bool { QuickControl.all.contains { side(for: $0.id) != nil } }

    func volume(_ s: VolumeStream) -> Volume? {
        guard let side = side(forStream: s), var v = volumes[side]?[s.rawValue] else { return nil }
        if let p = pendingVolume[s.rawValue] { v.level = p }
        return v
    }

    var hasVolume: Bool { VolumeStream.allCases.contains { side(forStream: $0) != nil } }

    // MARK: Tiles

    struct Tile {
        var title: String
        var symbol: String
        var on: Bool
        var value: String?
        var unavailable: String?
        var help: String
    }

    func tile(_ c: QuickControl) -> Tile {
        let reason = unavailableReason(c)
        var t = Tile(title: c.title, symbol: c.symbol, on: false, value: nil, unavailable: reason, help: c.title)
        switch c.id {
        case "ringer":
            let mode = value(c.id)?.mode ?? .normal
            t.title = reason == nil ? mode.title : "Sound"
            t.symbol = mode.symbol
            // Matches the phone: on for Sound and Vibrate.
            t.on = reason == nil && mode != .silent
            t.value = mode.title
            t.help = "Sound mode: \(mode.title). Click to change."
        case "hotspot":
            let on = PhoneLink.isDemo ? demoHotspot : (agent.hotspotOn == true || agent.sharingStarts)
            t.on = reason == nil && on
            t.value = on ? "On" : "Off"
            t.help = agent.sharingStarts ? "Connecting…" : on ? "Stop the phone hotspot" : "Start the phone hotspot and connect this Mac to it"
        case "findPhone":
            t.on = link.ringing
            t.value = link.ringing ? "Ringing" : "Off"
            t.help = link.ringing ? "Stop Ringing" : "Rings the phone at full volume, even when it is silent."
        case "lock":
            t.help = "Lock the phone"
        default:
            let on = value(c.id)?.on ?? false
            t.on = reason == nil && on
            t.value = on ? "On" : "Off"
            if !on, let off = c.offSymbol { t.symbol = off }
            t.help = "\(c.title): \(on ? "On" : "Off")"
        }
        if let reason { t.help = reason } else if let e = errors[c.id] { t.help = e }
        return t
    }

    func unavailableReason(_ c: QuickControl) -> String? {
        if PhoneLink.isDemo { return ProcessInfo.processInfo.environment["PHONELINK_DEMO_CONTROLS"] == "app" && c.need == .debugging
            ? "Needs USB or Wireless debugging." : nil }
        guard link.state == .connected else { return "The phone is not connected." }
        switch c.id {
        case "hotspot":
            if let r = link.route(.hotspot).reason { return r }
            return agent.hotspotOn == nil ? "Phone Link is starting on the phone. Try again in a moment." : nil
        case "findPhone":
            return link.path(for: .findPhone) == nil ? (link.route(.findPhone).reason ?? "Not available now.") : nil
        case "lock":
            return nil
        default:
            break
        }
        if side(for: c.id) != nil { return nil }
        let f = PhoneFeature.quickControls
        if f.isOff { return FeatureRouting.turnedOff }
        let sides = sides(f)
        let canApp = c.need != .debugging && sides.contains(.app)
        let canShell = c.need != .app && sides.contains(.shell)
        // The side runs but does not report this id.
        if canApp && appLive && appReported {
            switch c.id {
            case "dnd": return "Allow Do Not Disturb access for Phone Link on your phone."
            case "torch": return "This phone has no flashlight."
            default: if !canShell { return "Not available on this phone." }
            }
        }
        if canShell && shellLive { return "Not available on this phone." }
        if canShell && link.adbSerial != nil { return "Phone Link is starting on the phone. Try again in a moment." }
        if canApp && appLive { return "Waiting for the phone…" }
        switch c.need {
        case .debugging:
            return sides.contains(.shell) ? "Needs USB or Wireless debugging." : "Needs USB or Wireless debugging. Set Controls to Automatic in Settings > Connections."
        case .app:
            return "Open Phone Link on your phone."
        default:
            return "Open Phone Link on your phone, or connect it with USB or Wireless debugging."
        }
    }

    // MARK: Actions

    func perform(_ c: QuickControl) {
        guard unavailableReason(c) == nil else { return }
        switch c.id {
        case "hotspot":
            if PhoneLink.isDemo { demoHotspot.toggle(); return }
            HotspotControl.share(!(agent.hotspotOn == true))
        case "findPhone":
            link.ringing ? link.stopRing() : link.ring()
        case "lock":
            link.input(["t": "input.global", "action": "lock"])
        case "ringer":
            setRinger((value(c.id)?.mode ?? .normal).next)
        default:
            set(c.id, on: !(value(c.id)?.on ?? false))
        }
    }

    func set(_ id: String, on: Bool) {
        sendSet(id, ["t": "controls.set", "id": id, "on": on], Value(on: on))
    }

    func setRinger(_ mode: RingerMode) {
        sendSet("ringer", ["t": "controls.set", "id": "ringer", "mode": mode.rawValue], Value(mode: mode))
    }

    private func sendSet(_ id: String, _ j: JSON, _ v: Value) {
        guard let s = side(for: id) else { return }
        errors[id] = nil
        if PhoneLink.isDemo { items[s]?[id] = v; return }
        nextToken += 1
        let token = nextToken
        pending[id] = v
        pendingTokens[id] = token
        lastSet[s] = id
        send(j, to: s, setId: id)
        // No reply in time: revert to the reported value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.pendingTokens[id] == token else { return }
            self.pending[id] = nil
            self.pendingTokens[id] = nil
        }
    }

    /// The slider calls this at most every 120 ms while dragging.
    func setVolume(_ s: VolumeStream, _ level: Int) {
        guard let side = side(forStream: s), let v = volumes[side]?[s.rawValue] else { return }
        let level = Swift.min(Swift.max(level, v.min), v.max)
        if PhoneLink.isDemo { volumes[side]?[s.rawValue]?.level = level; return }
        pendingVolume[s.rawValue] = level
        nextToken += 1
        let token = nextToken
        pendingTokens["volume." + s.rawValue] = token
        send(["t": "volume.set", "stream": s.rawValue, "level": level], to: side, setId: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pendingTokens["volume." + s.rawValue] == token else { return }
            self.pendingVolume[s.rawValue] = nil
        }
    }

    private func send(_ j: JSON, to side: PhonePath, setId: String?) {
        switch side {
        case .app:
            link.sendAppOnly(j)
        case .shell:
            let type = j.str("t") ?? ""
            agent.request(j, timeout: 10) { [weak self] r in
                guard let self else { return }
                guard let r else {
                    if type != "controls.get" { self.failed(req: type, msg: "The phone did not answer.", from: .shell, id: setId) }
                    return
                }
                if r.str("t") == "controls" { self.received(r, from: .shell); return }
                if let e = r.str("error") ?? r.str("msg") { self.failed(req: type, msg: e, from: .shell, id: setId) }
            }
        }
    }

    // MARK: Messages from the phone

    /// For "error" replies from the app.
    static func owns(_ req: String) -> Bool { ["controls.get", "controls.set", "volume.set"].contains(req) }

    /// Replaces all values of that side.
    func received(_ j: JSON, from side: PhonePath) {
        var map: [String: Value] = [:]
        for (id, any) in (j["items"] as? JSON) ?? [:] {
            guard let o = any as? JSON else { continue }
            map[id] = Value(on: o["on"] as? Bool, mode: (o["mode"] as? String).flatMap(RingerMode.init))
        }
        var vol: [String: Volume] = [:]
        for (s, any) in (j["volume"] as? JSON) ?? [:] {
            guard let o = any as? JSON, let level = o.int("level"), let max = o.int("max"), max > 0 else { continue }
            let min = o.int("min") ?? 0
            vol[s] = Volume(level: Swift.min(Swift.max(level, min), max), min: min, max: max)
        }
        items[side] = map
        volumes[side] = vol
        if side == .app { appReported = true }
        // An optimistic value ends when the phone reports it.
        for (id, v) in pending where self.side(for: id) == side && map[id] == v {
            pending[id] = nil
            pendingTokens[id] = nil
        }
        for (s, level) in pendingVolume where self.side(forStream: VolumeStream(rawValue: s) ?? .media) == side && vol[s]?.level == level {
            pendingVolume[s] = nil
        }
    }

    func failed(req: String, msg: String?, from side: PhonePath, id: String? = nil) {
        let text = msg.flatMap { $0.isEmpty ? nil : $0 } ?? "The phone did not make the change."
        switch req {
        case "controls.set":
            if let id = id ?? lastSet[side] {
                pending[id] = nil
                pendingTokens[id] = nil
                errors[id] = text
            }
            showStatus(text)
        case "volume.set":
            pendingVolume = [:]
            showStatus(text)
        default:
            break
        }
    }

    private func showStatus(_ text: String) {
        statusToken += 1
        let token = statusToken
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.statusToken == token { self?.status = nil }
        }
    }

    // MARK: Polling

    /// While the menu is open, poll the shell helper every 3 s. The app session pushes changes itself.
    func menuVisible(_ open: Bool) {
        guard open != menuOpen else { return }
        menuOpen = open
        pollTimer?.invalidate()
        pollTimer = nil
        guard open else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshShell() }
    }

    func refresh() {
        guard !PhoneLink.isDemo, link.state == .connected else { return }
        let wanted = Set(sides(.quickControls) + sides(.volume))
        if wanted.contains(.app), link.sessionConnected { link.sendAppOnly(["t": "controls.get"]) }
        refreshShell()
    }

    private func refreshShell() {
        guard !PhoneLink.isDemo, link.state == .connected, agent.ready, link.shellCaps.contains("controls") else { return }
        guard sides(.quickControls).contains(.shell) || sides(.volume).contains(.shell) else { return }
        send(["t": "controls.get"], to: .shell, setId: nil)
    }

    func choicesChanged() {
        objectWillChange.send()
        if menuOpen { refresh() }
    }

    // MARK: Demo

    func loadDemo() {
        items[.app] = ["dnd": Value(on: true), "ringer": Value(mode: .normal), "torch": Value(on: false)]
        items[.shell] = ProcessInfo.processInfo.environment["PHONELINK_DEMO_CONTROLS"] == "app" ? [:] : [
            "bluetooth": Value(on: true), "data": Value(on: true), "powerSaving": Value(on: false),
            "darkMode": Value(on: true), "location": Value(on: true), "rotation": Value(on: false),
        ]
        volumes[.app] = [
            "media": Volume(level: 9, min: 0, max: 15), "ring": Volume(level: 11, min: 0, max: 15),
            "notification": Volume(level: 8, min: 0, max: 15), "alarm": Volume(level: 12, min: 0, max: 15),
            "call": Volume(level: 4, min: 1, max: 5),
        ]
        appReported = true
    }
}
