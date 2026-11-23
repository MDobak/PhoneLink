import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileError: LocalizedError, Equatable {
    let msg: String
    var code: String?
    var errorDescription: String? { msg }
}

struct RemoteFile: Identifiable, Hashable {
    let name: String
    let path: String
    let dir: Bool
    let size: Int64
    let mtime: Date
    var id: String { path }

    init(name: String, path: String, dir: Bool, size: Int64, mtime: Date) {
        self.name = name; self.path = path; self.dir = dir; self.size = size; self.mtime = mtime
    }

    init(_ j: JSON) {
        self.init(name: j.str("name") ?? "", path: j.str("path") ?? "", dir: j.bool("dir"),
                  size: j.i64("size") ?? 0, mtime: Date(ms: j.i64("mtime") ?? 0))
    }

    var type: UTType? { dir ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) }
    var kind: String { dir ? "Folder" : (type?.localizedDescription ?? "Document") }
}

struct FileLocation: Identifiable, Hashable {
    let name: String
    let path: String
    let symbol: String
    var id: String { path }
}

final class Transfer: ObservableObject, Identifiable {
    enum State { case active, done, failed, cancelled }
    let id: UInt32
    let name: String
    let toPhone: Bool
    @Published var total: Int64
    @Published var done: Int64 = 0
    /// Main thread only. Changes also refresh FileHub views.
    @Published var state: State = .active {
        didSet { if state != oldValue { FileHub.shared.objectWillChange.send() } }
    }
    @Published var error: String?
    @Published var url: URL?

    init(id: UInt32, name: String, toPhone: Bool, total: Int64) {
        self.id = id; self.name = name; self.toPhone = toPhone; self.total = total
    }

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var isActive: Bool { state == .active }
}

/// File browsing and transfers. The wire protocol is in Transfers.kt on the phone.
/// Every path from the phone is resolved (symlinks too) and must stay inside a shared folder.
final class FileHub: ObservableObject {
    static let shared = FileHub()

    private init() {
        DispatchQueue.global(qos: .utility).async { Self.removeOldCopies() }
    }

