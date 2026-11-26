import Foundation
import Network
import UniformTypeIdentifiers

/// Minimal WebDAV server (RFC 4918, class 1 and 2) for the macOS WebDAV file system.
/// Listens only on 127.0.0.1 and requires HTTP Basic auth on every request.
final class DavServer {
    struct Root { let name: String; let path: String }

    let volume: String
    let roots: [Root]
    let user = "phonelink"
    let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var authValue: String { "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "phonelink.drive", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listings: [String: (time: Date, items: [RemoteFile])] = [:]
    /// Finder files (AppleDouble "._" files, .DS_Store) stay in memory and never go to the phone.
    private var junk: [String: (data: Data, mtime: Date)] = [:]
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private let spool: URL
    private let started = Date()

    private static let cacheTime: TimeInterval = 3
    private static let junkMax = 1 << 20

    init(volume: String, roots: [Root]) {
        self.volume = volume
        self.roots = roots
        spool = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneLinkDrive-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    // MARK: Listener

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: if once.take() { c.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.take() { c.resume(throwing: e) }
                case .cancelled: if once.take() { c.resume(throwing: FileError(msg: "The drive stopped.")) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let all = locked { () -> [NWConnection] in defer { conns = [:] }; return Array(conns.values) }
        all.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: spool)
    }

    func invalidate() { locked { listings = [:] } }

    private func accept(_ c: NWConnection) {
        // Only local connections. Checked again for safety.
        if case .hostPort(let host, _) = c.endpoint, "\(host)" != "127.0.0.1", "\(host)" != "::1" { c.cancel(); return }
        let key = ObjectIdentifier(c)
        locked { conns[key] = c }
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.locked { _ = self?.conns.removeValue(forKey: key) }
            default: break
            }
        }
        c.start(queue: queue)
        let conn = DavConnection(c)
        Task { await self.serve(conn); c.cancel() }
    }

    // MARK: Requests

    private func serve(_ conn: DavConnection) async {
        while true {
            guard let req = await conn.readRequest() else { return }
            var keep = !req.close
            if req.header("authorization") != authValue {
                await conn.discardBody(req)
                await conn.respond(401, ["WWW-Authenticate": "Basic realm=\"Phone Link\""], close: !keep)
            } else {
                keep = await handle(req, conn) && keep
            }
            if !keep { return }
        }
    }

    private static let allowed = "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, COPY, LOCK, UNLOCK"

    private func handle(_ req: DavRequest, _ conn: DavConnection) async -> Bool {
        guard let comps = components(req.path) else {
            await conn.discardBody(req)
            await conn.respond(404, close: req.close)
            return !req.close
        }
        // Only PUT reads its body.
        if req.method != "PUT" { await conn.discardBody(req) }
        do {
            switch req.method {
            case "OPTIONS":
                await conn.respond(200, ["DAV": "1, 2", "MS-Author-Via": "DAV", "Allow": Self.allowed])
            case "PROPFIND":
                // No quota properties: with them, the macOS WebDAV client waits 90 s before the mount completes.
                try await propfind(comps, depth: req.header("depth") ?? "infinity", conn)
            case "GET", "HEAD":
                return try await get(comps, req, conn)
            case "PUT": try await put(comps, req, conn)
            case "DELETE": try await delete(comps, conn)
            case "MKCOL": try await mkcol(comps, conn)
            case "MOVE", "COPY": try await moveOrCopy(comps, req, conn)
            case "LOCK": await lockResponse(comps, req, conn)
            case "UNLOCK": await conn.respond(204)
            case "PROPPATCH":
                let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>\(href(comps, dir: false))</D:href>"
                    + "<D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"
                await conn.respond(207, ["Content-Type": "text/xml; charset=\"utf-8\""], body: Data(xml.utf8))
            default:
                await conn.respond(405, ["Allow": Self.allowed])
            }
        } catch {
            await conn.respond(Self.status(for: error))
        }
        return true
    }

    private static func status(for e: Error) -> Int {
        switch (e as? FileError)?.code {
        case "notfound": return 404
        case "exists": return 412
        case "perm", "forbidden": return 403
        case "conflict": return 409
        default: return (e as? FileError)?.msg == "The phone is not connected." ? 503 : 500
        }
    }

    private static func forbidden() -> FileError { FileError(msg: "Not permitted.", code: "forbidden") }

    // MARK: Paths

