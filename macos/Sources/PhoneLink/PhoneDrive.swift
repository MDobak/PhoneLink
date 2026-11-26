import AppKit
import Combine
import Foundation
import NetFS

/// Shows the phone storage as a Finder drive: a local WebDAV server mounted with NetFS.
/// The server listens only on 127.0.0.1 on a random port, needs a random password, and gets all data through FileHub.
final class PhoneDrive: ObservableObject {
    static let shared = PhoneDrive()

    enum Status: Equatable { case off, mounting, mounted, ejecting }

    @Published private(set) var status: Status = .off
    @Published private(set) var mountPoint: URL?
    @Published var error: String?

    private var server: DavServer?
    private var subs = Set<AnyCancellable>()

    var isMounted: Bool { status == .mounted && mountPoint != nil }

    private init() {
        // The drive needs the app session.
        PhoneLink.shared.$sessionConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self else { return }
                if !s { self.eject(force: true); return }
                guard UserDefaults.standard.bool(forKey: "driveAutoMount") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if PhoneLink.shared.route(.files).isAvailable, self.status == .off { self.mount(open: false) }
                }
            }
            .store(in: &subs)
        let phone = PhoneLink.shared.phoneName
        if !phone.isEmpty, !PhoneLink.isDemo {
            let volume = Self.volumeName(phone)
            DispatchQueue.global(qos: .utility).async { Self.removeStaleMounts(volume: volume, keepPort: nil) }
        }
        // Unmount before quitting, or Finder keeps a drive that does not answer.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, let mp = self.mountPoint else { return }
            Darwin.unmount(mp.path, MNT_FORCE)
            self.server?.stop()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let mp = self.mountPoint,
                  let u = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  u.standardizedFileURL.path == mp.standardizedFileURL.path else { return }
            self.cleanUp()
        }
    }

    func showInFinder() {
        if let mp = mountPoint, status == .mounted { NSWorkspace.shared.open(mp); return }
        mount(open: true)
    }

    func mount(open: Bool = true) {
        guard status == .off, PhoneLink.shared.route(.files).isAvailable, !PhoneLink.isDemo else { return }
        status = .mounting
        error = nil
        Task { @MainActor in
            do {
                let r = try await FileHub.shared.call(["t": "fs.roots"], timeout: 20)
                let roots = (r["items"] as? [JSON] ?? []).map(RemoteFile.init).map { DavServer.Root(name: $0.name, path: $0.path) }
                guard !roots.isEmpty else { throw FileError(msg: "The phone has no storage to show.") }
                let name = Self.volumeName(PhoneLink.shared.phoneName)
                let server = DavServer(volume: name, roots: roots)
                let port = try await server.start()
                self.server = server
                guard let url = URL(string: "http://127.0.0.1:\(port)/\(DavServer.encode(name))/") else {
                    throw FileError(msg: "macOS could not mount the phone drive.")
                }
                // Remove drives left by an earlier server. Do not wait: unmounting a drive with no server can take minutes.
                Self.removeStaleMounts(volume: name, keepPort: port)
                let mp = try await Task.detached {
                    try Self.netMount(url, user: server.user, password: server.password)
                }.value
                guard self.status == .mounting else {
                    // The phone disconnected while macOS mounted the drive.
                    Darwin.unmount(mp.path, MNT_FORCE); server.stop()
                    if self.server === server { self.server = nil }
                    return
                }
                self.mountPoint = mp
                self.status = .mounted
                if open { NSWorkspace.shared.open(mp) }
            } catch {
                self.server?.stop()
                self.server = nil
                self.status = .off
                self.error = (error as? FileError)?.msg ?? error.localizedDescription
            }
        }
    }

    func eject(force: Bool = false) {
        guard status == .mounted || status == .mounting else { return }
        guard let mp = mountPoint else { status = .off; server?.stop(); server = nil; return }
        status = .ejecting
        DispatchQueue.global(qos: .userInitiated).async {
            var r = Darwin.unmount(mp.path, 0)
            if r != 0, force { r = Darwin.unmount(mp.path, MNT_FORCE) }
            let busy = r != 0
            DispatchQueue.main.async {
                if busy && !force {
                    self.status = .mounted
                    self.error = "The drive is in use. Close the files on the phone drive, then try again."
                } else {
                    self.cleanUp()
                }
            }
        }
    }

    func invalidate() { server?.invalidate() }

    private func cleanUp() {
        server?.stop()
        server = nil
        mountPoint = nil
        status = .off
    }

    private static func volumeName(_ phone: String) -> String {
        let n = phone.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Phone" : n
    }

    /// Unmounts this app's drives left over after a crash or kill. Each server gets a new port, so a stale drive is a
    /// WebDAV mount of "http://127.0.0.1:<port>/<volume>/" with a port other than keepPort.
    /// Never blocks, so it is safe on the main thread.
    private static func removeStaleMounts(volume: String, keepPort: UInt16?) {
        var list: UnsafeMutablePointer<statfs>?
        // MNT_NOWAIT: querying a drive whose server stopped can block for a long time.
        let n = getmntinfo(&list, MNT_NOWAIT)
        guard n > 0, let list else { return }
        var stale: [(from: String, on: String)] = []
        for i in 0..<Int(n) {
            var s = list[i]
            let type = withUnsafeBytes(of: &s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type == "webdav" else { continue }
            let from = withUnsafeBytes(of: &s.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let on = withUnsafeBytes(of: &s.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if isOwnDrive(from, volume: volume, keepPort: keepPort) { stale.append((from, on)) }
        }
        guard !stale.isEmpty else { return }
        // A drive whose server stopped does not unmount, even with MNT_FORCE: macOS waits for its webdavfs_agent,
        // which waits for the server. Kill the agent first; then the unmount completes at once.
        DispatchQueue.global(qos: .utility).async {
            let agents = webdavAgents()
            for s in stale {
                for (pid, args) in agents where args.contains(" \(s.from) ") { kill(pid, SIGTERM) }
                DispatchQueue.global(qos: .utility).async { _ = Darwin.unmount(s.on, MNT_FORCE) }
            }
        }
    }

    private static func webdavAgents() -> [(pid: pid_t, args: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-x", "-o", "pid=,args="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = pid_t(t[..<sp]) else { return nil }
            let args = String(t[sp...]) + " "
            return args.contains("webdavfs_agent ") ? (pid, args) : nil
        }
    }

    private static func isOwnDrive(_ from: String, volume: String, keepPort: UInt16?) -> Bool {
        let prefix = "http://127.0.0.1:"
        guard from.hasPrefix(prefix) else { return false }
        let rest = from.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), let port = UInt16(rest[..<slash]), port != keepPort else { return false }
        let path = rest[slash...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decoded = path.removingPercentEncoding ?? path
        return !decoded.contains("/") && decoded == volume
    }

    /// Blocks; call off the main thread.
    private static func netMount(_ url: URL, user: String, password: String) throws -> URL {
        let open = NSMutableDictionary()
        open["UIOption"] = "NoUI"              // kNAUIOptionKey = kNAUIOptionNoUI
        let mount = NSMutableDictionary()
        mount["SoftMount"] = true              // kNetFSSoftMountKey: do not wait forever for a stopped server.
        var points: Unmanaged<CFArray>?
        let r = NetFSMountURLSync(url as CFURL, nil, user as CFString, password as CFString, open, mount, &points)
        let list = points?.takeRetainedValue() as? [String] ?? []
        guard r == 0, let p = list.first else {
            throw FileError(msg: "macOS could not mount the phone drive (error \(r)).")
        }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
}
