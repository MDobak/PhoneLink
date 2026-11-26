import AppKit
import Foundation

struct AgentError: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

/// The arguments of a tool call.
struct AgentArgs {
    let j: JSON
    init(_ j: JSON) { self.j = j }
    func str(_ k: String) -> String? { j.str(k) }
    func int(_ k: String) -> Int? { j.int(k) ?? (j[k] as? String).flatMap { Int($0) } }
    func bool(_ k: String) -> Bool { j.bool(k) || (j[k] as? String) == "true" }
    func has(_ k: String) -> Bool { j[k] != nil && !(j[k] is NSNull) }
    func need(_ k: String) throws -> String {
        guard let s = str(k) else { throw AgentError("Give \"\(k)\".") }
        return s
    }
    /// The arguments with these names, without nulls.
    func pick(_ keys: [String]) -> JSON {
        var o = JSON()
        for k in keys { if let v = j[k], !(v is NSNull) { o[k] = v } }
        return o
    }
    /// All arguments without nulls.
    var all: JSON { j.filter { !($0.value is NSNull) } }
    func action(_ allowed: [String]) throws -> String {
        guard let a = str("action"), allowed.contains(a) else {
            throw AgentError("\"action\" must be " + allowed.dropLast().joined(separator: ", ") + " or " + allowed.last! + ".")
        }
        return a
    }
}

enum AgentOutput {
    case json(Any)
    case text(String)
    case image(data: String, mime: String, meta: JSON)

    func mcp(error: Bool) -> JSON {
        switch self {
        case .text(let s): return ["content": [["type": "text", "text": s]], "isError": error]
        case .json(let v): return ["content": [["type": "text", "text": Self.encode(v)]], "isError": error]
        case .image(let d, let mime, let meta):
            return ["content": [["type": "image", "data": d, "mimeType": mime], ["type": "text", "text": Self.encode(meta)]], "isError": error]
        }
    }

    /// A short text for the activity log.
    var summary: String {
        switch self {
        case .text(let s): return String(s.prefix(300))
        case .json(let v):
            let s = Self.encode(v)
            return s.count > 300 ? String(s.prefix(300)) + "…" : s
        case .image(let d, let mime, _): return "\(mime) image, \(d.count * 3 / 4 / 1024) KB"
        }
    }

    static func encode(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return String(describing: v) }
        return String(decoding: d, as: UTF8.self)
    }
}

struct AgentTool {
    let name: String
    let title: String
    /// The tool is in the list when one of these groups is on.
    let groups: [AgentGroup]
    let readOnly: Bool
    var destructive = false
    let description: String
    let input: JSON
    let run: (AgentArgs) async throws -> AgentOutput

    var listing: JSON {
        ["name": name, "title": title, "description": description, "inputSchema": input,
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]]
    }
}

/// JSON Schema parts.
private enum S {
    static func object(_ p: [String: JSON], _ required: [String] = []) -> JSON {
        var o: JSON = ["type": "object", "properties": p]
        if !required.isEmpty { o["required"] = required }
        return o
    }
    static func string(_ d: String, _ values: [String]? = nil) -> JSON {
        var o: JSON = ["type": "string", "description": d]
        if let values { o["enum"] = values }
        return o
    }
    static func int(_ d: String) -> JSON { ["type": "integer", "description": d] }
    static func number(_ d: String) -> JSON { ["type": "number", "description": d] }
    static func bool(_ d: String) -> JSON { ["type": "boolean", "description": d] }
    static func strings(_ d: String) -> JSON { ["type": "array", "items": ["type": "string"], "description": d] }
    static func dict(_ d: String) -> JSON { ["type": "object", "description": d] }
    static func list(_ d: String) -> JSON { ["type": "array", "description": d] }
    static func time(_ d: String) -> JSON { ["type": ["string", "integer"], "description": d + " ISO 8601, or milliseconds since 1970."] }
    static func any(_ d: String) -> JSON { ["description": d] }
    static let limit = int("The maximum number of items.")
}

/// Requests to Phone Link on the phone ("agent" messages).
final class AgentPhone: @unchecked Sendable {
    static let shared = AgentPhone()
    private let lock = NSLock()
    private var pending: [String: (JSON?) -> Void] = [:]

    private func take(_ rid: String) -> ((JSON?) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: rid)
    }

    func call(_ op: String, _ args: JSON = [:], timeout: TimeInterval = 30) async throws -> Any {
        let link = PhoneLink.shared
        guard link.isSessionOpen else { throw AgentError("The phone is not connected to Phone Link on this Mac.") }
        let rid = UUID().uuidString
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            lock.lock()
            pending[rid] = { r in
                guard let r else {
                    c.resume(throwing: AgentError("The phone did not answer in \(Int(timeout)) seconds. Make sure that Phone Link on the phone is up to date."))
                    return
                }
                if r.bool("ok") { c.resume(returning: r["data"] ?? NSNull()) }
                else { c.resume(throwing: AgentError(r.str("error") ?? "The phone did not do the request.")) }
            }
            lock.unlock()
            link.sendAppOnly(["t": "agent", "rid": rid, "op": op, "args": args])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { self.take(rid)?(nil) }
        }
    }

    /// "agent.result" from the phone. Any thread.
    func received(_ j: JSON) {
        guard let rid = j.str("rid") else { return }
        take(rid)?(j)
    }
}

enum AgentTools {
    /// The tools that the settings allow. Any thread.
    static func visible() -> [AgentTool] { visible(allows: AgentSettings.shared.allows) }

    static func visible(allows: (AgentGroup) -> Bool) -> [AgentTool] {
        all.filter { $0.groups.contains(where: allows) }
    }

    private static func phone(_ op: String, _ args: JSON = [:], timeout: TimeInterval = 30) async throws -> AgentOutput {
        .json(try await AgentPhone.shared.call(op, args, timeout: timeout))
    }

    private static func ms(_ a: AgentArgs, _ key: String, _ def: Int) -> TimeInterval { TimeInterval(a.int(key) ?? def) / 1000 }

    private static let isoFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static func iso(_ ms: Int64?) -> Any {
        guard let ms else { return NSNull() }
        return isoFormat.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private static func isPackageName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$", options: .regularExpression) != nil
    }

    @MainActor private static func callJSON() -> Any {
        guard let c = PhoneLink.shared.call else { return NSNull() }
        return ["state": c.state, "number": c.number ?? NSNull(), "name": c.name ?? NSNull(), "audioOnMac": CallAudio.shared.audioOnMac] as JSON
    }

    // MARK: - Shared with the resources

    static func status() async throws -> JSON {
        var o = (try await AgentPhone.shared.call("status")) as? JSON ?? [:]
        let mac = await MainActor.run { () -> JSON in
            let l = PhoneLink.shared
            return ["link": ["connected": l.state == .connected, "type": l.linkKind?.rawValue ?? NSNull(), "phone": l.phoneName,
                             "model": l.phoneModel, "debugging": l.adbSerial != nil] as JSON,
                    "call": callJSON()]
        }
        o.merge(mac) { $1 }
        return o
    }

    // MARK: - Mac helpers