    /// Other apps may still use a recent copy (after a drag, for example), so only remove folders older than a day.
    private static func removeOldCopies() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let limit = Date().addingTimeInterval(-86_400)
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for n in names where n.hasPrefix("PhoneLink-") {
            let u = tmp.appendingPathComponent(n)
            if let d = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, d < limit {
                try? fm.removeItem(at: u)
            }
        }
    }

    // MARK: UI state (main thread)

    @Published private(set) var roots: [FileLocation] = []
    @Published private(set) var rootsError: FileError?
    @Published private(set) var place: String?
    @Published private(set) var location: FileLocation?
    @Published private(set) var items: [RemoteFile] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var writable = false
    @Published private(set) var transfers: [Transfer] = []
    private var history: [FileLocation] = []
    private var historyIndex = -1

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }
    var activeCount: Int { transfers.filter(\.isActive).count }

    var favorites: [FileLocation] {
        guard let r = roots.first else { return [] }
        return [("Download", "Download", "arrow.down.circle"), ("Camera", "DCIM", "camera"),
                ("Pictures", "Pictures", "photo"), ("Documents", "Documents", "doc"), ("Music", "Music", "music.note")]
            .map { FileLocation(name: $0.0, path: r.path + "/" + $0.1, symbol: $0.2) }
    }

    // MARK: Transfer state (any thread, guarded by lock)

    private final class Sending {
        var cancelled = false
        let transfer: Transfer?
        private let lock = NSLock()
        /// nil on success, else the error text. Called off the main thread.
        var onDone: ((String?) -> Void)?
        /// Both the link queue and the send queue can call this; only the first call counts.
        func complete(_ err: String?) {
            lock.lock()
            let d = onDone
            onDone = nil
            lock.unlock()
            d?(err)
        }
        init(_ t: Transfer?) { transfer = t }
    }

    /// Receives part of a phone file for the Finder drive. Called on the link queue.
    final class ReadSink {
        /// Total size, first byte, byte count.
        var onMeta: ((Int64, Int64, Int64) -> Void)?
        var onData: ((Data) -> Void)?
        var onEnd: ((FileError?) -> Void)?
        fileprivate var started = false
    }

    private final class Incoming {
        let handle: FileHandle
        let tmp: URL
        let dir: URL
        let name: String
        var expected: Int64
        var received: Int64 = 0
        let transfer: Transfer?
        let replyDone: Bool
        let openWhenDone: Bool
        var lastUI = Date.distantPast
        var onDone: ((URL?) -> Void)?
        func complete(_ u: URL?) { let d = onDone; onDone = nil; d?(u) }
        init(handle: FileHandle, tmp: URL, dir: URL, name: String, expected: Int64, transfer: Transfer?, replyDone: Bool, openWhenDone: Bool) {
            self.handle = handle; self.tmp = tmp; self.dir = dir; self.name = name; self.expected = expected
            self.transfer = transfer; self.replyDone = replyDone; self.openWhenDone = openWhenDone
        }
    }

    private let lock = NSLock()
    private var nextId: UInt32 = 0x8000_0000
    private var pending: [UInt32: (JSON) -> Void] = [:]
    private var incoming: [UInt32: Incoming] = [:]
    private var sending: [UInt32: Sending] = [:]
    private var adbJobs: [UInt32: AdbProcess] = [:]
    private var reads: [UInt32: ReadSink] = [:]
    /// Reply handlers for call(). They run on the link queue, so they work while the main thread waits.
    private var calls: [UInt32: (JSON) -> Void] = [:]
    private let chunk = 256 * 1024

    private var link: PhoneLink { PhoneLink.shared }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private func newId() -> UInt32 {
        locked {
            nextId = nextId &+ 1
            if nextId < 0x8000_0000 { nextId = 0x8000_0001 }
            return nextId
        }
    }

    private static func id(_ j: JSON) -> UInt32 { UInt32(truncatingIfNeeded: j.i64("id") ?? 0) }

    // MARK: Settings

    static var receiveFolder: URL {
        if let p = UserDefaults.standard.string(forKey: "receiveFolder"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static var sharedFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sharedFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "sharedFolders") }
    }

    private var shareOn: Bool { UserDefaults.standard.bool(forKey: "shareFolders") }
    private var shareWritable: Bool { UserDefaults.standard.bool(forKey: "shareWritable") }
    private var receiveOn: Bool { UserDefaults.standard.bool(forKey: "receiveFiles") }

    private func sharedRoots() -> [URL] {
        guard shareOn else { return [] }
        return Self.sharedFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
    }

    private func resolve(_ path: String) throws -> URL {
        guard shareOn else { throw FileError(msg: "This Mac does not share folders.") }
        let u = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        for r in sharedRoots() where u.path == r.path || u.path.hasPrefix(r.path.hasSuffix("/") ? r.path : r.path + "/") {
            return u
        }
        throw FileError(msg: "This location is not available.")
    }

    static func safeName(_ raw: String) -> String {
        var n = raw.components(separatedBy: "/").last ?? ""
        n = n.components(separatedBy: "\\").last ?? ""
        n = String(n.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init))
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        n = String(n.prefix(200))
        return n.isEmpty || n == "." || n == ".." ? "file" : n
    }

    private static func unique(_ dir: URL, _ name: String) -> URL {
        var u = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return u
    }

    // MARK: Messages from the phone (link queue)

    func handle(_ j: JSON) {
        let id = Self.id(j)
        if let sink = locked({ reads[id] }) { handleRead(id, sink, j); return }
        if j.str("t") == "fs.result" || j.str("t") == "fs.error", let cb = locked({ calls.removeValue(forKey: id) }) { cb(j); return }
        switch j.str("t") {
        case "fs.roots":
            let items: [JSON] = sharedRoots().map { ["name": FileManager.default.displayName(atPath: $0.path), "path": $0.path, "dir": true] }
            link.send(["t": "fs.result", "id": wire(id), "items": items])
        case "fs.list":
            do {
                let dir = try resolve(j.str("path") ?? "")
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                let items: [JSON] = urls.map { u in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    return ["name": u.lastPathComponent, "path": u.path, "dir": v?.isDirectory ?? false,
                            "size": v?.fileSize ?? 0, "mtime": Int64((v?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)]
                }
                link.send(["t": "fs.result", "id": wire(id), "path": dir.path,
                           "writable": shareWritable && FileManager.default.isWritableFile(atPath: dir.path), "items": items])
            } catch { sendError(id, error) }
        case "fs.get": serve(id, path: j.str("path") ?? "")
        case "fs.put": receive(id, j)
        case "fs.end": finishIncoming(id)
        case "fs.cancel":
            let (s, inc) = locked { (sending.removeValue(forKey: id), incoming.removeValue(forKey: id)) }
            s?.cancelled = true
            // put(local:dir:name:replace:) waits for this call.
            s?.complete("The phone stopped the copy.")
            if let inc { abort(inc) }
            if let t = s?.transfer ?? inc?.transfer { onMain { if t.isActive { t.state = .cancelled } } }

        case "fs.result":
            if let cb = locked({ pending.removeValue(forKey: id) }) { onMain { cb(j) } }
        case "fs.meta":
            if let inc = locked({ incoming[id] }), let size = j.i64("size") {
                inc.expected = size
                if let t = inc.transfer { onMain { t.total = size } }
            }
        case "fs.done":
            if let s = locked({ sending.removeValue(forKey: id) }) {
                s.complete(nil)
                if let t = s.transfer { onMain { t.state = .done; t.done = max(t.done, t.total) } }
            }
        case "fs.error":
            let msg = j.str("msg") ?? "Unknown error"
            let (s, inc, cb) = locked { (sending.removeValue(forKey: id), incoming.removeValue(forKey: id), pending.removeValue(forKey: id)) }
            s?.cancelled = true
            s?.complete(msg)
            if let inc { abort(inc) }
            if let t = s?.transfer ?? inc?.transfer { onMain { t.state = .failed; t.error = msg } }
            if let cb { onMain { cb(j) } }
        default: break
        }
    }

    func onChunk(_ id: UInt32, _ data: Data) {
        if let sink = locked({ reads[id] }) { sink.onData?(data); return }
        guard let inc = locked({ incoming[id] }) else { return }
        do {
            try inc.handle.write(contentsOf: data)
            inc.received += Int64(data.count)
            if let t = inc.transfer, Date().timeIntervalSince(inc.lastUI) > 0.1 {
                inc.lastUI = Date()
                let n = inc.received
                onMain { t.done = n }
            }
        } catch {
            locked { _ = incoming.removeValue(forKey: id) }
            abort(inc)
            link.send(["t": "fs.cancel", "id": wire(id)])
            if inc.replyDone { sendError(id, error) }
            if let t = inc.transfer { onMain { t.state = .failed; t.error = error.localizedDescription } }
        }
    }

    func sessionEnded() {
        let (ins, outs, cbs, sinks, waits) = locked { () -> ([Incoming], [Sending], [(JSON) -> Void], [ReadSink], [(JSON) -> Void]) in
            defer { incoming = [:]; sending = [:]; pending = [:]; reads = [:]; calls = [:] }
            return (Array(incoming.values), Array(sending.values), Array(pending.values), Array(reads.values), Array(calls.values))
        }
        waits.forEach { $0(["t": "fs.error", "msg": "The phone disconnected."]) }
        ins.forEach { abort($0) }
        outs.forEach { $0.cancelled = true; $0.complete("The phone disconnected.") }
        sinks.forEach { $0.onEnd?(FileError(msg: "The phone disconnected.")) }
        let ts = ins.compactMap(\.transfer) + outs.compactMap(\.transfer)
        onMain {
            ts.filter(\.isActive).forEach { $0.state = .failed; $0.error = "The phone disconnected." }
            cbs.forEach { $0(["t": "fs.error", "msg": "The phone disconnected."]) }
        }
    }

    private func wire(_ id: UInt32) -> Int { Int(Int32(bitPattern: id)) }

    private func sendError(_ id: UInt32, _ e: Error) {
        link.send(["t": "fs.error", "id": wire(id), "msg": (e as? FileError)?.msg ?? e.localizedDescription])
    }

    private func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    private func serve(_ id: UInt32, path: String) {
        let url: URL
        do {
            url = try resolve(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                throw FileError(msg: "This item is not a file.")
            }
        } catch { sendError(id, error); return }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let t = Transfer(id: id, name: url.lastPathComponent, toPhone: true, total: size)
        t.url = url
        let s = Sending(t)
        locked { sending[id] = s }
        onMain { self.transfers.insert(t, at: 0) }
        DispatchQueue.global(qos: .userInitiated).async {
            self.link.send(["t": "fs.meta", "id": self.wire(id), "name": url.lastPathComponent, "size": size])
            do {
                try self.stream(id, url: url, sending: s)
                if !s.cancelled {
                    self.link.send(["t": "fs.end", "id": self.wire(id)])
                    self.onMain { t.state = .done; t.done = t.total }
                }
            } catch {
                if !s.cancelled { self.sendError(id, error) }
                self.onMain { t.state = .failed; t.error = error.localizedDescription }
            }
            self.locked { _ = self.sending.removeValue(forKey: id) }
        }
    }

    /// Keeps at most 4 MB in flight. Runs on a background queue.
    private func stream(_ id: UInt32, url: URL, sending s: Sending) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let window = DispatchSemaphore(value: 16)
        var head = Data([3])
        var be = id.bigEndian
        head.append(Data(bytes: &be, count: 4))
        var sent: Int64 = 0
        var lastUI = Date.distantPast
        while !s.cancelled {
            guard let d = try fh.read(upToCount: chunk), !d.isEmpty else { break }
            window.wait()
            link.sendRaw(head + d) { window.signal() }
            sent += Int64(d.count)
            if let t = s.transfer, Date().timeIntervalSince(lastUI) > 0.1 {
                lastUI = Date()
                let n = sent
                onMain { t.done = n }
            }
            if !link.isSessionOpen { throw FileError(msg: "The phone disconnected.") }
        }
    }

    private func receive(_ id: UInt32, _ j: JSON) {
        do {
            let name = Self.safeName(j.str("name") ?? "")
            let dir: URL
            if let d = j.str("dir") {
                dir = try resolve(d)
                guard shareWritable else { throw FileError(msg: "This Mac does not let the phone add files here.") }
            } else {
                guard receiveOn else { throw FileError(msg: "This Mac does not receive files. Turn it on in Phone Link Settings.") }
                dir = Self.receiveFolder
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let inc = try makeIncoming(dir: dir, name: name, expected: j.i64("size") ?? -1, toPhone: false, replyDone: true, open: false, id: id)
            locked { incoming[id] = inc }
        } catch { sendError(id, error) }
    }

    private func makeIncoming(dir: URL, name: String, expected: Int64, toPhone: Bool, replyDone: Bool, open: Bool, id: UInt32,
                              transfer: Transfer? = nil) throws -> Incoming {
        let tmp = dir.appendingPathComponent(".\(name).\(id).phonelink-part")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FileError(msg: "Cannot save the file in \(dir.lastPathComponent).")
        }
        let fh = try FileHandle(forWritingTo: tmp)
        let t = transfer ?? Transfer(id: id, name: name, toPhone: toPhone, total: expected)
        if transfer == nil { onMain { self.transfers.insert(t, at: 0) } } else { onMain { t.done = 0 } }
        return Incoming(handle: fh, tmp: tmp, dir: dir, name: name, expected: expected, transfer: t, replyDone: replyDone, openWhenDone: open)
    }

    private func finishIncoming(_ id: UInt32) {
        guard let inc = locked({ incoming.removeValue(forKey: id) }) else { return }
        do {
            try inc.handle.close()
            if inc.expected >= 0, inc.received != inc.expected { throw FileError(msg: "The file is incomplete.") }
            let dest = Self.unique(inc.dir, inc.name)
            try FileManager.default.moveItem(at: inc.tmp, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
            if inc.replyDone { link.send(["t": "fs.done", "id": wire(id), "name": dest.lastPathComponent]) }
            inc.complete(dest)
            let n = inc.received
            onMain {
                if let t = inc.transfer { t.done = n; t.total = n; t.url = dest; t.state = .done }
                if inc.replyDone { Notifier.shared.postFile(name: dest.lastPathComponent, url: dest, from: self.link.phoneName) }
                if inc.openWhenDone { NSWorkspace.shared.open(dest) }
            }
        } catch {
            abort(inc)
            if inc.replyDone { sendError(id, error) }
            if let t = inc.transfer { onMain { t.state = .failed; t.error = error.localizedDescription } }
        }
    }

    private func abort(_ inc: Incoming) {
        inc.complete(nil)
        try? inc.handle.close()
        try? FileManager.default.removeItem(at: inc.tmp)
    }

    // MARK: Browse the phone (main thread)

    private func request(_ t: String, path: String?, _ cb: @escaping (JSON) -> Void) {
        guard link.sessionConnected else { cb(["t": "fs.error", "msg": "The phone is not connected."]); return }
        let id = newId()
        locked { pending[id] = cb }
        var j: JSON = ["t": t, "id": wire(id)]
        if let path { j["path"] = path }
        link.send(j)
    }

    func loadRoots() {
        if PhoneLink.isDemo { return }
        request("fs.roots", path: nil) { r in
            if r.str("t") == "fs.error" {
                self.rootsError = FileError(msg: r.str("msg") ?? "Unknown error", code: r.str("code"))
                self.roots = []
                return
            }
            self.rootsError = nil
            self.roots = (r["items"] as? [JSON] ?? []).map {
                let f = RemoteFile($0)
                return FileLocation(name: f.name, path: f.path, symbol: f.name == "Internal storage" ? "internaldrive" : "sdcard")
            }
            if self.location == nil, let first = self.roots.first { self.go(first) }
        }
    }

    func go(_ loc: FileLocation) {
        place = loc.path
        history = [loc]
        historyIndex = 0
        load(loc)
    }

    func open(_ f: RemoteFile) {
        guard f.dir else { download([f], open: true); return }
        let loc = FileLocation(name: f.name, path: f.path, symbol: "folder")
        history = Array(history.prefix(historyIndex + 1)) + [loc]
        historyIndex = history.count - 1
        load(loc)
    }

    func back() { guard canGoBack else { return }; historyIndex -= 1; load(history[historyIndex]) }

    var parentLocation: FileLocation? {
        guard let l = location, !l.path.hasPrefix("media:"), !roots.contains(where: { $0.path == l.path }) else { return nil }
        let p = (l.path as NSString).deletingLastPathComponent
        guard roots.contains(where: { p == $0.path || p.hasPrefix($0.path + "/") }) else { return nil }
        if let r = roots.first(where: { $0.path == p }) { return r }
        return FileLocation(name: (p as NSString).lastPathComponent, path: p, symbol: "folder")
    }

    func openParent() {
        guard let p = parentLocation else { return }
        history = Array(history.prefix(historyIndex + 1)) + [p]
        historyIndex = history.count - 1
        load(p)
    }

    func displayPath(_ path: String) -> String {
        guard let r = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { return path }
        let rest = path.dropFirst(r.path.count).split(separator: "/").map(String.init)
        return ([r.name] + rest).joined(separator: " › ")
    }
    func forward() { guard canGoForward else { return }; historyIndex += 1; load(history[historyIndex]) }
    func reload() { if let l = location { load(l) } }

    private func load(_ loc: FileLocation) {
        location = loc
        if PhoneLink.isDemo { return }
        loading = true
        error = nil
        request("fs.list", path: loc.path) { r in
            guard self.location == loc else { return }
            self.loading = false
            if r.str("t") == "fs.error" {
                self.error = r.str("msg")
                self.items = []
                self.writable = false
            } else {
                self.items = (r["items"] as? [JSON] ?? []).map(RemoteFile.init).filter { !$0.name.hasPrefix(".") }
                self.writable = r.bool("writable")
            }
        }
    }

    func reset() {
        roots = []; rootsError = nil; location = nil; place = nil; items = []; history = []; historyIndex = -1; error = nil
    }

    // MARK: Copy (main thread)

    /// Copies one phone file to a new temporary folder, with no transfer list entry.
    /// path can be "media:<id>" for a photo. Calls done on the main thread.
    func fetch(path: String, name: String, done: @escaping (URL?) -> Void) {
        // Without the app session, photos come from the media store over adb.
        if !link.sessionConnected, path.hasPrefix("media:"), let serial = link.adbSerial, let mid = Int64(path.dropFirst(6)) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneLink-" + UUID().uuidString, isDirectory: true)
            let out = dir.appendingPathComponent(Self.safeName(name))
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let ok = AdbFiles.readMedia(serial: serial, id: mid, to: out)
                DispatchQueue.main.async { done(ok ? out : nil) }
            }
            return
        }
        guard link.sessionConnected else { done(nil); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneLink-" + UUID().uuidString, isDirectory: true)
        let id = newId()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = Self.safeName(name)
            let tmp = dir.appendingPathComponent(".\(safe).part")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw FileError(msg: "Cannot save the file.") }
            let inc = Incoming(handle: try FileHandle(forWritingTo: tmp), tmp: tmp, dir: dir, name: safe, expected: -1,
                               transfer: nil, replyDone: false, openWhenDone: false)
            inc.onDone = { u in DispatchQueue.main.async { done(u) } }
            locked { incoming[id] = inc }
            link.send(["t": "fs.get", "id": wire(id), "path": path])
        } catch {
            done(nil)
        }
    }

    func download(_ files: [RemoteFile], open: Bool = false) {
        let dir = Self.receiveFolder
        let serial = usbSerial
        for f in files where !f.dir {
            let id = newId()
            let name = Self.safeName(f.name)
            // Photos ("media:<id>") have no path for adb.
            if let serial, f.size >= AdbFiles.minSize, !f.path.hasPrefix("media:") {
                adbDownload(f, name: name, dir: dir, open: open, id: id, serial: serial)
            } else {
                netDownload(path: f.path, dir: dir, name: name, size: f.size, open: open, id: id, transfer: nil)
            }
        }
    }

    private func netDownload(path: String, dir: URL, name: String, size: Int64, open: Bool, id: UInt32, transfer: Transfer?) {
        do {
            // Without a session the transfer would stay active forever.
            if !link.sessionConnected { throw FileError(msg: "The phone is not connected.") }
            let inc = try makeIncoming(dir: dir, name: name, expected: size, toPhone: false, replyDone: false, open: open, id: id, transfer: transfer)
            locked { incoming[id] = inc }
            link.send(["t": "fs.get", "id": wire(id), "path": path])
        } catch {
            if let transfer { transfer.state = .failed; transfer.error = error.localizedDescription }
            else { link.banner = error.localizedDescription }
        }
    }

    private var usbSerial: String? {
        let adb = AdbManager.shared
        guard adb.linkedDevice?.usb == true, AdbManager.path != nil else { return nil }
        return adb.linkedSerial
    }

    private func adbDownload(_ f: RemoteFile, name: String, dir: URL, open: Bool, id: UInt32, serial: String) {
        let t = Transfer(id: id, name: name, toPhone: false, total: f.size)
        transfers.insert(t, at: 0)
        let job = AdbProcess()
        locked { adbJobs[id] = job }
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = dir.appendingPathComponent(".\(name).\(id).phonelink-usb")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let outcome = AdbFiles.pull(serial: serial, remote: f.path, to: tmp, job: job) { n in
                self.onMain { if t.isActive { t.done = n } }
            }
            self.locked { _ = self.adbJobs.removeValue(forKey: id) }
            if outcome == .done(tmp.path) {
                do {
                    let dest = Self.unique(dir, name)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
                    let n = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    self.onMain {
                        t.done = n; t.total = n; t.url = dest; t.state = .done
                        if open { NSWorkspace.shared.open(dest) }
                    }
                    return
                } catch {}
            }
            try? FileManager.default.removeItem(at: tmp)
            if outcome == .cancelled { return }
            self.onMain {
                guard t.isActive else { return }
                self.netDownload(path: f.path, dir: dir, name: name, size: f.size, open: open, id: id, transfer: t)
            }
        }
    }

    func upload(_ urls: [URL], to dir: String?) {
        guard link.sessionConnected else { link.banner = link.state == .connected ? "Sending files needs Phone Link on the phone." : "The phone is not connected."; return }
        let files = urls.filter { !$0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.path) }
        if files.count < urls.count { link.banner = "Phone Link copies files only. To copy a folder, compress it first." }
        let serial = usbSerial
        let jobs = files.map { u -> (URL, Transfer, Sending, AdbProcess?) in
            let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let t = Transfer(id: newId(), name: u.lastPathComponent, toPhone: true, total: size)
            t.url = u
            let job = serial != nil && size >= AdbFiles.minSize ? AdbProcess() : nil
            return (u, t, Sending(t), job)
        }
        // Register now so cancel(_:) also stops copies that have not started.
        locked {
            for j in jobs {
                if let job = j.3 { adbJobs[j.1.id] = job } else { sending[j.1.id] = j.2 }
            }
        }
        transfers.insert(contentsOf: jobs.map(\.1).reversed(), at: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for (u, t, s, job) in jobs {
                if s.cancelled { continue }
                if let job, let serial {
                    let outcome = AdbFiles.push(serial: serial, local: u, dir: dir, name: Self.safeName(u.lastPathComponent), job: job) { n in
                        self.onMain { if t.isActive { t.done = n } }
                    }
                    self.locked { _ = self.adbJobs.removeValue(forKey: t.id) }
                    if case .done = outcome {
                        self.onMain { if t.isActive { t.done = t.total; t.state = .done } }
                        continue
                    }
                    if outcome == .cancelled || job.cancelled { continue }
                    self.onMain { t.done = 0 }
                    self.locked { self.sending[t.id] = s }
                }
                var j: JSON = ["t": "fs.put", "id": self.wire(t.id), "name": u.lastPathComponent, "size": t.total]
                if let dir { j["dir"] = dir }
                self.link.send(j)
                do {
                    try self.stream(t.id, url: u, sending: s)
                    self.link.send(["t": s.cancelled ? "fs.cancel" : "fs.end", "id": self.wire(t.id)])
                } catch {
                    self.locked { _ = self.sending.removeValue(forKey: t.id) }
                    self.link.send(["t": "fs.cancel", "id": self.wire(t.id)])
                    self.onMain { if t.isActive { t.state = .failed; t.error = error.localizedDescription } }
                }
            }
            if let dir { self.onMain { if self.location?.path == dir { self.reload() } } }
        }
    }

    func cancel(_ t: Transfer) {
        guard t.isActive else { return }
        t.state = .cancelled
        let (s, inc) = locked { (sending.removeValue(forKey: t.id), incoming.removeValue(forKey: t.id)) }
        s?.cancelled = true
        if let inc { link.queue.async { self.abort(inc) } }
        if let job = locked({ adbJobs.removeValue(forKey: t.id) }) {
            // USB copy: the phone does not know about it, so just stop adb.
            DispatchQueue.global(qos: .userInitiated).async { job.cancel() }
            return
        }
        link.send(["t": "fs.cancel", "id": wire(t.id)])
    }

    func clearFinished() { transfers.removeAll { !$0.isActive } }

    static func chooseAndSend(to dir: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Send"
        p.message = dir == nil ? "Phone Link saves the files in Download/Phone Link on the phone." : "Phone Link copies the files to this folder on the phone."
        if p.runModal() == .OK { shared.upload(p.urls, to: dir) }
    }

    // MARK: Requests for any thread (Finder drive and file operations)

    func call(_ msg: JSON, timeout: TimeInterval = 120) async throws -> JSON {
        guard link.isSessionOpen else { throw FileError(msg: "The phone is not connected.") }
        let id = newId()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            let once = NSLock()
            var resumed = false
            func finish(_ r: Result<JSON, Error>) {
                once.lock(); defer { once.unlock() }
                if resumed { return }
                resumed = true
                c.resume(with: r)
            }
            locked {
                calls[id] = { r in
                    if r.str("t") == "fs.error" { finish(.failure(FileError(msg: r.str("msg") ?? "Unknown error", code: r.str("code")))) }
                    else { finish(.success(r)) }
                }
            }
            var j = msg
            j["id"] = wire(id)
            link.send(j)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if self.locked({ self.calls.removeValue(forKey: id) }) != nil {
                    finish(.failure(FileError(msg: "The phone did not answer.")))
                }
            }
        }
    }

    /// nil offset and suffix read the whole file. Returns an id for cancelRead.
    /// The sink is called on the link queue.
    @discardableResult
    func read(path: String, offset: Int64?, length: Int64?, suffix: Int64?, sink: ReadSink) -> UInt32 {
        let id = newId()
        guard link.isSessionOpen else { sink.onEnd?(FileError(msg: "The phone is not connected.")); return id }
        locked { reads[id] = sink }
        var j: JSON = ["t": "fs.get", "id": wire(id), "path": path]
        if let suffix { j["suffix"] = suffix } else { j["offset"] = offset ?? 0; if let length { j["length"] = length } }
        link.send(j)
        return id
    }

    func cancelRead(_ id: UInt32) {
        guard locked({ reads.removeValue(forKey: id) }) != nil else { return }
        link.send(["t": "fs.cancel", "id": wire(id)])
    }

    private func handleRead(_ id: UInt32, _ sink: ReadSink, _ j: JSON) {
        switch j.str("t") {
        case "fs.meta":
            let size = j.i64("size") ?? -1
            sink.started = true
            sink.onMeta?(size, j.i64("offset") ?? 0, j.i64("length") ?? size)
        case "fs.end":
            locked { _ = reads.removeValue(forKey: id) }
            sink.onEnd?(nil)
        case "fs.error":
            locked { _ = reads.removeValue(forKey: id) }
            sink.onEnd?(FileError(msg: j.str("msg") ?? "Unknown error", code: j.str("code")))
        default: break
        }
    }

    func put(local: URL, dir: String, name: String, replace: Bool) async throws {
        guard link.isSessionOpen else { throw FileError(msg: "The phone is not connected.") }
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let id = newId()
        let s = Sending(nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            s.onDone = { err in
                if let err { c.resume(throwing: FileError(msg: err)) } else { c.resume() }
            }
            locked { sending[id] = s }
            link.send(["t": "fs.put", "id": wire(id), "dir": dir, "name": name, "size": size, "replace": replace, "quiet": true])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.stream(id, url: local, sending: s)
                    if !s.cancelled { self.link.send(["t": "fs.end", "id": self.wire(id)]) }
                } catch {
                    self.locked { _ = self.sending.removeValue(forKey: id) }
                    self.link.send(["t": "fs.cancel", "id": self.wire(id)])
                    s.complete(error.localizedDescription)
                }
            }
        }
    }

    // MARK: File operations (main thread)

    @Published var opError: FileError?
    @Published var newItemPath: String?

    /// Photo locations ("media:") are read-only.
    var canModify: Bool {
        guard let l = location, !l.path.hasPrefix("media:"), link.sessionConnected || PhoneLink.isDemo else { return false }
        return writable
    }

    func isRoot(_ f: RemoteFile) -> Bool { roots.contains { $0.path == f.path } || f.path.hasPrefix("media:") }

    private func run(_ what: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await what() } catch {
                self.opError = (error as? FileError) ?? FileError(msg: error.localizedDescription)
            }
            self.reload()
            PhoneDrive.shared.invalidate()
        }
    }

    private static func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    private static func join(_ d: String, _ n: String) -> String { d.hasSuffix("/") ? d + n : d + "/" + n }

    func delete(_ files: [RemoteFile]) {
        let files = files.filter { !isRoot($0) }
        guard !files.isEmpty else { return }
        if PhoneLink.isDemo { items.removeAll { f in files.contains { $0.path == f.path } }; return }
        run { _ = try await self.call(["t": "fs.delete", "paths": files.map(\.path)]) }
    }

    func rename(_ f: RemoteFile, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != f.name, !isRoot(f) else { return }
        if n.contains("/") || n.contains(":") { opError = FileError(msg: "The name “\(n)” cannot be used. Use a name without “/” or “:”."); return }
        if PhoneLink.isDemo {
            if let i = items.firstIndex(of: f) { items[i] = RemoteFile(name: n, path: Self.join(Self.parent(f.path), n), dir: f.dir, size: f.size, mtime: f.mtime) }
            return
        }
        run { _ = try await self.call(["t": "fs.rename", "path": f.path, "name": n]) }
    }

    func newFolder() {
        guard let dir = location?.path, canModify else { return }
        if PhoneLink.isDemo {
            var n = "untitled folder", i = 2
            while items.contains(where: { $0.name == n }) { n = "untitled folder \(i)"; i += 1 }
            let p = Self.join(dir, n)
            items.append(RemoteFile(name: n, path: p, dir: true, size: 0, mtime: Date()))
            newItemPath = p
            return
        }
        run {
            let r = try await self.call(["t": "fs.mkdir", "dir": dir, "name": "untitled folder", "unique": true])
            self.newItemPath = r.str("path")
        }
    }

    func duplicate(_ files: [RemoteFile]) {
        let files = files.filter { !isRoot($0) }
        guard !files.isEmpty, !PhoneLink.isDemo else { return }
        run { for f in files { _ = try await self.call(["t": "fs.copy", "from": f.path], timeout: 600) } }
    }

    func move(_ paths: [String], into dir: String) {
        let paths = paths.filter { p in Self.parent(p) != dir && p != dir && !roots.contains { $0.path == p } && !p.hasPrefix("media:") }
        guard !paths.isEmpty, !PhoneLink.isDemo else { return }
        if let bad = paths.first(where: { dir.hasPrefix($0 + "/") }) {
            opError = FileError(msg: "You cannot move “\((bad as NSString).lastPathComponent)” into itself."); return
        }
        run {
            for p in paths {
                _ = try await self.call(["t": "fs.move", "from": p, "to": Self.join(dir, (p as NSString).lastPathComponent), "overwrite": false], timeout: 600)
            }
        }
    }

    func info(_ path: String, deep: Bool) async throws -> (RemoteFile, created: Date?, count: Int64?, free: Int64?, total: Int64?) {
        if PhoneLink.isDemo, let f = items.first(where: { $0.path == path }) { return (f, nil, nil, nil, nil) }
        let r = try await call(["t": "fs.stat", "path": path, "deep": deep], timeout: 30)
        let it = r["item"] as? JSON ?? [:]
        let f = RemoteFile(it)
        return (f, it.i64("ctime").map { Date(ms: $0) }, it.i64("count"), r.i64("free"), r.i64("total"))
    }

    func folders(in path: String) async throws -> [RemoteFile] {
        let r = try await call(["t": "fs.list", "path": path], timeout: 30)
        return (r["items"] as? [JSON] ?? []).map(RemoteFile.init).filter { $0.dir && !$0.name.hasPrefix(".") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Demo

    func loadDemo() {
        let root = "/storage/emulated/0"
        roots = [FileLocation(name: "Internal storage", path: root, symbol: "internaldrive")]
        let now = Date()
        func d(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        let loc = FileLocation(name: "Download", path: root + "/Download", symbol: "arrow.down.circle")
        place = loc.path
        location = loc
        history = [roots[0], loc]
        historyIndex = 1
        writable = true
        items = [
            RemoteFile(name: "Phone Link", path: root + "/Download/Phone Link", dir: true, size: 0, mtime: d(2)),
            RemoteFile(name: "Boarding pass SFO-LIS.pdf", path: root + "/Download/b.pdf", dir: false, size: 248_312, mtime: d(5)),
            RemoteFile(name: "IMG_20261118_174233.jpg", path: root + "/Download/i.jpg", dir: false, size: 3_912_004, mtime: d(28)),
            RemoteFile(name: "Lease agreement 2027.docx", path: root + "/Download/l.docx", dir: false, size: 61_440, mtime: d(50)),
            RemoteFile(name: "Recording 014.m4a", path: root + "/Download/r.m4a", dir: false, size: 1_204_224, mtime: d(75)),
            RemoteFile(name: "Statement October.pdf", path: root + "/Download/s.pdf", dir: false, size: 118_772, mtime: d(160)),
            RemoteFile(name: "Trip photos.zip", path: root + "/Download/t.zip", dir: false, size: 84_201_300, mtime: d(300)),
        ]
        let a = Transfer(id: 1, name: "Trip photos.zip", toPhone: false, total: 84_201_300); a.done = 52_000_000
        let b = Transfer(id: 2, name: "Invoice 1142.pdf", toPhone: true, total: 220_000); b.done = 220_000; b.state = .done
        transfers = [a, b]
    }
}

enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ f: RemoteFile) -> NSImage {
        let t = f.type ?? .data
        if let i = cache[t.identifier] { return i }
        let i = NSWorkspace.shared.icon(for: t)
        cache[t.identifier] = i
        return i
    }
    static func icon(name: String) -> NSImage {
        icon(RemoteFile(name: name, path: name, dir: false, size: 0, mtime: Date()))
    }
}