    private func components(_ raw: String) -> [String]? {
        var p = raw
        if let r = p.range(of: "://"), let slash = p[r.upperBound...].firstIndex(of: "/") { p = String(p[slash...]) }
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        guard let decoded = p.removingPercentEncoding else { return nil }
        var parts = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.first == volume { parts.removeFirst() } else if !parts.isEmpty { return nil }
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        return parts
    }

    /// Other storage (an SD card) shows as a top-level folder.
    private func phonePath(_ comps: [String]) -> String {
        if let first = comps.first, let r = roots.dropFirst().first(where: { $0.name == first }) {
            return ([r.path] + comps.dropFirst()).joined(separator: "/")
        }
        return ([roots[0].path] + comps).joined(separator: "/")
    }

    private func isTop(_ comps: [String]) -> Bool {
        comps.isEmpty || (comps.count == 1 && roots.dropFirst().contains { $0.name == comps[0] })
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func href(_ comps: [String], dir: Bool) -> String {
        let p = "/" + ([volume] + comps).map(Self.encode).joined(separator: "/")
        return dir ? p + "/" : p
    }

    private static func junkName(_ n: String) -> Bool {
        n.hasPrefix("._") || [".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
                              ".metadata_never_index", ".metadata_never_index_unless_rootfs", ".VolumeIcon.icns",
                              ".ql_disablethumbnails", ".ql_disablecache", ".com.apple.timemachine.donotpresent"].contains(n)
    }

    private func junkKey(_ comps: [String]) -> String? {
        guard let n = comps.last, Self.junkName(n) else { return nil }
        return comps.joined(separator: "/")
    }

    // MARK: Phone access with a short cache

    private func list(_ comps: [String]) async throws -> [RemoteFile] {
        let path = phonePath(comps)
        if let c = locked({ listings[path] }), Date().timeIntervalSince(c.time) < Self.cacheTime { return c.items }
        let r = try await FileHub.shared.call(["t": "fs.list", "path": path], timeout: 60)
        var items = (r["items"] as? [JSON] ?? []).map(RemoteFile.init)
            .filter { !$0.name.hasSuffix(".phonelink-part") && !Self.junkName($0.name) }
        if comps.isEmpty {
            items += roots.dropFirst().map { RemoteFile(name: $0.name, path: $0.path, dir: true, size: 0, mtime: started) }
        }
        locked { listings[path] = (Date(), items) }
        return items
    }

    private func stat(_ comps: [String]) async throws -> RemoteFile? {
        if isTop(comps) {
            return RemoteFile(name: comps.last ?? volume, path: phonePath(comps), dir: true, size: 0, mtime: started)
        }
        if let k = junkKey(comps) {
            guard let j = locked({ junk[k] }) else { return nil }
            return RemoteFile(name: comps.last!, path: k, dir: false, size: Int64(j.data.count), mtime: j.mtime)
        }
        let parent = Array(comps.dropLast())
        do {
            return try await list(parent).first { $0.name == comps.last }
        } catch let e as FileError where e.code == "notfound" {
            return nil
        }
    }

    // MARK: Methods

    /// DateFormatter is thread-safe, so all connections share one.
    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let isoDate = ISO8601DateFormatter()

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func etag(_ f: RemoteFile) -> String { "\"\(Int64(f.mtime.timeIntervalSince1970 * 1000))-\(f.size)\"" }

    private static func mime(_ name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func entry(_ f: RemoteFile, _ comps: [String]) -> String {
        var p = "<D:response><D:href>\(Self.xmlEscape(href(comps, dir: f.dir)))</D:href><D:propstat><D:prop>"
        p += "<D:displayname>\(Self.xmlEscape(f.name))</D:displayname>"
        p += "<D:getlastmodified>\(Self.httpDate.string(from: f.mtime))</D:getlastmodified>"
        p += "<D:creationdate>\(Self.isoDate.string(from: f.mtime))</D:creationdate>"
        if f.dir {
            p += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            p += "<D:resourcetype/><D:getcontentlength>\(f.size)</D:getcontentlength>"
            p += "<D:getcontenttype>\(Self.mime(f.name))</D:getcontenttype><D:getetag>\(Self.xmlEscape(Self.etag(f)))</D:getetag>"
        }
        p += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
        p += "<D:lockdiscovery/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        return p
    }

    private func propfind(_ comps: [String], depth: String, _ conn: DavConnection) async throws {
        guard let f = try await stat(comps) else { await conn.respond(404); return }
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">"
        xml += entry(f, comps)
        if f.dir, depth != "0" {
            for c in try await list(comps) { xml += entry(c, comps + [c.name]) }
        }
        xml += "</D:multistatus>"
        await conn.respond(207, ["Content-Type": "text/xml; charset=\"utf-8\""], body: Data(xml.utf8))
    }

    /// Ranges ("bytes=a-b", "bytes=a-", "bytes=-n") are read from the phone in parts.
    private func get(_ comps: [String], _ req: DavRequest, _ conn: DavConnection) async throws -> Bool {
        let head = req.method == "HEAD"
        if let k = junkKey(comps) {
            guard let j = locked({ junk[k] }) else { await conn.respond(404); return true }
            await conn.respond(200, ["Content-Type": "application/octet-stream", "Last-Modified": Self.httpDate.string(from: j.mtime)],
                               body: head ? nil : j.data, length: Int64(j.data.count))
            return true
        }
        guard let f = try await stat(comps) else { await conn.respond(404); return true }
        if f.dir {
            let body = Data("<html><body>\(Self.xmlEscape(f.name))</body></html>".utf8)
            await conn.respond(200, ["Content-Type": "text/html; charset=utf-8"], body: head ? nil : body, length: Int64(body.count))
            return true
        }
        var headers = ["Content-Type": Self.mime(f.name), "Last-Modified": Self.httpDate.string(from: f.mtime),
                       "ETag": Self.etag(f), "Accept-Ranges": "bytes"]
        if head { await conn.respond(200, headers, length: f.size); return true }

        let range = Self.range(req.header("range"))
        let ranged = range.offset != nil || range.suffix != nil

        let sink = FileHub.ReadSink()
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var sentHead = false
            var readId: UInt32 = 0
            sink.onMeta = { size, off, len in
                sentHead = true
                if ranged, size > 0, let s = range.offset, s >= size {
                    conn.sendHead(416, ["Content-Range": "bytes */\(size)"], length: 0)
                    return
                }
                if ranged && size > 0 {
                    headers["Content-Range"] = "bytes \(off)-\(off + len - 1)/\(size)"
                    conn.sendHead(206, headers, length: len)
                } else {
                    conn.sendHead(200, headers, length: max(0, size))
                }
            }
            sink.onData = { d in
                conn.sendData(d) { ok in
                    if !ok, once.take() { FileHub.shared.cancelRead(readId); cont.resume(returning: false) }
                }
            }
            sink.onEnd = { err in
                if let err, !sentHead {
                    // Nothing sent yet, so an error response is still possible.
                    conn.sendHead(Self.status(for: err), [:], length: 0)
                    conn.flush { _ in if once.take() { cont.resume(returning: true) } }
                    return
                }
                // Error mid-stream: close the connection so the client sees a short file.
                conn.flush { ok in if once.take() { cont.resume(returning: err == nil && ok) } }
            }
            readId = FileHub.shared.read(path: phonePath(comps), offset: range.offset, length: range.length, suffix: range.suffix, sink: sink)
        }
    }

    /// Only a single range is supported. Other forms read the whole file.
    private static func range(_ header: String?) -> (offset: Int64?, length: Int64?, suffix: Int64?) {
        let none: (Int64?, Int64?, Int64?) = (nil, nil, nil)
        guard let r = header?.trimmingCharacters(in: .whitespaces), r.hasPrefix("bytes="), !r.contains(",") else { return none }
        let spec = r.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard spec.count == 2 else { return none }
        if spec[0].isEmpty, let n = Int64(spec[1]) { return (nil, nil, n) }
        guard let a = Int64(spec[0]) else { return none }
        guard let b = Int64(spec[1]) else { return (a, nil, nil) }
        return b >= a ? (a, b - a + 1, nil) : none
    }

    private func put(_ comps: [String], _ req: DavRequest, _ conn: DavConnection) async throws {
        guard let name = comps.last, !isTop(comps) else { await conn.discardBody(req); throw Self.forbidden() }
        if let k = junkKey(comps) {
            // A file larger than junkMax is kept empty.
            let data = await conn.readBody(req, max: Self.junkMax) ?? Data()
            let existed = locked { junk.updateValue((data, Date()), forKey: k) != nil }
            await conn.respond(existed ? 204 : 201)
            return
        }
        let tmp = spool.appendingPathComponent(UUID().uuidString)
        guard await conn.spoolBody(req, to: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            await conn.respond(400, close: true)
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let existing = try? await stat(comps)
        if existing?.dir == true { await conn.respond(405); return }
        do {
            try await FileHub.shared.put(local: tmp, dir: phonePath(Array(comps.dropLast())), name: name, replace: true)
        } catch let e as FileError where e.msg == "This folder does not exist." {
            invalidate()
            await conn.respond(409); return
        }
        invalidate()
        await conn.respond(existing == nil ? 201 : 204)
    }

    private func delete(_ comps: [String], _ conn: DavConnection) async throws {
        guard !isTop(comps) else { throw Self.forbidden() }
        if let k = junkKey(comps) {
            let had = locked { junk.removeValue(forKey: k) != nil }
            await conn.respond(had ? 204 : 404)
            return
        }
        _ = try await FileHub.shared.call(["t": "fs.delete", "paths": [phonePath(comps)]], timeout: 600)
        invalidate()
        await conn.respond(204)
    }

    private func mkcol(_ comps: [String], _ conn: DavConnection) async throws {
        guard let name = comps.last, !isTop(comps), junkKey(comps) == nil else { throw Self.forbidden() }
        do {
            _ = try await FileHub.shared.call(["t": "fs.mkdir", "dir": phonePath(Array(comps.dropLast())), "name": name, "unique": false])
        } catch let e as FileError where e.code == "exists" {
            await conn.respond(405); return
        } catch let e as FileError where e.code == "notfound" {
            await conn.respond(409); return
        }
        invalidate()
        await conn.respond(201)
    }

    private func moveOrCopy(_ comps: [String], _ req: DavRequest, _ conn: DavConnection) async throws {
        guard let dest = req.header("destination"), let to = components(dest) else { await conn.respond(400); return }
        guard !isTop(comps), !isTop(to) else { throw Self.forbidden() }
        let overwrite = req.header("overwrite")?.uppercased() != "F"
        let move = req.method == "MOVE"
        if let k = junkKey(comps) {
            guard let j = locked({ junk[k] }) else { await conn.respond(404); return }
            if let k2 = junkKey(to) {
                locked { junk[k2] = j; if move { junk[k] = nil } }
                await conn.respond(201)
            } else { throw Self.forbidden() }
            return
        }
        if junkKey(to) != nil { throw Self.forbidden() }
        let r = try await FileHub.shared.call(["t": move ? "fs.move" : "fs.copy", "from": phonePath(comps), "to": phonePath(to),
                                               "overwrite": overwrite], timeout: 600)
        invalidate()
        await conn.respond(r.bool("replaced") ? 204 : 201)
    }

    private func lockResponse(_ comps: [String], _ req: DavRequest, _ conn: DavConnection) async {
        // A refresh sends the token in the "If" header; reuse it.
        var token = "opaquelocktoken:" + UUID().uuidString.lowercased()
        if let ifh = req.header("if"), let r = ifh.range(of: "opaquelocktoken:[0-9a-fA-F-]+", options: .regularExpression) {
            token = String(ifh[r])
        }
        let timeout = "Second-3600"
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
            + "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>"
            + "<D:owner>Phone Link</D:owner><D:timeout>\(timeout)</D:timeout>"
            + "<D:locktoken><D:href>\(token)</D:href></D:locktoken>"
            + "<D:lockroot><D:href>\(Self.xmlEscape(href(comps, dir: false)))</D:href></D:lockroot>"
            + "</D:activelock></D:lockdiscovery></D:prop>"
        await conn.respond(200, ["Content-Type": "text/xml; charset=\"utf-8\"", "Lock-Token": "<\(token)>"], body: Data(xml.utf8))
    }
}

private final class Once {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

struct DavRequest {
    let method: String
    let path: String
    let headers: [String: String]
    func header(_ k: String) -> String? { headers[k] }
    var close: Bool { header("connection")?.lowercased() == "close" }
    var chunked: Bool { header("transfer-encoding")?.lowercased().contains("chunked") == true }
    var length: Int64 { Int64(header("content-length") ?? "") ?? 0 }
}

final class DavConnection {
    private let c: NWConnection
    private var buf = Data()

    init(_ c: NWConnection) { self.c = c }

    private func receive() async -> Data? {
        await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
                if let data, !data.isEmpty { k.resume(returning: data) }
                else if done || err != nil { k.resume(returning: nil) }
                else { k.resume(returning: Data()) }
            }
        }
    }

    private func fill(_ n: Int) async -> Bool {
        while buf.count < n { guard let d = await receive() else { return false }; buf.append(d) }
        return true
    }

    private func readLine() async -> String? {
        let crlf = Data("\r\n".utf8)
        while true {
            if let r = buf.range(of: crlf) {
                let line = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
                buf = Data(buf[r.upperBound...])
                return line
            }
            if buf.count > 64 * 1024 { return nil }
            guard let d = await receive() else { return nil }
            buf.append(d)
        }
    }

    private func take(_ n: Int) -> Data {
        let d = Data(buf.prefix(n))
        buf = Data(buf.dropFirst(n))
        return d
    }

    func readRequest() async -> DavRequest? {
        var first = ""
        while first.isEmpty { guard let l = await readLine() else { return nil }; first = l }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        while let l = await readLine() {
            if l.isEmpty {
                let req = DavRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), headers: headers)
                if req.header("expect")?.lowercased() == "100-continue" { sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
                return req
            }
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func body(_ req: DavRequest, write: (Data) throws -> Void) async -> Bool {
        do {
            if req.chunked {
                while true {
                    guard let line = await readLine(), let n = Int(line.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) else { return false }
                    if n == 0 {
                        while let t = await readLine() { if t.isEmpty { return true } }
                        return false
                    }
                    var left = n
                    while left > 0 {
                        if buf.isEmpty { guard await fill(1) else { return false } }
                        let d = take(min(left, buf.count))
                        try write(d)
                        left -= d.count
                    }
                    guard await readLine() != nil else { return false }
                }
            }
            var left = req.length
            while left > 0 {
                if buf.isEmpty { guard await fill(1) else { return false } }
                let d = take(Int(min(left, Int64(buf.count))))
                try write(d)
                left -= Int64(d.count)
            }
            return true
        } catch { return false }
    }

    func discardBody(_ req: DavRequest) async { _ = await body(req) { _ in } }

    /// nil when larger than max; the data is then read and dropped.
    func readBody(_ req: DavRequest, max: Int) async -> Data? {
        var d = Data()
        var over = false
        _ = await body(req) { part in if !over { d.append(part); if d.count > max { over = true; d = Data() } } }
        return over ? nil : d
    }

    func spoolBody(_ req: DavRequest, to url: URL) async -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else { await discardBody(req); return false }
        defer { try? h.close() }
        return await body(req) { try h.write(contentsOf: $0) }
    }

    private static let reasons: [Int: String] = [
        100: "Continue", 200: "OK", 201: "Created", 204: "No Content", 206: "Partial Content", 207: "Multi-Status",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        409: "Conflict", 412: "Precondition Failed", 415: "Unsupported Media Type", 416: "Range Not Satisfiable",
        500: "Internal Server Error", 503: "Service Unavailable"]

    private func headBytes(_ status: Int, _ headers: [String: String], length: Int64, close: Bool) -> Data {
        var h = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = headers
        all["Content-Length"] = String(length)
        all["Server"] = "PhoneLink"
        all["Date"] = DavServer.httpDate.string(from: Date())
        if close { all["Connection"] = "close" }
        for (k, v) in all { h += "\(k): \(v)\r\n" }
        return Data((h + "\r\n").utf8)
    }

    func sendRaw(_ d: Data) { c.send(content: d, completion: .contentProcessed { _ in }) }

    func sendHead(_ status: Int, _ headers: [String: String], length: Int64) {
        sendRaw(headBytes(status, headers, length: length, close: false))
    }

    func sendData(_ d: Data, done: @escaping (Bool) -> Void) {
        c.send(content: d, completion: .contentProcessed { e in done(e == nil) })
    }

    func flush(_ done: @escaping (Bool) -> Void) {
        c.send(content: Data(), completion: .contentProcessed { e in done(e == nil) })
    }

    /// With a body, length is the body size. HEAD sends length with no body.
    func respond(_ status: Int, _ headers: [String: String] = [:], body: Data? = nil, length: Int64? = nil, close: Bool = false) async {
        var d = headBytes(status, headers, length: length ?? Int64(body?.count ?? 0), close: close)
        if let body { d.append(body) }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            c.send(content: d, completion: .contentProcessed { _ in k.resume() })
        }
    }
}