    /// Runs a command on the phone with adb.
    static func adb(_ cmd: String, timeout: TimeInterval = 20) async throws -> AdbManager.Result {
        let serial = await MainActor.run { PhoneLink.shared.adbSerial }
        guard let serial else {
            throw AgentError("This needs USB debugging or wireless debugging. The user can turn it on in Phone Link Settings > Connections.")
        }
        return try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                if let r = AdbManager.shell(serial, [cmd], timeout: timeout) { c.resume(returning: r) }
                else { c.resume(throwing: AgentError("adb did not complete the command in \(Int(timeout)) seconds.")) }
            }
        }
    }

    /// An image file on the Mac as JPEG, with a maximum side of 1600 pixels.
    private static func jpeg(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AgentError("Phone Link cannot open the image \(url.path).")
        }
        let scale = min(1, 1600 / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AgentError("Phone Link cannot convert the image.") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(),
              let d = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw AgentError("Phone Link cannot convert the image.")
        }
        return d.base64EncodedString()
    }

    private static func fileJSON(_ j: JSON) -> JSON {
        var o: JSON = ["name": j["name"] ?? "", "path": j["path"] ?? "", "dir": j.bool("dir")]
        if !j.bool("dir") { o["size"] = j.i64("size") ?? 0 }
        o["modified"] = iso(j.i64("mtime"))
        if let c = j.i64("count") { o["count"] = c }
        if let c = j.i64("ctime") { o["created"] = iso(c) }
        return o
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private static func split(_ path: String) throws -> (String, String) {
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let i = p.lastIndex(of: "/"), i != p.startIndex || p.count > 1 else { throw AgentError("Give a full path, for example /sdcard/Download/a.txt.") }
        let dir = i == p.startIndex ? "/" : String(p[..<i])
        return (dir, String(p[p.index(after: i)...]))
    }

    /// Reads part of a phone file.
    private static func readFile(_ path: String, offset: Int64, length: Int64) async throws -> (Data, Int64) {
        final class Box { var data = Data(); var size: Int64 = -1 }
        let box = Box()
        return try await withCheckedThrowingContinuation { c in
            let sink = FileHub.ReadSink()
            sink.onMeta = { size, _, _ in box.size = size }
            sink.onData = { box.data.append($0) }
            sink.onEnd = { e in
                if let e { c.resume(throwing: AgentError(e.msg)) } else { c.resume(returning: (box.data, box.size)) }
            }
            FileHub.shared.read(path: path, offset: offset, length: length, suffix: nil, sink: sink)
        }
    }

    /// Copies a phone file to a file on the Mac.
    private static func download(_ path: String, to url: URL) async throws -> Int64 {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw AgentError("Phone Link cannot write \(url.path).") }
        final class Box { var count: Int64 = 0 }
        let box = Box()
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let sink = FileHub.ReadSink()
                sink.onData = { d in h.write(d); box.count += Int64(d.count) }
                sink.onEnd = { e in if let e { c.resume(throwing: AgentError(e.msg)) } else { c.resume() } }
                FileHub.shared.read(path: path, offset: nil, length: nil, suffix: nil, sink: sink)
            }
        } catch {
            try? h.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        try? h.close()
        return box.count
    }

    private static let imageTypes = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"]

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2... {
            let u = url.deletingLastPathComponent().appendingPathComponent(base + " \(n)" + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return url
    }

    // MARK: - App windows on the Mac

    @MainActor private static func stream(_ window: String) throws -> AppStream {
        let pkg = window == "desktop" ? AppStream.desktopID : window
        guard let s = AppStream.open.first(where: { $0.pkg == pkg }) else {
            throw AgentError("No app window of \(window) is open. Use windows_read, or windows_control with the action open.")
        }
        return s
    }

    /// The display of the window in the arguments, or nil for the main phone screen.
    private static func display(_ a: AgentArgs) async throws -> Int? {
        guard let w = a.str("window") else { return nil }
        return try await MainActor.run {
            let s = try stream(w)
            guard let id = s.displayId, s.phase == .streaming else { throw AgentError("The window \(w) is not open yet. Try again in a moment.") }
            return id
        }
    }

    /// The arguments for the phone, with "display" for a window.
    private static func onDisplay(_ args: JSON, _ a: AgentArgs) async throws -> JSON {
        var o = args
        o.removeValue(forKey: "window")
        if let d = try await display(a) { o["display"] = d }
        return o
    }

    @MainActor private static func windowJSON(_ s: AppStream) -> JSON {
        let state: String
        switch s.phase {
        case .idle: state = "closed"
        case .opening: state = "opening"
        case .streaming: state = "open"
        case .failed(let m): state = "failed: " + m
        }
        var o: JSON = ["window": s.isDesktop ? "desktop" : s.pkg, "title": s.isDesktop ? "Phone Desktop" : (s.label ?? s.pkg),
                       "state": state, "display": s.displayId ?? NSNull()]
        if !s.isDesktop { o["package"] = s.pkg }
        if let w = s.window {
            let c = w.contentLayoutRect.size
            o["size"] = ["width": Int(c.width), "height": Int(c.height)]
            o["focused"] = w.isKeyWindow
        }
        return o
    }

    /// Why a window did not open: for the error of windows_control.
    private static func windowDiagnosis(_ pkg: String) async -> String {
        let (phase, display): (AppStream.Phase?, Int?) = await MainActor.run {
            let s = AppStream.open.first(where: { $0.pkg == pkg })
            return (s?.phase, s?.displayId)
        }
        var out: [String] = []
        switch phase {
        case nil: out.append("The window closed.")
        case .opening?: out.append("The window is still open and waits for the first picture.")
        default: break
        }
        guard let display else {
            out.append("The phone did not make a virtual display. Make sure that USB or wireless debugging is on, and examine the window on this Mac for a message.")
            return out.joined(separator: " ")
        }
        out.append("The virtual display is \(display).")
        if let r = try? await adb("dumpsys activity activities"), r.status == 0 {
            var current: Int?
            var top: String?
            for line in r.output.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Display #") { current = Int(t.dropFirst(9).prefix(while: \.isNumber)) }
                else if current == display, t.hasPrefix("topResumedActivity="), let c = t.split(separator: " ").first(where: { $0.contains("/") }) {
                    top = String(c); break
                }
            }
            if let top {
                out.append("The activity in front on that display is \(top).")
                if !top.hasPrefix(pkg + "/") && pkg != AppStream.desktopID {
                    out.append("The app did not start there. Some apps do not allow other displays, or they show a sign-in, update or permission screen on the phone screen.")
                }
            } else {
                out.append("No activity runs on that display. The app did not start, or it closed at once.")
            }
        }
        out.append("Use screen_capture with this window to see it. Close it with windows_control action close.")
        return out.joined(separator: " ")
    }

    /// The screen_read tree as one line for each element: [id] class "text" desc="..." {flags} @x,y (the center).
    static func screenText(_ r: JSON) -> String {
        var lines: [String] = []
        if let s = r["screen"] as? [Int], s.count == 2 {
            var h = "screen \(s[0])x\(s[1])"
            if let f = r.str("front") { h += ", front app " + f }
            if let d = r.int("display") { h += ", display \(d)" }
            lines.append(h)
        }
        func walk(_ list: [JSON], _ depth: Int) {
            for e in list {
                var l = String(repeating: " ", count: depth) + "[\(e.int("id") ?? 0)]"
                if let c = e.str("class"), c != "TextView", c != "View" { l += " " + c }
                let text = e.str("text"), desc = e.str("desc")
                if let text { l += " \"" + text + "\"" }
                if let desc, desc != text { l += " desc=\"" + desc + "\"" }
                if let h = e.str("hint") { l += " hint=\"" + h + "\"" }
                if text == nil, desc == nil, let res = e.str("res") { l += " res=" + res }
                if let f = e["flags"] as? [String], !f.isEmpty { l += " {" + f.joined(separator: ",") + "}" }
                if let b = e["bounds"] as? [Int], b.count == 4 { l += " @\((b[0] + b[2]) / 2),\((b[1] + b[3]) / 2)" }
                lines.append(l)
                walk(e["children"] as? [JSON] ?? [], depth + 1)
            }
        }
        for w in r["windows"] as? [JSON] ?? [] {
            var h = "# " + (w.str("type") ?? "window")
            if let p = w.str("package") { h += " " + p }
            if let t = w.str("title") { h += " \"" + t + "\"" }
            if w.bool("active") { h += " (active)" }
            lines.append(h)
            let elements = w["elements"] as? [JSON] ?? []
            walk(elements, 1)
            if elements.isEmpty { lines.append(" (no elements)") }
        }
        if (r["windows"] as? [JSON] ?? []).allSatisfy({ ($0["elements"] as? [JSON] ?? []).isEmpty }), r["found"] == nil {
            lines.append("No elements. Some screens do not give elements, for example the phone home screen in a window while the phone is locked. Use screen_capture, then screen_control with x and y. Or open an app with apps_start.")
        }
        if let f = r["found"] as? Bool { lines.append(f ? "found: yes" : "found: no") }
        if r.bool("truncated") { lines.append("(more elements: give a larger maxNodes)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tools

    static let all: [AgentTool] = [
        AgentTool(name: "status_read", title: "Read the phone status", groups: [.status], readOnly: true,
                  description: "Gets the battery, network, signal, SIM cards, screen (on, locked), the app in front, storage, Do Not Disturb, the ringer, the volume, the media that plays, the current call and the connection to the Mac.",
                  input: S.object([:])) { _ in .json(try await status()) },

        AgentTool(name: "messages_read", title: "Read messages", groups: [.messagesRead], readOnly: true,
                  description: "Reads SMS and MMS. Reading does not mark messages as read. \"conversations\" lists the conversations, the newest first. \"read\" gets the messages of one conversation (give thread or address), the newest first. \"search\" finds messages that contain a text. \"attachment\" gets an image of an MMS (the id comes from the attachments of a message).",
                  input: S.object([
                    "action": S.string("What to do.", ["conversations", "read", "search", "attachment"]),
                    "thread": S.int("The conversation ID (read)."),
                    "address": S.string("A phone number (read, search)."),
                    "query": S.string("The text to find (search)."),
                    "unreadOnly": S.bool("Only unread conversations or messages."),
                    "before": S.time("Only messages before this time (read)."),
                    "since": S.time("Only conversations with a message after this time (conversations), or only messages after this time (search)."),
                    "id": S.int("The attachment ID (attachment)."),
                    "limit": S.limit,
                  ], ["action"])) { a in
            switch try a.action(["conversations", "read", "search", "attachment"]) {
            case "conversations": return try await phone("sms.threads", a.pick(["limit", "unreadOnly", "since"]))
            case "read": return try await phone("sms.read", a.pick(["thread", "address", "limit", "before"]))
            case "search": return try await phone("sms.search", a.pick(["query", "address", "since", "unreadOnly", "limit"]))
            default:
                guard let id = a.int("id") else { throw AgentError("Give \"id\".") }
                let r = try await AgentPhone.shared.call("sms.attachment", ["id": id]) as? JSON ?? [:]
                guard let d = r.str("data") else { throw AgentError("The attachment has no image data.") }
                return .image(data: d, mime: r.str("mime") ?? "image/jpeg", meta: ["id": id])
            }
        },

        AgentTool(name: "messages_send", title: "Send a message", groups: [.messagesSend], readOnly: false,
                  description: "Sends an SMS, or an MMS when there is more than one recipient or an image. The message goes out at once.",
                  input: S.object([
                    "to": S.strings("The phone numbers of the recipients."),
                    "text": S.string("The text of the message."),
                    "imagePath": S.string("An image file on this Mac to send as MMS."),
                    "sim": S.int("The subscription ID of the SIM to use (from status_read). The default SIM if not given."),
                  ], ["to"])) { a in
            var args = a.pick(["text", "sim"])
            let to = (a.j["to"] as? [Any])?.compactMap { $0 as? String } ?? a.str("to").map { [$0] } ?? []
            guard !to.isEmpty else { throw AgentError("Give at least one recipient in \"to\".") }
            args["to"] = to
            if let p = a.str("imagePath") { args["image"] = try jpeg(p) }
            guard args["text"] != nil || args["image"] != nil else { throw AgentError("Give \"text\" or \"imagePath\".") }
            return try await phone("sms.send", args, timeout: 120)
        },

        AgentTool(name: "contacts_read", title: "Read contacts", groups: [.personalRead], readOnly: true,
                  description: "\"find\" finds contacts by name, phone number or email. An empty query lists all contacts. \"get\" gets all fields of one contact.",
                  input: S.object([
                    "action": S.string("What to do.", ["find", "get"]),
                    "query": S.string("A name, phone number or email (find)."),
                    "id": S.int("The contact ID (get)."),
                    "limit": S.limit,
                  ], ["action"])) { a in
            if try a.action(["find", "get"]) == "find" { return try await phone("contacts.find", a.pick(["query", "limit"])) }
            guard let id = a.int("id") else { throw AgentError("Give \"id\".") }
            return try await phone("contacts.get", ["id": id])
        },

        AgentTool(name: "contacts_write", title: "Change contacts", groups: [.personalWrite], readOnly: false, destructive: true,
                  description: "Creates, changes or deletes a contact. In \"update\", each field that you give replaces all values of that field.",
                  input: S.object([
                    "action": S.string("What to do.", ["create", "update", "delete"]),
                    "id": S.int("The contact ID (update, delete)."),
                    "name": S.string("The full name."),
                    "given": S.string("The given name."),
                    "family": S.string("The family name."),
                    "phones": S.list("Phone numbers: strings, or {\"value\", \"label\"} with the label mobile, home, work, main, other or a custom label."),
                    "emails": S.list("Emails: strings, or {\"value\", \"label\"} with the label home, work, mobile, other or a custom label."),
                    "addresses": S.list("Postal addresses: strings, or {\"value\", \"label\"}."),
                    "organization": S.string("The company."),
                    "title": S.string("The job title."),
                    "note": S.string("A note."),
                    "birthday": S.string("The birthday, YYYY-MM-DD."),
                    "starred": S.bool("A favorite contact."),
                    "accountType": S.string("The account type for a new contact, for example com.google."),
                    "accountName": S.string("The account name for a new contact."),
                  ], ["action"])) { a in
            _ = try a.action(["create", "update", "delete"])
            return try await phone("contacts.edit", a.all)
        },

        AgentTool(name: "calendar_read", title: "Read the calendar", groups: [.personalRead], readOnly: true,
                  description: "\"calendars\" lists the calendars. \"events\" lists the events in a time range (each repeat is one item), the first first.",
                  input: S.object([
                    "action": S.string("What to do.", ["calendars", "events"]),
                    "from": S.time("The start of the range. The default is now."),
                    "to": S.time("The end of the range. The default is 30 days after the start."),
                    "query": S.string("Only events with this text in the title, location or description."),
                    "calendar": S.int("Only events of this calendar ID."),
                    "limit": S.limit,
                  ], ["action"])) { a in
            if try a.action(["calendars", "events"]) == "calendars" { return try await phone("calendar.calendars") }
            return try await phone("calendar.find", a.pick(["from", "to", "query", "calendar", "limit"]))
        },

        AgentTool(name: "calendar_write", title: "Change the calendar", groups: [.personalWrite], readOnly: false, destructive: true,
                  description: "Creates, changes or deletes an event. \"update\" and \"delete\" change all repeats of the event.",
                  input: S.object([
                    "action": S.string("What to do.", ["create", "update", "delete"]),
                    "id": S.int("The event ID (update, delete)."),
                    "calendar": S.int("The calendar ID. The default is the first calendar that you can write (create)."),
                    "title": S.string("The title."),
                    "start": S.time("The start. For all-day events, YYYY-MM-DD."),
                    "end": S.time("The end. For all-day events, the day after the last day."),
                    "allDay": S.bool("An all-day event."),
                    "location": S.string("The location."),
                    "description": S.string("The description."),
                    "repeat": S.string("An RRULE, for example FREQ=WEEKLY;BYDAY=MO."),
                    "timeZone": S.string("An IANA time zone. The default is the time zone of the phone."),
                    "reminders": ["type": "array", "items": ["type": "integer"], "description": "Reminders, in minutes before the start."] as JSON,
                  ], ["action"])) { a in
            _ = try a.action(["create", "update", "delete"])
            return try await phone("calendar.edit", a.all)
        },

        AgentTool(name: "calls_read", title: "Read the call history", groups: [.personalRead], readOnly: true,
                  description: "Lists calls, the newest first.",
                  input: S.object([
                    "type": S.string("Only this type of call.", ["incoming", "outgoing", "missed"]),
                    "number": S.string("Only calls with this phone number."),
                    "since": S.time("Only calls after this time."),
                    "limit": S.limit,
                  ])) { a in try await phone("calls.log", a.pick(["type", "number", "since", "limit"])) },

        AgentTool(name: "calls_control", title: "Control phone calls", groups: [.calls], readOnly: false,
                  description: "Makes, answers, ends and rejects calls, sends keypad tones, and moves the call audio between this Mac and the phone. Returns the call state.",
                  input: S.object([
                    "action": S.string("What to do.", ["dial", "answer", "end", "reject", "audio", "keys"]),
                    "number": S.string("The phone number to call (dial)."),
                    "keys": S.string("Keypad tones: 0-9, * and # (keys). Only when the call audio is on this Mac."),
                    "route": S.string("Where to hear the call (audio).", ["mac", "phone"]),
                  ], ["action"])) { a in
            let action = try a.action(["dial", "answer", "end", "reject", "audio", "keys"])
            let number = a.str("number")
            if action == "dial", number == nil { throw AgentError("Give \"number\".") }
            if action == "audio", a.str("route") == nil { throw AgentError("Give \"route\": mac or phone.") }
            try await MainActor.run {
                let l = PhoneLink.shared
                switch action {
                case "dial": l.dial(number!)
                case "answer":
                    guard l.call?.state == "ringing" else { throw AgentError("No call rings.") }
                    l.answer()
                case "end", "reject":
                    guard l.call != nil else { throw AgentError("There is no call.") }
                    l.hangUp()
                case "keys":
                    guard let k = a.str("keys"), k.allSatisfy({ "0123456789*#".contains($0) }) else { throw AgentError("Give \"keys\" with 0-9, * and #.") }
                    guard CallAudio.shared.audioOnMac else { throw AgentError("Keypad tones work only when the call audio is on this Mac.") }
                    CallAudio.shared.sendKeys(k)
                default:
                    guard CallAudio.shared.callActive else { throw AgentError("There is no call with its audio on this Mac.") }
                    CallAudio.shared.setRoute(a.str("route") == "phone" ? .phone : .mac)
                }
            }
            try await Task.sleep(for: .seconds(1.5))
            return .json(["call": await MainActor.run { callJSON() }])
        },

        AgentTool(name: "notifications_read", title: "Read notifications", groups: [.notificationsRead], readOnly: true,
                  description: "Lists the notifications on the phone, the newest first, with their keys and actions. Chat notifications also give their last messages (messages, with the sender and the time), so you can read new chat messages without opening the app; opening the app can mark them as read. With history, gets the notifications of the last 7 days, also the removed ones, if the user turned on the history.",
                  input: S.object([
                    "app": S.string("Only notifications of this package or app name."),
                    "all": S.bool("Also ongoing and silent notifications (not with history)."),
                    "history": S.bool("The saved history of the last 7 days, not only the notifications that are on the phone now."),
                    "since": S.time("Only notifications after this time."),
                    "limit": S.int("The maximum number of notifications. The default is 100."),
                  ])) { a in try await phone("notif.list", a.pick(["app", "all", "history", "since", "limit"])) },

        AgentTool(name: "notifications_act", title: "Act on a notification", groups: [.notificationsAct], readOnly: false,
                  description: "Dismisses or opens a notification, uses one of its actions, or replies to it. To open a notification while the phone is locked, give window: the app opens in that app window on this Mac.",
                  input: S.object([
                    "key": S.string("The notification key from notifications_read."),
                    "action": S.string("What to do.", ["dismiss", "open", "action", "reply"]),
                    "index": S.int("The action index (action)."),
                    "title": S.string("The action title, if you do not give index (action)."),
                    "text": S.string("The reply text (reply), or text for an action with text input (action)."),
                    "window": S.string("Open the notification in this app window on this Mac: a package or desktop (open)."),
                  ], ["key", "action"])) { a in
            _ = try a.action(["dismiss", "open", "action", "reply"])
            return try await phone("notif.act", try await onDisplay(a.pick(["key", "action", "index", "title", "text", "window"]), a))
        },

        AgentTool(name: "apps_read", title: "Read apps", groups: [.appsRead], readOnly: true,
                  description: "\"list\" lists the installed apps that have a launcher icon (with all, also the other apps), with their package names. Open any app with apps_start. Do not decide before that an app cannot start: apps_start tells you when it cannot. \"info\" gets the version, permissions, activities and intent filters of one app.",
                  input: S.object([
                    "action": S.string("What to do.", ["list", "info"]),
                    "query": S.string("Only apps with this text in the name or package (list)."),
                    "all": S.bool("Also apps without a launcher icon (list)."),
                    "package": S.string("The package name (info)."),
                  ], ["action"])) { a in
            if try a.action(["list", "info"]) == "list" { return try await phone("apps.list", a.pick(["query", "all"]), timeout: 60) }
            return try await phone("apps.info", ["package": try a.need("package")], timeout: 60)
        },

        AgentTool(name: "apps_start", title: "Open an app", groups: [.intents], readOnly: false,
                  description: "Opens an app on the phone screen, or in an app window on this Mac (window). By default the app starts on its start screen, not on the screen where the user left it (for example an open chat), so that you do not mark messages as read by accident. This closes the screens that the app had open. On the phone screen, the phone must be unlocked; app windows work while the phone is locked.",
                  input: S.object([
                    "package": S.string("The package of the app, for example org.telegram.messenger. See apps_read."),
                    "fresh": S.bool("Start on the start screen of the app. The default is true. With false, the app shows the screen where the user left it."),
                    "window": S.string("Open the app in this app window on this Mac: a package or desktop. Open the window first with windows_control."),
                  ], ["package"])) { a in
            let pkg = try a.need("package")
            let fresh = a.j["fresh"] == nil || a.bool("fresh")
            guard let w = a.str("window") else { return try await phone("app.start", a.pick(["package", "fresh"])) }
            guard isPackageName(pkg) else {
                throw AgentError("\"package\" must be a package name, for example com.android.settings.")
            }
            // The shell user on the phone moves a task of the app to the display of the window.
            // An app start from Phone Link cannot move a task that is already on the phone screen.
            try await MainActor.run {
                let s = try stream(w)
                guard s.phase == .streaming else { throw AgentError("The window \(w) is not open yet. Try again in a moment.") }
                s.send(["t": "app.launch", "pkg": pkg, "fresh": fresh])
            }
            try await Task.sleep(for: .seconds(2.5))
            return .json(["started": pkg, "window": w, "fresh": fresh])
        },

        AgentTool(name: "intents_resolve", title: "Find activities for an intent", groups: [.appsRead], readOnly: true,
                  description: "Lists the activities that can handle an intent.",
                  input: S.object([
                    "action": S.string("The intent action, for example android.intent.action.VIEW."),
                    "data": S.string("The data URI."),
                    "type": S.string("The MIME type."),
                    "categories": S.strings("The categories."),
                    "package": S.string("Only activities of this package."),
                  ])) { a in try await phone("intent.resolve", a.pick(["action", "data", "type", "categories", "package"])) },

        AgentTool(name: "intents_start", title: "Start an activity", groups: [.intents], readOnly: false,
                  description: "Starts an activity with an intent: open an app, a URL, a share sheet, a settings page or an app screen. Only activities. The phone must be unlocked. With waitForResult, waits for the result of the activity.",
                  input: S.object([
                    "action": S.string("The intent action."),
                    "data": S.string("The data URI."),
                    "type": S.string("The MIME type."),
                    "categories": S.strings("The categories."),
                    "package": S.string("The package. Only a package opens its launcher activity."),
                    "component": S.string("package/class of the activity."),
                    "flags": S.list("Intent flags: names such as FLAG_ACTIVITY_CLEAR_TOP, or numbers."),
                    "extras": S.any("Extras: an object {key: value}, or a list of {\"key\", \"type\", \"value\"}. type is string, int, long, float, double, boolean, uri, strings or ints."),
                    "waitForResult": S.bool("Wait for the result of the activity."),
                    "timeout": S.int("The time to wait for the result, in milliseconds. The default is 120000."),
                    "window": S.string("Start the activity in this app window on this Mac (a package or desktop). It works while the phone is locked."),
                  ])) { a in
            try await phone("intent.start", try await onDisplay(a.all, a), timeout: a.bool("waitForResult") ? ms(a, "timeout", 120_000) + 15 : 30)
        },

        AgentTool(name: "clipboard_read", title: "Read the clipboard", groups: [.clipboardRead], readOnly: true,
                  description: "Gets the text or image on the clipboard of the phone. Android lets Phone Link read the clipboard only when the phone is unlocked; else you get the last text that the phone copied.",
                  input: S.object([:])) { _ in
            do {
                let r = try await AgentPhone.shared.call("clip.get", [:], timeout: 15)
                if let j = r as? JSON, let img = j.str("image") { return .image(data: img, mime: "image/png", meta: ["image": true]) }
                return .json(r)
            } catch {
                guard let c = AgentServer.shared.lastClipboard else { throw error }
                return .json(["text": c.text, "copied": iso(Int64(c.time.timeIntervalSince1970 * 1000)),
                              "note": "The last text that the phone copied. " + error.localizedDescription])
            }
        },

        AgentTool(name: "clipboard_write", title: "Set the clipboard", groups: [.clipboardWrite], readOnly: false,
                  description: "Puts text on the clipboard of the phone.",
                  input: S.object(["text": S.string("The text.")], ["text"])) { a in
            try await phone("clip.set", ["text": try a.need("text")])
        },

        AgentTool(name: "location_read", title: "Read the location", groups: [.location], readOnly: true,
                  description: "Gets the location of the phone: latitude, longitude, accuracy in meters, altitude, speed and time.",
                  input: S.object([
                    "maxAge": S.int("Use a known location that is not older than this, in milliseconds. The default is 60000."),
                    "timeout": S.int("The time to find a new location, in milliseconds. The default is 20000."),
                  ])) { a in try await phone("location.get", a.pick(["maxAge", "timeout"]), timeout: ms(a, "timeout", 20_000) + 15) },

        AgentTool(name: "files_read", title: "Read files", groups: [.filesRead], readOnly: true,
                  description: "Reads the files on the phone. Paths start at /sdcard. \"list\" lists a folder. \"stat\" gets the details of a file or folder. \"read\" reads a file: text, base64, or an image that you can see. \"find\" finds files by name under a folder. \"media\" lists photos, videos, audio or downloads from the media store, the newest first.",
                  input: S.object([
                    "action": S.string("What to do.", ["list", "stat", "read", "find", "media"]),
                    "path": S.string("The file or folder (list, stat, read, find). The default folder is /sdcard."),
                    "offset": S.int("The first byte (read)."),
                    "length": S.int("The number of bytes (read). The default and maximum is 4 MB."),
                    "encoding": S.string("text, base64, or image (read). The default is text for UTF-8 files, image for images and base64 for other files.", ["text", "base64", "image"]),
                    "query": S.string("A part of the name, or a pattern with * and ? (find). Text to find in the name (media)."),
                    "hidden": S.bool("Also hidden files and folders (find)."),
                    "deep": S.bool("Count the size of a folder (stat)."),
                    "kind": S.string("The media type (media).", ["images", "videos", "audio", "downloads", "all"]),
                    "folder": S.string("Only media in this folder, for example DCIM/Camera (media)."),
                    "since": S.time("Only media after this time (media)."),
                    "limit": S.limit,
                  ], ["action"])) { a in
            let root = "/sdcard"
            switch try a.action(["list", "stat", "read", "find", "media"]) {
            case "list":
                let r = try await FileHub.shared.call(["t": "fs.list", "path": a.str("path") ?? root], timeout: 30)
                var items = (r["items"] as? [JSON] ?? []).map(fileJSON)
                if let n = a.int("limit"), items.count > n { items = Array(items.prefix(n)) }
                return .json(["path": r["path"] ?? NSNull(), "writable": r.bool("writable"), "items": items])
            case "stat":
                let r = try await FileHub.shared.call(["t": "fs.stat", "path": try a.need("path"), "deep": a.bool("deep")], timeout: 60)
                var o = fileJSON(r["item"] as? JSON ?? [:])
                if let f = r.i64("free") { o["storageFree"] = f }
                if let t = r.i64("total") { o["storageTotal"] = t }
                return .json(o)
            case "read":
                let path = try a.need("path")
                let limit: Int64 = 4 << 20
                let length = min(Int64(a.int("length") ?? Int(limit)), limit)
                let (data, size) = try await readFile(path, offset: Int64(a.int("offset") ?? 0), length: length)
                let ext = (path as NSString).pathExtension.lowercased()
                let text = String(data: data, encoding: .utf8)
                let enc = a.str("encoding") ?? (imageTypes[ext] != nil ? "image" : text != nil && !data.contains(0) ? "text" : "base64")
                let meta: JSON = ["path": path, "size": size, "offset": a.int("offset") ?? 0, "bytes": data.count]
                switch enc {
                case "image":
                    guard let mime = imageTypes[ext] else { throw AgentError("The file is not a JPEG, PNG, GIF or WebP image.") }
                    return .image(data: data.base64EncodedString(), mime: mime, meta: meta)
                case "text":
                    guard let text else { throw AgentError("The file is not UTF-8 text. Use the encoding base64.") }
                    return .json(meta.merging(["text": text]) { $1 })
                default:
                    return .json(meta.merging(["base64": data.base64EncodedString()]) { $1 })
                }
            case "find":
                let start = a.str("path") ?? root
                let q = a.str("query") ?? ""
                let pattern = q.contains("*") || q.contains("?") ? NSPredicate(format: "SELF LIKE[c] %@", q) : nil
                let limit = a.int("limit") ?? 100
                var found: [JSON] = []
                var queue = [start]
                var dirs = 0
                while !queue.isEmpty, found.count < limit, dirs < 3000 {
                    let dir = queue.removeFirst()
                    dirs += 1
                    guard let r = try? await FileHub.shared.call(["t": "fs.list", "path": dir], timeout: 30) else { continue }
                    for it in r["items"] as? [JSON] ?? [] {
                        let name = it.str("name") ?? ""
                        if name.hasPrefix("."), !a.bool("hidden") { continue }
                        if it.bool("dir") { queue.append(it.str("path") ?? join(dir, name)) }
                        let hit = q.isEmpty || (pattern?.evaluate(with: name) ?? name.localizedCaseInsensitiveContains(q))
                        if hit { found.append(fileJSON(it)); if found.count >= limit { break } }
                    }
                }
                return .json(["items": found, "complete": queue.isEmpty])
            default:
                return try await phone("media.list", a.pick(["kind", "query", "folder", "since", "limit"]), timeout: 60)
            }
        },

        AgentTool(name: "files_write", title: "Change files", groups: [.filesWrite], readOnly: false, destructive: true,
                  description: "Changes the files on the phone. \"write\" makes or replaces a file. \"mkdir\" makes a folder. \"move\" moves or renames. \"copy\" copies. \"delete\" deletes files and folders for good.",
                  input: S.object([
                    "action": S.string("What to do.", ["write", "mkdir", "move", "copy", "delete"]),
                    "path": S.string("The file (write) or the folder (mkdir)."),
                    "content": S.string("The content of the file (write)."),
                    "encoding": S.string("The encoding of content (write). The default is text.", ["text", "base64"]),
                    "from": S.string("The source path (move, copy)."),
                    "to": S.string("The new path (move, copy)."),
                    "paths": S.strings("The files and folders to delete (delete)."),
                    "overwrite": S.bool("Replace a file that is there (write, move, copy)."),
                  ], ["action"])) { a in
            switch try a.action(["write", "mkdir", "move", "copy", "delete"]) {
            case "write":
                let (dir, name) = try split(try a.need("path"))
                let content = a.str("content") ?? ""
                let data: Data
                if a.str("encoding") == "base64" {
                    guard let d = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw AgentError("The content is not valid base64.") }
                    data = d
                } else { data = Data(content.utf8) }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneLink-agent-" + UUID().uuidString)
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await FileHub.shared.put(local: tmp, dir: dir, name: name, replace: a.bool("overwrite"))
                return .json(["written": join(dir, name), "bytes": data.count])
            case "mkdir":
                let (dir, name) = try split(try a.need("path"))
                return .json(try await FileHub.shared.call(["t": "fs.mkdir", "dir": dir, "name": name, "unique": false], timeout: 30).filter { $0.key != "t" && $0.key != "id" })
            case "move", "copy":
                let t = a.str("action") == "move" ? "fs.move" : "fs.copy"
                let r = try await FileHub.shared.call(["t": t, "from": try a.need("from"), "to": try a.need("to"), "overwrite": a.bool("overwrite")], timeout: 600)
                return .json(r.filter { $0.key != "t" && $0.key != "id" }.merging(["done": true]) { $1 })
            default:
                let paths = (a.j["paths"] as? [Any])?.compactMap { $0 as? String } ?? a.str("path").map { [$0] } ?? []
                guard !paths.isEmpty else { throw AgentError("Give \"paths\".") }
                _ = try await FileHub.shared.call(["t": "fs.delete", "paths": paths], timeout: 600)
                return .json(["deleted": paths])
            }
        },

        AgentTool(name: "files_transfer", title: "Copy files between the Mac and the phone", groups: [.filesRead, .filesWrite], readOnly: false,
                  description: "Copies a file from the phone to this Mac (toMac, needs Read files), or from this Mac to the phone (toPhone, needs Change files).",
                  input: S.object([
                    "direction": S.string("The direction.", ["toMac", "toPhone"]),
                    "from": S.string("The source file: a phone path (toMac) or a Mac path (toPhone)."),
                    "to": S.string("The target: a Mac file or folder (toMac, the default is ~/Downloads) or a phone folder (toPhone, the default is /sdcard/Download)."),
                    "overwrite": S.bool("Replace a file that is there."),
                  ], ["direction", "from"])) { a in
            let s = AgentSettings.shared
            let from = try a.need("from")
            if a.str("direction") == "toMac" {
                guard s.allows(.filesRead) else { throw AgentError("Copying to the Mac needs \"Files and photos: Read\" in Phone Link Settings > Agents.") }
                let name = (from as NSString).lastPathComponent
                var url = URL(fileURLWithPath: ((a.str("to") ?? "~/Downloads") as NSString).expandingTildeInPath)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { url.appendPathComponent(name) }
                if !a.bool("overwrite") { url = uniqueURL(url) }
                let n = try await download(from, to: url)
                return .json(["saved": url.path, "bytes": n])
            }
            guard a.str("direction") == "toPhone" else { throw AgentError("\"direction\" must be toMac or toPhone.") }
            guard s.allows(.filesWrite) else { throw AgentError("Copying to the phone needs \"Files and photos: Change\" in Phone Link Settings > Agents.") }
            let local = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), !isDir.boolValue else { throw AgentError("There is no file at \(local.path).") }
            let dir = a.str("to") ?? "/sdcard/Download"
            try await FileHub.shared.put(local: local, dir: dir, name: local.lastPathComponent, replace: a.bool("overwrite"))
            return .json(["saved": join(dir, local.lastPathComponent)])
        },

        AgentTool(name: "screen_capture", title: "Capture the screen", groups: [.screenRead], readOnly: true,
                  description: "Takes a screenshot of the phone. Use screen_read to get the elements and their coordinates.",
                  input: S.object([
                    "maxSize": S.int("The maximum width or height in pixels. The default is 1280."),
                    "format": S.string("The image format. The default is jpeg.", ["jpeg", "png"]),
                    "quality": S.int("The JPEG quality, 1 to 100. The default is 80."),
                    "window": S.string("An app window on this Mac: its package, or desktop. See windows_read. Without window, the main phone screen."),
                  ])) { a in
            let r = try await AgentPhone.shared.call("screenshot", try await onDisplay(a.pick(["maxSize", "format", "quality"]), a), timeout: 30) as? JSON ?? [:]
            guard let d = r.str("data") else { throw AgentError("The phone did not give a screenshot.") }
            var meta = r
            meta.removeValue(forKey: "data")
            meta.removeValue(forKey: "mime")
            return .image(data: d, mime: r.str("mime") ?? "image/jpeg", meta: meta)
        },

        AgentTool(name: "screen_read", title: "Read the screen", groups: [.screenRead], readOnly: true,
                  description: "Gets the elements on the screen of the phone. The default format is text: one line for each element, indented as in the tree: [id] class \"text\" desc=\"description\" {flags} @x,y (the center in pixels). The json format also gives the bounds and resource IDs. Use the ids with screen_control. The ids change at each call. With waitForText, waits until an element shows the text.",
                  input: S.object([
                    "format": S.string("text (the default) uses fewer tokens. json gives the full tree.", ["text", "json"]),
                    "windows": S.string("All windows, or only the active window. The default is all.", ["all", "active"]),
                    "waitForText": S.string("Wait until an element contains this text."),
                    "timeout": S.int("The time to wait for the text, in milliseconds."),
                    "maxNodes": S.int("The maximum number of elements. The default is 600."),
                    "window": S.string("An app window on this Mac: its package, or desktop. See windows_read. Without window, the main phone screen."),
                  ])) { a in
            let r = try await AgentPhone.shared.call("ui.tree", try await onDisplay(a.pick(["windows", "waitForText", "timeout", "maxNodes"]), a), timeout: ms(a, "timeout", 0) + 30)
            if a.str("format") == "json" { return .json(r) }
            return .text(screenText(r as? JSON ?? [:]))
        },

        AgentTool(name: "screen_control", title: "Control the screen", groups: [.screenControl], readOnly: false,
                  description: "Acts on the screen of the phone. Give element (an id from screen_read) with the action click, long_click, focus, set_text (with text), clear, scroll_forward, scroll_backward, select, expand, collapse, dismiss, copy, paste, cut or show_on_screen. Or give coordinates in pixels with the action tap, double_tap, long_press, swipe or drag (with x2 and y2). Or use the action key (with key: enter, backspace, delete, left, right, select_all, copy, paste, cut or escape) or type (with text) on the focused text field. Or use a global action: back, home, recents, notifications, quick_settings, lock, power, screenshot or wake (turns the screen on). With window, the action applies to that app window on this Mac; the global actions are then only back and home.",
                  input: S.object([
                    "action": S.string("What to do."),
                    "element": S.int("The element id from screen_read."),
                    "x": S.number("X in pixels."),
                    "y": S.number("Y in pixels."),
                    "x2": S.number("The end X (swipe, drag)."),
                    "y2": S.number("The end Y (swipe, drag)."),
                    "duration": S.int("The gesture time in milliseconds."),
                    "key": S.string("The key (key).", ["enter", "backspace", "delete", "left", "right", "select_all", "copy", "paste", "cut", "escape"]),
                    "text": S.string("The text (type, set_text)."),
                    "window": S.string("An app window on this Mac: its package, or desktop. See windows_read. Without window, the main phone screen."),
                  ], ["action"])) { a in
            let action = try a.need("action")
            if action == "wake" {
                await MainActor.run { PhoneLink.shared.input(["t": "input.wake"]) }
                return .json(["done": true])
            }
            // In a window, keys, text and back go to the virtual display through the window stream.
            if let w = a.str("window"), !a.has("element"), ["back", "home", "key", "type"].contains(action) {
                try await MainActor.run {
                    let s = try stream(w)
                    guard s.phase == .streaming else { throw AgentError("The window \(w) is not open yet.") }
                    switch action {
                    case "back": s.back()
                    case "home":
                        guard s.isDesktop else { throw AgentError("Only the desktop window has home. Use windows_control to open another app.") }
                        s.home()
                    case "key": s.send(["t": "input.key", "key": try a.need("key")])
                    default: s.send(["t": "input.text", "text": try a.need("text")])
                    }
                }
                return .json(["done": true])
            }
            let elementActions = ["click", "long_click", "focus", "set_text", "clear", "scroll_forward", "scroll_backward", "select", "expand", "collapse", "dismiss", "copy", "paste", "cut", "show_on_screen"]
            if elementActions.contains(action), !a.has("element") {
                throw AgentError("The action \(action) needs element: an id from screen_read.")
            }
            if a.has("window"), !a.has("element"), ["recents", "notifications", "quick_settings", "lock", "power", "screenshot"].contains(action) {
                throw AgentError("Use \"\(action)\" without window.")
            }
            return try await phone("ui.act", try await onDisplay(a.all, a), timeout: 60)
        },

        AgentTool(name: "windows_read", title: "List app windows", groups: [.screenRead], readOnly: true,
                  description: "Lists the phone app windows that are open on this Mac. Each window shows one app (or the phone desktop) on its own virtual display of the phone. Give the window to screen_capture, screen_read, screen_control and intents_start.",
                  input: S.object([:])) { _ in
            .json(await MainActor.run { ["windows": AppStream.open.map(windowJSON)] as JSON })
        },

        AgentTool(name: "windows_control", title: "Open apps in windows on this Mac", groups: [.screenControl], readOnly: false,
                  description: "Opens a phone app in its own window on this Mac (action open), or the phone desktop. The app runs on a separate virtual display of the phone: the phone screen stays free, and the window works while the phone is locked. Also closes, focuses and resizes these windows. Then give the window to screen_read, screen_control, screen_capture, intents_start and apps_start. To open an app on the phone screen, use apps_start. Needs USB or wireless debugging.",
                  input: S.object([
                    "action": S.string("What to do.", ["open", "close", "focus", "resize"]),
                    "window": S.string("The package of the app, for example com.whatsapp, or desktop. For close, focus and resize: a window from windows_read."),
                    "width": S.int("The width in points (resize). One point is one dp on the phone."),
                    "height": S.int("The height in points (resize)."),
                  ], ["action", "window"])) { a in
            let action = try a.action(["open", "close", "focus", "resize"])
            // "package" is a common guess for the name of the argument.
            guard let w = a.str("window") ?? a.str("package") else { throw AgentError("Give \"window\": the package of the app, for example com.whatsapp, or desktop.") }
            let pkg = w == "desktop" ? AppStream.desktopID : w
            if action == "open" {
                guard pkg == AppStream.desktopID || isPackageName(pkg) else {
                    throw AgentError("\"window\" must be a package name, for example com.whatsapp, or desktop. Use apps_read to find the package.")
                }
                try await MainActor.run {
                    guard PhoneLink.shared.adbSerial != nil else {
                        throw AgentError("App windows need USB debugging or wireless debugging. The user can turn it on in Phone Link Settings > Connections.")
                    }
                }
                if pkg != AppStream.desktopID {
                    let r = try await adb("pm path " + pkg)
                    if r.status != 0 || !r.output.contains("package:") {
                        throw AgentError("\(pkg) is not installed on the phone. Use apps_read with action list to find the package.")
                    }
                }
                await MainActor.run {
                    if let s = AppStream.open.first(where: { $0.pkg == pkg }), let win = s.window { win.makeKeyAndOrderFront(nil) }
                    else { Router.shared.openApp(pkg) }
                }
                let end = Date().addingTimeInterval(30)
                while Date() < end {
                    let r: JSON? = try await MainActor.run {
                        guard let s = AppStream.open.first(where: { $0.pkg == pkg }) else { return nil }
                        if case .failed(let m) = s.phase { throw AgentError(m) }
                        return s.phase == .streaming && s.displayId != nil ? windowJSON(s) : nil
                    }
                    if let r { return .json(r) }
                    try await Task.sleep(for: .milliseconds(300))
                }
                throw AgentError("The window of \(w) did not show the app in 30 seconds. " + (await windowDiagnosis(pkg)))
            }
            return .json(try await MainActor.run { () -> JSON in
                let s = try stream(w)
                switch action {
                case "close":
                    guard let win = s.window else { throw AgentError("The window is not on the screen.") }
                    win.close()
                    return ["closed": w]
                case "focus":
                    NSApp.activate(ignoringOtherApps: true)
                    s.window?.makeKeyAndOrderFront(nil)
                default:
                    guard let width = a.int("width"), let height = a.int("height") else { throw AgentError("Give \"width\" and \"height\".") }
                    s.window?.setContentSize(NSSize(width: max(240, width), height: max(320, height)))
                }
                return windowJSON(s)
            })
        },

        AgentTool(name: "media_control", title: "Control media", groups: [.media], readOnly: false,
                  description: "Controls the media that plays on the phone, or sets the media volume.",
                  input: S.object([
                    "action": S.string("What to do.", ["play", "pause", "toggle", "next", "previous", "seek", "volume"]),
                    "position": S.int("The position in milliseconds (seek)."),
                    "level": S.int("The volume level (volume). status_read gives the range."),
                  ], ["action"])) { a in
            let action = try a.action(["play", "pause", "toggle", "next", "previous", "seek", "volume"])
            if action == "volume" {
                guard let level = a.int("level") else { throw AgentError("Give \"level\".") }
                return try await phone("settings.set", ["name": "volume", "stream": "media", "level": level])
            }
            var m: JSON = ["t": "media.cmd", "action": action]
            if action == "seek" {
                guard let p = a.int("position") else { throw AgentError("Give \"position\".") }
                m["position"] = p
            }
            PhoneLink.shared.send(m)
            try await Task.sleep(for: .seconds(0.8))
            let s = try await AgentPhone.shared.call("status") as? JSON ?? [:]
            return .json(["media": s["media"] ?? NSNull()])
        },

        AgentTool(name: "settings_read", title: "Read device settings", groups: [.settingsRead], readOnly: true,
                  description: "Gets Wi-Fi, Bluetooth, airplane mode, mobile data, location, hotspot, private Wi-Fi, brightness, rotation, the screen timeout (milliseconds), Do Not Disturb, flashlight, the ringer and the volume.",
                  input: S.object([:])) { _ in try await phone("settings.get") },

        AgentTool(name: "settings_write", title: "Change device settings", groups: [.settingsWrite], readOnly: false,
                  description: "Changes a setting on the phone. wifi, bluetooth, airplane, mobileData, location, screenTimeout, brightness, rotation and hotspot need USB or wireless debugging. Turning off Wi-Fi or Bluetooth, or turning on airplane mode, can stop the connection to this Mac. Turning off mobile data stops the internet of the phone hotspot. privateWifi makes a Wi-Fi network between the phone and the Mac (only with a Bluetooth connection).",
                  input: S.object([
                    "name": S.string("The setting.", ["wifi", "bluetooth", "airplane", "mobileData", "location", "dnd", "flashlight", "ringer", "volume", "brightness", "rotation", "screenTimeout", "hotspot", "privateWifi"]),
                    "on": S.bool("On or off (wifi, bluetooth, airplane, mobileData, location, dnd, flashlight, rotation, hotspot, privateWifi). For rotation, on is auto-rotate."),
                    "timeout": S.int("The screen timeout in milliseconds, 10000 to 1800000 (screenTimeout)."),
                    "mode": S.string("The ringer mode (ringer).", ["normal", "vibrate", "silent"]),
                    "stream": S.string("The volume stream (volume). The default is media.", ["media", "ring", "notification", "alarm", "call"]),
                    "level": S.int("The volume level (volume), or the brightness 0 to 255 (brightness)."),
                    "auto": S.bool("Adaptive brightness (brightness)."),
                  ], ["name"])) { a in
            let name = try a.need("name")
            func on() throws -> Bool {
                guard a.has("on") else { throw AgentError("Give \"on\".") }
                return a.bool("on")
            }
            func shell(_ cmd: String) async throws {
                let r = try await adb(cmd)
                if r.status != 0 { throw AgentError("The phone did not make the change: " + r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            switch name {
            case "dnd": _ = try await AgentPhone.shared.call("settings.set", ["name": "dnd", "on": try on()])
            case "flashlight": _ = try await AgentPhone.shared.call("settings.set", ["name": "torch", "on": try on()])
            case "ringer": _ = try await AgentPhone.shared.call("settings.set", ["name": "ringer", "mode": try a.need("mode")])
            case "volume":
                guard let level = a.int("level") else { throw AgentError("Give \"level\".") }
                _ = try await AgentPhone.shared.call("settings.set", ["name": "volume", "stream": a.str("stream") ?? "media", "level": level])
            case "wifi": try await shell("svc wifi " + (try on() ? "enable" : "disable"))
            case "bluetooth": try await shell("svc bluetooth " + (try on() ? "enable" : "disable"))
            case "airplane": try await shell("cmd connectivity airplane-mode " + (try on() ? "enable" : "disable"))
            case "mobileData": try await shell("svc data " + (try on() ? "enable" : "disable"))
            case "location": try await shell("cmd location set-location-enabled " + (try on() ? "true" : "false"))
            case "screenTimeout":
                guard let t = a.int("timeout"), (10_000...1_800_000).contains(t) else { throw AgentError("Give \"timeout\" from 10000 to 1800000 milliseconds.") }
                try await shell("settings put system screen_off_timeout \(t)")
            case "rotation": try await shell("settings put system accelerometer_rotation " + (try on() ? "1" : "0"))
            case "brightness":
                if a.has("auto") { try await shell("settings put system screen_brightness_mode " + (a.bool("auto") ? "1" : "0")) }
                if let level = a.int("level") {
                    try await shell("settings put system screen_brightness_mode 0 && settings put system screen_brightness \(max(0, min(255, level)))")
                }
                if !a.has("auto"), a.int("level") == nil { throw AgentError("Give \"level\" or \"auto\".") }
            case "hotspot":
                let want = try on()
                guard AdbAgent.shared.can("hotspot") else { throw AgentError("This needs USB debugging or wireless debugging and the Phone Link shell helper.") }
                let err: String? = await withCheckedContinuation { c in
                    DispatchQueue.main.async { AdbAgent.shared.hotspot(on: want) { c.resume(returning: $0) } }
                }
                if let err { throw AgentError(err) }
            case "privateWifi":
                let want = try on()
                try await MainActor.run {
                    let p = PrivateWifi.shared
                    if want {
                        guard p.canStart else { throw AgentError("Private Wi-Fi can start only when the Mac connects to the phone through Bluetooth.") }
                        p.userStart()
                    } else { p.stop() }
                }
            default:
                throw AgentError("Phone Link cannot change \"\(name)\".")
            }
            try await Task.sleep(for: .seconds(1))
            return try await phone("settings.get")
        },

        AgentTool(name: "alert_show", title: "Alert on the phone", groups: [.alerts], readOnly: false,
                  description: "\"notify\" shows a notification on the phone. \"ring\" rings the phone at full volume, also in silent mode, until \"stop\" or until the user stops it.",
                  input: S.object([
                    "action": S.string("What to do.", ["notify", "ring", "stop"]),
                    "title": S.string("The title (notify)."),
                    "text": S.string("The text (notify)."),
                    "id": S.int("A notification ID. A new notification with the same ID replaces the old one (notify)."),
                  ], ["action"])) { a in
            switch try a.action(["notify", "ring", "stop"]) {
            case "notify": return try await phone("notify.post", a.pick(["title", "text", "id"]))
            case "ring": await MainActor.run { PhoneLink.shared.ring() }
            default: await MainActor.run { PhoneLink.shared.stopRing() }
            }
            return .json(["done": true])
        },

        AgentTool(name: "shell_run", title: "Run a shell command", groups: [.shell], readOnly: false, destructive: true,
                  description: "Runs a command in the shell of the phone with adb (as the shell user). Needs USB or wireless debugging.",
                  input: S.object([
                    "command": S.string("The command, for example \"dumpsys battery\"."),
                    "timeout": S.int("The maximum time in milliseconds. The default is 30000, the maximum is 600000."),
                  ], ["command"])) { a in
            let cmd = try a.need("command")
            let r = try await adb(cmd, timeout: min(600, max(1, ms(a, "timeout", 30_000))))
            var out = r.output
            var cut = false
            if out.utf8.count > 200_000 { out = String(out.prefix(200_000)); cut = true }
            return .json(["exitCode": r.status, "output": out, "truncated": cut])
        },

        AgentTool(name: "events_wait", title: "Wait for events", groups: [.events], readOnly: true,
                  description: "Waits for events from the phone and returns them with a cursor. Give the cursor in the next call to get only newer events. Without a cursor, returns only events that come after the call. Types: message.new, notification.posted, notification.removed, call.state, call.missed, clipboard.changed, status, media, screen.locked. You get only events of the groups that are on.",
                  input: S.object([
                    "types": S.strings("Only these event types. A prefix such as \"notification\" also works."),
                    "cursor": S.int("The cursor from the last call."),
                    "timeout": S.int("The maximum time to wait, in milliseconds. The default is 30000, the maximum is 300000."),
                  ])) { a in
            let server = AgentServer.shared
            let cursor = a.int("cursor") ?? server.eventCursor
            let types = Set((a.j["types"] as? [Any])?.compactMap { $0 as? String } ?? [])
            let end = Date().addingTimeInterval(min(300, ms(a, "timeout", 30_000)))
            while true {
                let list = server.events(after: cursor, types: types)
                if !list.isEmpty || Date() >= end {
                    return .json([
                        "cursor": list.last?.seq ?? max(cursor, server.eventCursor),
                        "events": list.map { ["type": $0.type, "time": iso(Int64($0.time.timeIntervalSince1970 * 1000)), "data": $0.data] as JSON },
                    ])
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        },

        AgentTool(name: "content_read", title: "Query a content provider", groups: [.contentRead], readOnly: true,
                  description: "Advanced. Queries a content:// URI on the phone, for example content://settings/system. Phone Link needs the permission of the provider.",
                  input: S.object([
                    "uri": S.string("The content URI."),
                    "projection": S.strings("The columns."),
                    "selection": S.string("The WHERE clause, with ? for arguments."),
                    "args": S.strings("The selection arguments."),
                    "sort": S.string("The ORDER BY clause."),
                    "limit": S.limit,
                  ], ["uri"])) { a in try await phone("cp.query", a.pick(["uri", "projection", "selection", "args", "sort", "limit"])) },

        AgentTool(name: "content_write", title: "Change a content provider", groups: [.contentWrite], readOnly: false, destructive: true,
                  description: "Advanced. Inserts, updates or deletes rows of a content:// URI on the phone.",
                  input: S.object([
                    "action": S.string("What to do.", ["insert", "update", "delete"]),
                    "uri": S.string("The content URI."),
                    "values": S.dict("The column values (insert, update)."),
                    "selection": S.string("The WHERE clause, with ? for arguments (update, delete)."),
                    "args": S.strings("The selection arguments."),
                  ], ["action", "uri"])) { a in
            _ = try a.action(["insert", "update", "delete"])
            return try await phone("cp.modify", a.pick(["action", "uri", "values", "selection", "args"]))
        },
    ]
}

/// MCP resources: the status, the notifications and the conversations.
enum AgentResources {
    static func list() -> [JSON] {
        let s = AgentSettings.shared
        var r: [JSON] = []
        if s.allows(.status) {
            r.append(["uri": "phone://status", "name": "status", "title": "Phone status", "mimeType": "application/json",
                      "description": "Battery, network, screen, media and the current call."])
        }
        if s.allows(.notificationsRead) {
            r.append(["uri": "phone://notifications", "name": "notifications", "title": "Notifications", "mimeType": "application/json",
                      "description": "The notifications on the phone."])
        }
        return r
    }

    static func templates() -> [JSON] {
        guard AgentSettings.shared.allows(.messagesRead) else { return [] }
        return [["uriTemplate": "phone://conversations/{id}", "name": "conversation", "title": "A conversation", "mimeType": "application/json",
                 "description": "The last 50 messages of a conversation. The id comes from messages_read."]]
    }

    static func read(_ uri: String) async throws -> String {
        let s = AgentSettings.shared
        let data: Any
        if uri == "phone://status", s.allows(.status) {
            data = try await AgentTools.status()
        } else if uri == "phone://notifications", s.allows(.notificationsRead) {
            data = try await AgentPhone.shared.call("notif.list")
        } else if uri.hasPrefix("phone://conversations/"), s.allows(.messagesRead), let id = Int64(uri.dropFirst("phone://conversations/".count)) {
            data = try await AgentPhone.shared.call("sms.read", ["thread": id, "limit": 50])
        } else {
            throw AgentError("Unknown resource, or the resource is off: " + uri)
        }
        return AgentOutput.encode(data)
    }
}
