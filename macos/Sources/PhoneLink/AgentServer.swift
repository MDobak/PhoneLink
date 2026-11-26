import Foundation

/// Serves MCP to local agents: JSON-RPC 2.0, one message on each line, on a Unix socket.
/// The phonelink-mcp helper connects the stdio of the agent to this socket.
/// @unchecked: each property says if it belongs to the main thread or to queue.
final class AgentServer: ObservableObject, @unchecked Sendable {
    static let shared = AgentServer()

    static let socketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Phone Link/agent.sock")
    static var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/phonelink-mcp").path }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let client: String
        let tool: String
        let args: String
        var ok: Bool?
        var result: String?
        var ms: Int?
    }

    /// The tool calls, the newest first. Main thread.
    @Published private(set) var log: [LogEntry] = []
    /// An agent used the phone a short time ago. Main thread.
    @Published private(set) var active = false
    /// Connected agents. Main thread.
    @Published private(set) var clients: [String] = []
    /// The agent that used the phone last. Main thread.
    @Published private(set) var lastClient: String?
    @Published private(set) var error: String?

    private let queue = DispatchQueue(label: "phonelink.agents")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// On queue.
    private var conns: [Int32: Conn] = [:]
    /// Main thread.
    private var running = 0
    private var idle: DispatchWorkItem?
    /// The tool calls that run, so that Stop can cancel them. On queue.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The sign on the phone (AgentSign on Android). Main thread.
    private var signSent: Date?
    private var signOff: DispatchWorkItem?

    private final class Conn {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var name = "Agent"
        var ready = false
        var subscriptions: Set<String> = []
        /// Writes go through this queue. closed is set on it too, so that no write goes to a closed
        /// descriptor, which the system can give to a new connection.
        let out: DispatchQueue
        var closed = false
        init(fd: Int32) { self.fd = fd; out = DispatchQueue(label: "phonelink.agents.out.\(fd)") }
    }

    private init() {}

    // MARK: - Socket

    func start() {
        queue.async { self.listen() }
    }

    private func listen() {
        guard listenFD < 0 else { return }
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(at: Self.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("Phone Link could not make the agent socket."); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); fail("The path of the agent socket is too long."); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        // Only this user can connect.
        let old = umask(0o077)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard ok == 0, Darwin.listen(fd, 8) == 0 else { close(fd); fail("Phone Link could not open the agent socket."); return }
        chmod(path, 0o600)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        acceptSource = src
    }

    private func fail(_ msg: String) {
        NSLog("Phone Link: %@", msg)
        DispatchQueue.main.async { self.error = msg }
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let c = Conn(fd: fd)
        conns[fd] = c
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readable(c) }
        src.setCancelHandler { c.out.async { c.closed = true; close(fd) } }
        c.source = src
        src.resume()
    }

    private func readable(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { read(c.fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            drop(c)
            return
        }
        c.buffer.append(contentsOf: buf[0..<n])
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            let line = c.buffer[c.buffer.startIndex..<nl]
            c.buffer = Data(c.buffer[(nl + 1)...])
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            guard let msg = try? JSONSerialization.jsonObject(with: line) else {
                send(c, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = msg as? [JSON] { batch.forEach { receive(c, $0) } }
            else if let m = msg as? JSON { receive(c, m) }
        }
        if c.buffer.count > 16 << 20 { drop(c) }
    }

    private func drop(_ c: Conn) {
        guard conns.removeValue(forKey: c.fd) != nil else { return }
        c.source?.cancel()
        publishClients()
    }

    private func publishClients() {
        let names = conns.values.filter(\.ready).map(\.name).sorted()
        DispatchQueue.main.async { self.clients = names }
    }

    /// Any thread.
    private func send(_ c: Conn, _ j: JSON) {
        guard var d = try? JSONSerialization.data(withJSONObject: j, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        c.out.async {
            guard !c.closed else { return }
            d.withUnsafeBytes { p in
                var off = 0
                while off < p.count {
                    let w = write(c.fd, p.baseAddress! + off, p.count - off)
                    if w < 0 { if errno == EINTR { continue }; return }
                    off += w
                }
            }
        }
    }

    // MARK: - JSON-RPC

    private static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private static let instructions = """
        These tools use the Android phone that is connected to Phone Link on this Mac. \
        The user selects which tools are available in Phone Link Settings > Agents. \
        Times are ISO 8601 in the time zone of the phone; you can also give times as milliseconds since 1970. \
        Durations and timeouts are in milliseconds. \
        To control an app, use screen_read to get the element IDs, then screen_control. \
        To read new chat messages without opening the app (which can mark them as read), use notifications_read; \
        with history, it also gives older notifications, if the user turned on the history. \
        To open an app on its start screen, use apps_start. \
        To find what an app can do, use apps_read with action "info", then intents_resolve and intents_start. \
        Agents cannot unlock the phone. When the phone is locked (status_read: screen.locked), the main screen shows the lock screen. \
        Then open the app in a window on this Mac with windows_control, and give the window to screen_read, screen_control, \
        screen_capture, intents_start and notifications_act. App windows work while the phone is locked.
        """

    /// On queue.
    private func receive(_ c: Conn, _ m: JSON) {
        let method = m.str("method")
        let id = m["id"]
        guard let method else { return } // A response: this server sends no requests.
        guard let id, !(id is NSNull) else {
            if method == "notifications/initialized" { c.ready = true; publishClients() }
            return
        }
        func reply(_ result: Any) { send(c, ["jsonrpc": "2.0", "id": id, "result": result]) }
        func error(_ code: Int, _ msg: String) { send(c, ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]]) }
        let params = m["params"] as? JSON ?? [:]

        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? JSON { c.name = info.str("title") ?? info.str("name") ?? c.name }
            let asked = params.str("protocolVersion") ?? ""
            reply([
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                "capabilities": ["tools": ["listChanged": true], "resources": ["subscribe": true, "listChanged": true]],
                "serverInfo": ["name": "phone-link", "title": "Phone Link", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
                "instructions": Self.instructions,
            ])
            c.ready = true
            publishClients()
        case "ping", "logging/setLevel":
            reply([String: Any]())
        case "tools/list":
            reply(["tools": AgentTools.visible().map(\.listing)])
        case "tools/call":
            guard let name = params.str("name") else { error(-32602, "The tool name is missing."); return }
            let args = params["arguments"] as? JSON ?? [:]
            let client = c.name
            let key = UUID()
            tasks[key] = Task {
                reply(await self.call(name, args, client: client))
                self.queue.async { self.tasks[key] = nil }
            }
        case "resources/list":
            reply(["resources": AgentResources.list()])
        case "resources/templates/list":
            reply(["resourceTemplates": AgentResources.templates()])
        case "resources/read":
            let uri = params.str("uri") ?? ""
            Task {
                do { reply(["contents": [["uri": uri, "mimeType": "application/json", "text": try await AgentResources.read(uri)]]]) }
                catch { send(c, ["jsonrpc": "2.0", "id": id, "error": ["code": -32002, "message": error.localizedDescription]]) }
            }
        case "resources/subscribe":
            if let uri = params.str("uri") { c.subscriptions.insert(uri) }
            reply([String: Any]())
        case "resources/unsubscribe":
            if let uri = params.str("uri") { c.subscriptions.remove(uri) }
            reply([String: Any]())
        default:
            error(-32601, "Method not found: " + method)
        }
    }

    private func call(_ name: String, _ args: JSON, client: String) async -> JSON {
        let started = Date()
        let entry = LogEntry(time: started, client: client, tool: name, args: Self.summary(args))
        await MainActor.run { self.began(entry) }
        let out: AgentOutput
        let ok: Bool
        do {
            guard let tool = AgentTools.visible().first(where: { $0.name == name }) else {
                throw AgentError("The tool \(name) is off. The user can turn it on in Phone Link Settings > Agents.")
            }
            let o = try await tool.run(AgentArgs(args))
            if Task.isCancelled { throw AgentError("The user stopped the agents.") }
            out = o
            ok = true
        } catch {
            out = .text(error.localizedDescription)
            ok = false
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let summary = out.summary
        await MainActor.run { self.ended(entry.id, ok: ok, result: summary, ms: ms) }
        return out.mcp(error: !ok)
    }

    static func summary(_ args: JSON) -> String {
        guard !args.isEmpty else { return "" }
        var a = args
        for (k, v) in a {
            if let s = v as? String, s.count > 200 { a[k] = String(s.prefix(200)) + "…" }
        }
        let d = (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let s = String(decoding: d, as: UTF8.self)
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }

    // MARK: - Activity (main thread)

    private func began(_ e: LogEntry) {
        log.insert(e, at: 0)
        if log.count > 500 { log.removeLast(log.count - 500) }
        running += 1
        idle?.cancel()
        active = true
        lastClient = e.client
        signOff?.cancel()
        // Show the sign on the phone, and refresh it before it expires on the phone.
        if signSent.map({ Date().timeIntervalSince($0) > 60 }) ?? true { sendSign(true, e.client) }
    }

    private func sendSign(_ on: Bool, _ client: String? = nil) {
        signSent = on ? Date() : nil
        var j: JSON = ["t": "agent.presence", "on": on]
        if let client { j["client"] = client }
        PhoneLink.shared.sendAppOnly(j)
    }

    /// Tells the phone the agent settings that it needs. On each new session and when the settings change. Main thread.
    func sendConfig() {
        PhoneLink.shared.sendAppOnly(["t": "agent.config", "history": AgentSettings.shared.historyOn])
    }

    /// Turns off the agents: hides all tools, cancels the calls that run and removes the sign on the phone.
    /// From the menu bar or from the Stop action on the phone. Any thread.
    func stopAll() {
        queue.async {
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
        }
        DispatchQueue.main.async {
            AgentSettings.shared.enabled = false
            self.signOff?.cancel()
            if self.signSent != nil { self.sendSign(false) }
        }
    }

    private func ended(_ id: UUID, ok: Bool, result: String, ms: Int) {
        if let i = log.firstIndex(where: { $0.id == id }) {
            log[i].ok = ok
            log[i].result = result
            log[i].ms = ms
        }
        running -= 1
        guard running == 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.active = false }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        // Agents often wait some seconds between calls. Keep the sign on the phone for one minute.
        let s = DispatchWorkItem { [weak self] in if self?.signSent != nil { self?.sendSign(false) } }
        signOff = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: s)
    }

    func clearLog() { log.removeAll { $0.ok != nil } }

    // MARK: - Notifications to agents

    /// The settings changed. Any thread.
    func toolsChanged() {
        queue.async {
            for c in self.conns.values where c.ready {
                self.send(c, ["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
                self.send(c, ["jsonrpc": "2.0", "method": "notifications/resources/list_changed"])
            }
        }
    }

    /// On queue.
    private var lastUpdate: [String: Date] = [:]

    /// A subscribed resource changed. Any thread.
    func resourceChanged(_ uri: String) {
        queue.async {
            // Not more than one update each second for one resource.
            if let t = self.lastUpdate[uri], Date().timeIntervalSince(t) < 1 { return }
            self.lastUpdate[uri] = Date()
            for c in self.conns.values where c.subscriptions.contains(uri) {
                self.send(c, ["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": uri]])
            }
        }
    }

    // MARK: - Events from the phone

    struct Event { let seq: Int; let type: String; let group: AgentGroup; let time: Date; let data: Any }

    private let eventLock = NSLock()
    private var events: [Event] = []
    private var eventSeq = 0
    private var lastClip: (text: String, time: Date)?

    /// A message from the phone. Main thread (PhoneLink.handle).
    func phoneEvent(_ j: JSON) {
        guard AgentSettings.shared.anyOn, let t = j.str("t") else { return }
        var e: (String, AgentGroup, Any)?
        switch t {
        case "sms.new":
            guard let m = j["message"] as? JSON else { return }
            e = ("message.new", .messagesRead, m)
            if let thread = m.i64("thread") { resourceChanged("phone://conversations/\(thread)") }
        case "notif.posted":
            guard var n = j["n"] as? JSON else { return }
            for k in ["icon", "largeIcon", "picture", "iconKey"] { n.removeValue(forKey: k) }
            e = ("notification.posted", .notificationsRead, n)
            resourceChanged("phone://notifications")
        case "notif.removed":
            e = ("notification.removed", .notificationsRead, ["key": j["key"] ?? NSNull()])
            resourceChanged("phone://notifications")
        case "call.state":
            e = ("call.state", .personalRead, ["state": j["state"] ?? "idle", "number": j["number"] ?? NSNull(), "name": j["name"] ?? NSNull()])
            resourceChanged("phone://status")
        case "call.missed":
            e = ("call.missed", .personalRead, ["number": j["number"] ?? NSNull(), "name": j["name"] ?? NSNull()])
        case "clip":
            guard let text = j.str("text") else { return }
            eventLock.lock(); lastClip = (text, Date()); eventLock.unlock()
            e = ("clipboard.changed", .clipboardRead, ["text": text])
        case "status":
            e = ("status", .status, ["battery": j["battery"] ?? NSNull(), "charging": j.bool("charging")])
            resourceChanged("phone://status")
        case "media":
            var m = j
            for k in ["t", "art", "artKey"] { m.removeValue(forKey: k) }
            e = ("media", .status, m)
            resourceChanged("phone://status")
        case "screen.locked":
            e = ("screen.locked", .status, ["locked": j.bool("locked")])
            resourceChanged("phone://status")
        default:
            return
        }
        guard let (type, group, data) = e else { return }
        eventLock.lock()
        eventSeq += 1
        events.append(Event(seq: eventSeq, type: type, group: group, time: Date(), data: data))
        if events.count > 300 { events.removeFirst(events.count - 300) }
        eventLock.unlock()
    }

    /// The last event number. Any thread.
    var eventCursor: Int { eventLock.lock(); defer { eventLock.unlock() }; return eventSeq }

    /// Events after the cursor that the settings allow. Any thread.
    func events(after cursor: Int, types: Set<String>) -> [Event] {
        eventLock.lock()
        let list = events.filter { $0.seq > cursor }
        eventLock.unlock()
        let s = AgentSettings.shared
        return list.filter { ev in
            let allowed = s.allows(ev.group) || (ev.type == "call.state" && s.allows(.calls))
            return allowed && (types.isEmpty || types.contains(ev.type) || types.contains(where: { ev.type.hasPrefix($0 + ".") }))
        }
    }

    /// The last clipboard text that the phone sent. Any thread.
    var lastClipboard: (text: String, time: Date)? { eventLock.lock(); defer { eventLock.unlock() }; return lastClip }
}
