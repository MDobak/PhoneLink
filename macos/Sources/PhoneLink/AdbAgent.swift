import AppKit
import Combine
import Network

struct PhoneApp: Identifiable, Hashable {
    let pkg: String
    let label: String
    let version: String
    let system: Bool
    let enabled: Bool
    let launchable: Bool
    let installed: Date
    let updated: Date
    let size: Int64
    var id: String { pkg }

    init?(_ j: JSON) {
        guard let pkg = j["pkg"] as? String else { return nil }
        self.pkg = pkg
        label = (j["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pkg
        version = j["version"] as? String ?? ""
        system = j["system"] as? Bool ?? false
        enabled = j["enabled"] as? Bool ?? true
        launchable = j["launchable"] as? Bool ?? false
        installed = Date(timeIntervalSince1970: ((j["installed"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        updated = Date(timeIntervalSince1970: ((j["updated"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        size = (j["size"] as? NSNumber)?.int64Value ?? 0
    }
}

/// Helper that runs on the phone as the shell user over adb (ShellAgent). It syncs the clipboard, lists apps,
/// controls the hotspot and serves the same JSON requests as the app session (see PhoneRouter).
/// It announces supported request types in a "caps" message. Runs only while PhoneLink.adbSerial is set.
final class AdbAgent: ObservableObject {
    static let shared = AdbAgent()
    private static let localPort: UInt16 = 47803 + AdbManager.portOffset

    /// Stays true for a short grace time after a stop, because the helper often restarts.
    @Published private(set) var ready = false
    @Published private(set) var hotspotOn: Bool?
    @Published private(set) var hotspotName: String?
    private var hotspotPassword: String?
    @Published private(set) var sharingStarts = false
    /// Cleared only after the grace time. Requests should use can(_:), which has the real state.
    @Published private(set) var caps: Set<String> = []
    /// Main thread: helper messages that are not replies, e.g. "notif.posted".
    var onPush: ((JSON) -> Void)?
    /// Main thread: the real state, with no grace time.
    var onReady: ((Bool) -> Void)?

    private static let legacyCaps: Set<String> = ["apps", "icon", "hotspot", "clip.set"]
    private let capsLock = NSLock()
    /// On queue. An old helper sends no "caps" and copies only "id".
    private var legacyHelper: Bool { capsSnapshot == Self.legacyCaps }
    private var capsSnapshot: Set<String> = []

    private let queue = DispatchQueue(label: "phonelink.adbagent")
    private var serial: String?
    private var process: Process?
    private var conn: NWConnection?
    private var generation = 0
    private var nextId = 1
    private var pending: [Int: (JSON?) -> Void] = [:]
    private var bag: AnyCancellable?
    /// Main thread.
    private var iconCache: [String: NSImage] = [:]
    private var iconWaiters: [String: [(NSImage?) -> Void]] = [:]

    /// On queue. Unlike the published ready, it has no grace time.
    private var readyLocked = false
    /// The helper can stop and restart, e.g. after a crash on the phone. Keep the published state during this time
    /// so menus and the sidebar do not flicker.
    private static let graceTime: TimeInterval = 15
    private var graceWork: DispatchWorkItem?
    private var upSince: Date?
    /// On queue. Doubles on each stop (5 s to 60 s), back to 5 s after the helper stays up for 60 s.
    private var restartDelay = minRestartDelay
    private static let minRestartDelay: TimeInterval = 5
    private static let maxRestartDelay: TimeInterval = 60

    func start() {
        bag = PhoneLink.shared.$adbSerial.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] s in
            self?.setSerial(s)
        }
    }

    private func setSerial(_ s: String?) {
        queue.async {
            guard s != self.serial else { return }
            self.serial = s
            self.generation += 1
            self.restartDelay = Self.minRestartDelay
            self.stopLocked()
            // Another phone or none: drop the old state now, with no grace time.
            self.clearPublished()
            DispatchQueue.main.async { self.iconCache = [:] }
            if s != nil { self.launch(self.generation) }
        }
    }

    /// reply gets nil after the timeout or when the helper stops. Main thread.
    func request(_ j: JSON, timeout: TimeInterval = 20, reply: ((JSON?) -> Void)? = nil) {
        queue.async {
            var m = j
            let id = self.nextId
            self.nextId += 1
            if let reply {
                // The helper copies "rid" into each reply. "id" is data in some requests (e.g. mms.part).
                m["rid"] = id
                // An old helper copies only "id".
                if m["id"] == nil { m["id"] = id }
                self.pending[id] = { r in DispatchQueue.main.async { reply(r) } }
                self.queue.asyncAfter(deadline: .now() + timeout) { self.pending.removeValue(forKey: id)?(nil) }
            }
            guard let c = self.conn, self.readyLocked, let d = try? JSONSerialization.data(withJSONObject: m) else {
                self.pending.removeValue(forKey: id)?(nil)
                return
            }
            var n = UInt32(d.count).bigEndian
            c.send(content: Data(bytes: &n, count: 4) + d, completion: .contentProcessed { _ in })
        }
    }

    func apps(system: Bool, done: @escaping ([PhoneApp]?) -> Void) {
        request(["t": "apps", "system": system], timeout: 30) { r in
            guard let list = r?["apps"] as? [JSON] else { done(nil); return }
            done(list.compactMap(PhoneApp.init).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending })
        }
    }

    func icon(_ pkg: String, done: @escaping (NSImage?) -> Void) {
        if let i = iconCache[pkg] { done(i); return }
        if iconWaiters[pkg] != nil { iconWaiters[pkg]!.append(done); return }
        iconWaiters[pkg] = [done]
        request(["t": "icon", "pkg": pkg, "size": 96]) { [weak self] r in
            guard let self else { return }
            let img = (r?["png"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            if let img { self.iconCache[pkg] = img }
            self.iconWaiters.removeValue(forKey: pkg)?.forEach { $0(img) }
        }
    }

    func cachedIcon(_ pkg: String) -> NSImage? { iconCache[pkg] }

    func can(_ type: String) -> Bool {
        capsLock.lock()
        defer { capsLock.unlock() }
        return capsSnapshot.contains(type)
    }

    private func setCaps(_ c: Set<String>, publish: Bool = true) {
        capsLock.lock()
        capsSnapshot = c
        capsLock.unlock()
        guard publish else { return }
        DispatchQueue.main.async {
            guard self.caps != c else { return }
            self.caps = c
            // Remember the types so the sidebar does not change while the helper restarts.
            if !c.isEmpty { UserDefaults.standard.set(Array(c).sorted(), forKey: "directCaps") }
        }
    }

    func hotspot(on: Bool? = nil, done: ((String?) -> Void)? = nil) {
        var j: JSON = ["t": "hotspot"]
        if let on { j["on"] = on }
        request(j, timeout: 15) { [weak self] r in
            guard let r else { done?(Self.noAnswer); return }
            if let e = r["error"] as? String {
                done?(e)
                // Re-read after a failed change. Do not re-read after a failed read, or it loops.
                if on != nil { self?.hotspot() }
                return
            }
            self?.hotspotOn = r["on"] as? Bool
            self?.hotspotName = r["ssid"] as? String
            self?.hotspotPassword = r["password"] as? String
            // Saved so that the Mac can join the hotspot later without debugging (PhoneHotspot).
            if let ssid = r["ssid"] as? String { PhoneHotspot.shared.remember(ssid: ssid, password: r["password"] as? String) }
            done?(nil)
        }
    }

    /// Starts the phone hotspot and joins this Mac to it with the name and password from the phone.
    func shareInternet(done: @escaping (String?) -> Void) {
        guard !sharingStarts else { return }
        sharingStarts = true
        let finish: (String?) -> Void = { [weak self] e in self?.sharingStarts = false; done(e) }
        // Read the name and password first. Many phones drop Wi-Fi, and with it wireless debugging, when the hotspot starts.
        hotspot { [weak self] _ in
            guard let self else { return }
            // No answer can mean the hotspot started and cut the debugging connection. Continue with the credentials.
            self.hotspot(on: true) { [weak self] err in
                guard let self else { return }
                if let err, err != Self.noAnswer { finish(err); return }
                guard self.hotspotName?.isEmpty == false else { finish("The phone did not give the hotspot name."); return }
                // The hotspot takes a few seconds to start, so retry for about 20 s.
                self.joinWithRetry(left: 6, finish: finish)
            }
        }
    }

    private static let noAnswer = "The phone did not answer."

    private func joinWithRetry(left: Int, finish: @escaping (String?) -> Void) {
        joinHotspot { [weak self] err in
            guard let err else { finish(nil); return }
            guard left > 1, let self else { finish(err); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.joinWithRetry(left: left - 1, finish: finish) }
        }
    }

    func joinHotspot(done: @escaping (String?) -> Void) {
        guard let ssid = hotspotName, !ssid.isEmpty else { done("The phone did not give the hotspot name."); return }
        let password = hotspotPassword
        Task { @MainActor in
            switch await PhoneHotspot.join(ssid: ssid, password: password) {
            case .joined: done(nil)
            case .notFound: done("The Mac cannot find “\(ssid)”.")
            case .failed(let why): done(why)
            }
        }
    }

    func shell(_ args: [String], timeout: TimeInterval = 30, done: ((String?) -> Void)? = nil) {
        guard let s = PhoneLink.shared.adbSerial else { done?(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = AdbManager.shell(s, args, timeout: timeout)
            let out = r.flatMap { $0.status == 0 ? $0.output : nil }
            DispatchQueue.main.async { done?(out) }
        }
    }

    func install(_ url: URL, done: @escaping (String?) -> Void) {
        guard let s = PhoneLink.shared.adbSerial else { done("The phone is not connected."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = AdbManager.run(["-s", s, "install", "-r", url.path], timeout: 300)
            var err: String?
            if r == nil { err = "The installation did not finish." }
            else if let r, r.status != 0 || !r.output.contains("Success") {
                let line = r.output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("rror") }
                err = line.map(String.init) ?? "The phone did not install the app."
            }
            DispatchQueue.main.async { done(err) }
        }
    }

    /// On queue. onReady always gets the real state. Published values change at once only when the helper
    /// becomes ready; after a stop they change after graceTime.
    private func setReady(_ v: Bool) {
        readyLocked = v
        graceWork?.cancel()
        graceWork = nil
        if v {
            upSince = Date()
            DispatchQueue.main.async {
                self.ready = true
                self.onReady?(true)
            }
            return
        }
        setCaps([], publish: false)
        DispatchQueue.main.async { self.onReady?(false) }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.readyLocked else { return }
            self.clearPublished()
        }
        graceWork = w
        queue.asyncAfter(deadline: .now() + Self.graceTime, execute: w)
    }

    private func clearPublished() {
        graceWork?.cancel()
        graceWork = nil
        setCaps([])
        DispatchQueue.main.async {
            self.ready = false
            self.hotspotOn = nil
        }
    }

    private func launch(_ gen: Int) {
        guard let serial, let adb = AdbManager.path else { return }
        let classpath = AdbManager.classpath(serial)
        guard gen == generation else { return }
        // The helper can outlive our "adb shell" and keep its socket name, which blocks a new helper. Stop old ones first.
        _ = AdbManager.run(["-s", serial, "shell", "pkill -f com.mdobak.phonelink.ShellAgent"])
        guard gen == generation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "shell", "CLASSPATH=\(classpath) app_process / com.mdobak.phonelink.ShellAgent"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            self?.queue.async { self?.ended(gen, "exit code \(code)") }
        }
        // After "ready", keep draining output so a full pipe cannot block the helper.
        var buffer = ""
        var started = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            guard !started else { return }
            buffer += String(decoding: d, as: UTF8.self)
            if buffer.contains("ready") {
                started = true
                buffer = ""
                self?.queue.async { self?.connect(gen) }
            }
        }
        do { try p.run() } catch {
            // The termination handler does not run for a process that did not start.
            pipe.fileHandleForReading.readabilityHandler = nil
            ended(gen, "adb did not start")
            return
        }
        process = p
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, gen == self.generation, self.conn == nil else { return }
            self.ended(gen, "no ready message in 30 s")
        }
    }

    private func connect(_ gen: Int) {
        guard gen == generation, let serial,
              AdbManager.run(["-s", serial, "forward", "tcp:\(Self.localPort)", "localabstract:phonelink-agent"])?.status == 0 else {
            ended(gen, "adb forward failed")
            return
        }
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.localPort)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.read(c, gen)
            case .failed(let e), .waiting(let e): self.ended(gen, "connection: \(e.localizedDescription)")
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func ended(_ gen: Int, _ reason: String) {
        guard gen == generation else { return }
        generation += 1
        stopLocked()
        if let up = upSince, Date().timeIntervalSince(up) >= Self.maxRestartDelay { restartDelay = Self.minRestartDelay }
        upSince = nil
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
        NSLog("Phone Link: the shell helper stopped (%@). It starts again in %d s.", reason, Int(delay))
        let next = generation
        queue.asyncAfter(deadline: .now() + delay) {
            guard next == self.generation, self.serial != nil else { return }
            self.launch(next)
        }
    }

    private func stopLocked() {
        if readyLocked { setReady(false) }
        conn?.cancel()
        conn = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0(nil) }
    }

    private func read(_ c: NWConnection, _ gen: Int) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, err in
            guard let self, gen == self.generation else { return }
            guard let head, head.count == 4, err == nil else { self.ended(gen, Self.readError(err)); return }
            let n = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard n >= 0, n < 64 << 20 else { self.ended(gen, "bad frame length \(n)"); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard gen == self.generation else { return }
                guard let body, body.count == n, err == nil else { self.ended(gen, Self.readError(err)); return }
                if let j = (try? JSONSerialization.jsonObject(with: body)) as? JSON { self.handle(j) }
                self.read(c, gen)
            }
        }
    }

    private static func readError(_ err: NWError?) -> String {
        err.map { "read: \($0.localizedDescription)" } ?? "the phone closed the connection"
    }

    private func handle(_ j: JSON) {
        if let rid = j["rid"] as? Int, let cb = pending.removeValue(forKey: rid) { cb(j); return }
        if j["rid"] == nil, legacyHelper, let id = j["id"] as? Int, let cb = pending.removeValue(forKey: id) { cb(j); return }
        switch j["t"] as? String {
        case "hello":
            // Until the "caps" reply, assume an old helper. Do not publish yet: the views still show the last helper's
            // types, and the reply usually matches them.
            if capsSnapshot.isEmpty { setCaps(Self.legacyCaps, publish: false) }
            setReady(true)
            DispatchQueue.main.async { self.hotspot() }
            // An old helper replies with an error and keeps the legacy types. nil means the helper stopped.
            request(["t": "caps"], timeout: 10) { [weak self] r in
                guard let self, let r else { return }
                let types = (r["types"] as? [String]).map(Set.init) ?? Self.legacyCaps
                self.queue.async { if self.readyLocked { self.setCaps(types) } }
            }
        case "caps":
            if let types = j["types"] as? [String] { setCaps(Set(types)) }
        case "clip":
            guard let text = j["text"] as? String else { return }
            DispatchQueue.main.async {
                guard UserDefaults.standard.bool(forKey: "shareClipboard"),
                      NSPasteboard.general.string(forType: .string) != text else { return }
                ClipboardSync.shared.received(["t": "clip", "text": text])
            }
        case "clip.locked":
            // The phone is locked, so the helper could not read the new clipboard. The app can send the selected text.
            DispatchQueue.main.async {
                guard UserDefaults.standard.bool(forKey: "shareClipboard") else { return }
                PhoneLink.shared.requestSelectionForClipboard()
            }
        default:
            DispatchQueue.main.async { self.onPush?(j) }
        }
    }
}

enum HotspotControl {
    static func share(_ on: Bool) {
        guard on else { toggle(false); return }
        AdbAgent.shared.shareInternet { err in
            if let err { PhoneLink.shared.banner = "Phone Link could not share the phone internet. " + err }
        }
    }

    static func toggle(_ on: Bool) {
        AdbAgent.shared.hotspot(on: on) { err in
            if let err { PhoneLink.shared.banner = (on ? "The hotspot did not turn on. " : "The hotspot did not turn off. ") + err }
        }
    }

    static func join() {
        AdbAgent.shared.joinHotspot { err in if let err { PhoneLink.shared.banner = err } }
    }
}
