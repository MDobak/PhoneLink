import Combine
import Darwin
import Foundation

/// Login shells on this Mac for the phone, one per tab.
/// All state lives on `q`, except `openTabCount` (main thread).
final class RemoteTerminal: ObservableObject {
    static let shared = RemoteTerminal()

    /// Includes shells waiting for the phone after a disconnect. Main thread.
    @Published private(set) var openTabCount = 0

    static let enabledKey = "remoteTerminalEnabled"
    private static let maxTabs = 8
    private static let ringSize = 512 * 1024
    private static let chunkSize = 32 * 1024
    private static let keepAlive: TimeInterval = 15 * 60
    /// TIOCSWINSZ. Swift does not import the _IOW macro.
    private static let setWindowSize = UInt(0x8008_7467)

    /// Owns the pty fd. The cancel handler of the last dispatch source using it closes it. Use only on `q`.
    private final class Descriptor {
        let fd: Int32
        private var users = 0
        init(_ fd: Int32) { self.fd = fd }
        func retain() { users += 1 }
        func release() {
            users -= 1
            if users == 0 { Darwin.close(fd) }
        }
    }

    private final class Tab {
        let id: UInt32
        let pid: pid_t
        let descriptor: Descriptor
        var fd: Int32 { descriptor.fd }
        let shell: String
        /// Once set, the fd may be closed. Do not use it.
        var ioClosed = false
        var readSource: DispatchSourceRead?
        var readPaused = false
        var processSource: DispatchSourceProcess?
        var writeSource: DispatchSourceWrite?
        var writeActive = false
        var ring = Data()
        var pending = Data()
        var flushScheduled = false
        var input = Data()
        var attached = true
        var detachedAt: Date?
        var finished = false
        init(id: UInt32, pid: pid_t, fd: Int32, shell: String) { self.id = id; self.pid = pid; descriptor = Descriptor(fd); self.shell = shell }
    }

    private let q = DispatchQueue(label: "phonelink.terminal")
    private var tabs: [UInt32: Tab] = [:]
    private var sweeper: DispatchSourceTimer?
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var wasEnabled = false

    private init() {
        wasEnabled = Self.isEnabled
        let check: (Notification) -> Void = { [weak self] _ in self?.q.async { self?.checkEnabled() } }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: check)
        NotificationCenter.default.addObserver(forName: RemoteDesktopHost.accessChanged, object: nil, queue: nil, using: check)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: - Calls from PhoneLink

    /// Called on the link queue. Do not block.
    func handle(_ j: JSON) {
        q.async { self.process(j) }
    }

    /// Called on the link queue. Do not block.
    func input(id: UInt32, data: Data) {
        q.async {
            guard Self.isEnabled, let tab = self.tabs[id], !tab.finished else { return }
            tab.input.append(data)
            self.pumpInput(tab)
        }
    }

    /// Keep the shells for a while so the phone can reattach.
    func linkClosed() {
        q.async {
            let now = Date()
            for tab in self.tabs.values where tab.attached {
                tab.attached = false
                tab.detachedAt = now
                tab.pending.removeAll()
            }
            self.updateSweeper()
        }
    }

    /// SIGHUP to each process group. Any thread.
    func closeAll() {
        q.async { for tab in Array(self.tabs.values) { self.close(tab) } }
    }

    // MARK: - Messages

    private func process(_ j: JSON) {
        let t = j.str("t") ?? ""
        guard Self.isEnabled else {
            if t == "term.open" || t == "term.list" { sendDisabled() }
            return
        }
        let id = (j["id"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) } ?? 0
        let cols = max(2, min(1000, (j["cols"] as? NSNumber)?.intValue ?? 80))
        let rows = max(2, min(1000, (j["rows"] as? NSNumber)?.intValue ?? 24))
        switch t {
        case "term.list":
            PhoneLink.shared.sendRemote(["t": "term.state", "state": "ok"])
            let list: [JSON] = tabs.values.filter { !$0.finished }.sorted { $0.id < $1.id }
                .map { ["id": Int($0.id), "title": title(of: $0), "alive": true] }
            PhoneLink.shared.sendRemote(["t": "term.list", "tabs": list])
        case "term.open":
            guard id > 0 else { return }
            if let tab = tabs[id], !tab.finished {
                reattach(tab, cols: cols, rows: rows)
            } else if tabs.values.filter({ !$0.finished }).count >= Self.maxTabs {
                PhoneLink.shared.sendRemote(["t": "term.exit", "id": Int(id), "code": -1,
                                             "message": "You can open a maximum of \(Self.maxTabs) tabs."])
            } else if let tab = spawn(id: id, cols: cols, rows: rows) {
                tabs[id] = tab
                publishCount()
                PhoneLink.shared.sendRemote(["t": "term.opened", "id": Int(id), "shell": tab.shell, "reattached": false])
            } else {
                PhoneLink.shared.sendRemote(["t": "term.exit", "id": Int(id), "code": -1,
                                             "message": "The Mac cannot start the shell."])
            }
        case "term.resize":
            if let tab = tabs[id], !tab.finished { resize(tab, cols: cols, rows: rows) }
        case "term.close":
            if let tab = tabs[id] { close(tab) }
        default:
            break
        }
    }

    private func sendDisabled() {
        PhoneLink.shared.sendRemote(["t": "term.state", "state": "disabled",
                                     "message": "To use Terminal, turn on \u{201C}Allow Terminal access from your phone\u{201D} in Phone Link Settings on the Mac."])
    }

    private func checkEnabled() {
        let on = Self.isEnabled
        guard on != wasEnabled else { return }
        wasEnabled = on
        if on {
            PhoneLink.shared.sendRemote(["t": "term.state", "state": "ok"])
        } else {
            for tab in Array(tabs.values) { close(tab) }
            sendDisabled()
        }
    }

    // MARK: - Shell process

    private func spawn(id: UInt32, cols: Int, rows: Int) -> Tab? {
        let pw = getpwuid(getuid())
        var shell = pw.flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? ""
        if shell.isEmpty || access(shell, X_OK) != 0 { shell = "/bin/zsh" }
        let home = pw.flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        let user = pw.flatMap { $0.pointee.pw_name.map { String(cString: $0) } } ?? NSUserName()
        let name = (shell as NSString).lastPathComponent

        // Do not leak the app environment into the shell.
        var env: [String: String] = [
            "HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell,
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "PhoneLink",
            "LANG": Self.lang(),
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }

        // Prepare C strings before fork. The child may only call async-signal-safe functions.
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-" + name), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let shellC = strdup(shell)
        let homeC = strdup(home)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(shellC)
            free(homeC)
        }
        let maxFd = min(Int32(getdtablesize()), 4096)
        // The child must not allocate either.
        let signals: [Int32] = [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU]
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &ws)
        if pid < 0 { return nil }
        if pid == 0 {
            // Child: close inherited fds, reset signals, exec the login shell.
            var fd: Int32 = 3
            while fd < maxFd { Darwin.close(fd); fd += 1 }
            signals.withUnsafeBufferPointer { for sig in $0 { signal(sig, SIG_DFL) } }
            var none = sigset_t()
            sigemptyset(&none)
            sigprocmask(SIG_SETMASK, &none, nil)
            chdir(homeC)
            execve(shellC, argv, envp)
            _exit(127)
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let tab = Tab(id: id, pid: pid, fd: master, shell: name)

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: q)
        rs.setEventHandler { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.readOutput(tab)
        }
        let descriptor = tab.descriptor
        descriptor.retain()
        rs.setCancelHandler { descriptor.release() }
        tab.readSource = rs
        rs.resume()

        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: q)
        ps.setEventHandler { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.reap(tab, wait: true)
        }
        tab.processSource = ps
        ps.resume()
        // The process can exit before the source starts monitoring it.
        q.asyncAfter(deadline: .now() + 0.5) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.reap(tab, wait: false)
        }
        return tab
    }

    private static func lang() -> String {
        let loc = Locale.current
        if let l = loc.language.languageCode?.identifier, let r = loc.region?.identifier {
            let name = "\(l)_\(r).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") { return name }
        }
        return "en_US.UTF-8"
    }

    private func resize(_ tab: Tab, cols: Int, rows: Int) {
        guard !tab.ioClosed else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(tab.fd, Self.setWindowSize, &ws)
    }

    private func reattach(_ tab: Tab, cols: Int, rows: Int) {
        tab.attached = true
        tab.detachedAt = nil
        // The ring buffer already holds the pending output.
        tab.pending.removeAll()
        updateSweeper()
        PhoneLink.shared.sendRemote(["t": "term.opened", "id": Int(tab.id), "shell": tab.shell, "reattached": true])
        send(tab.ring, tab: tab)
        resize(tab, cols: cols, rows: rows)
    }

    private func title(of tab: Tab) -> String {
        guard !tab.ioClosed else { return tab.shell }
        let pg = tcgetpgrp(tab.fd)
        if pg > 0 {
            var buf = [CChar](repeating: 0, count: 256)
            if proc_name(pg, &buf, UInt32(buf.count)) > 0 {
                let s = String(cString: buf)
                if !s.isEmpty { return s }
            }
        }
        return tab.shell
    }

    // MARK: - Output

    private func readOutput(_ tab: Tab) {
        let n = readBuffer.withUnsafeMutableBytes { read(tab.fd, $0.baseAddress, $0.count) }
        if n > 0 {
            append(tab, Data(readBuffer[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            // The slave side closed (EOF or EIO).
            stopIO(tab)
            reap(tab, wait: false, retries: 40)
        }
    }

    private func append(_ tab: Tab, _ d: Data) {
        tab.ring.append(d)
        // Copy: Data.removeFirst keeps the old storage.
        if tab.ring.count > Self.ringSize + 64 * 1024 { tab.ring = Data(tab.ring.suffix(Self.ringSize)) }
        guard tab.attached else { return }
        tab.pending.append(d)
        if tab.pending.count >= Self.chunkSize {
            flush(tab)
            // Large output: pause reading so the network can catch up.
            pauseRead(tab)
            q.asyncAfter(deadline: .now() + 0.01) { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.resumeRead(tab)
            }
        } else if !tab.flushScheduled {
            tab.flushScheduled = true
            q.asyncAfter(deadline: .now() + 0.01) { [weak self, weak tab] in
                guard let self, let tab else { return }
                tab.flushScheduled = false
                self.flush(tab)
            }
        }
    }

    private func flush(_ tab: Tab) {
        guard tab.attached, !tab.pending.isEmpty else { tab.pending.removeAll(); return }
        send(tab.pending, tab: tab)
        tab.pending.removeAll(keepingCapacity: true)
    }

    private func send(_ data: Data, tab: Tab) {
        var off = data.startIndex
        while off < data.endIndex {
            let end = min(off + Self.chunkSize, data.endIndex)
            PhoneLink.shared.sendTerminal(id: tab.id, data: data.subdata(in: off..<end))
            off = end
        }
    }

    private func pauseRead(_ tab: Tab) {
        guard let rs = tab.readSource, !tab.readPaused else { return }
        rs.suspend()
        tab.readPaused = true
    }

    private func resumeRead(_ tab: Tab) {
        guard let rs = tab.readSource, tab.readPaused else { return }
        tab.readPaused = false
        rs.resume()
    }

    // MARK: - Input

    private func pumpInput(_ tab: Tab) {
        guard !tab.ioClosed else { tab.input.removeAll(); return }
        while !tab.input.isEmpty {
            let n = tab.input.withUnsafeBytes { write(tab.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                tab.input.removeFirst(n)
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                break
            } else {
                tab.input.removeAll()
            }
        }
        if !tab.input.isEmpty {
            if tab.writeSource == nil {
                let ws = DispatchSource.makeWriteSource(fileDescriptor: tab.fd, queue: q)
                ws.setEventHandler { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.pumpInput(tab)
                }
                let descriptor = tab.descriptor
                descriptor.retain()
                ws.setCancelHandler { descriptor.release() }
                tab.writeSource = ws
            }
            if !tab.writeActive { tab.writeActive = true; tab.writeSource?.resume() }
        } else if tab.writeActive {
            tab.writeActive = false
            tab.writeSource?.suspend()
        }
    }

    // MARK: - Stop

    private func close(_ tab: Tab) {
        guard !tab.finished else { return }
        kill(-tab.pid, SIGHUP)
        kill(tab.pid, SIGHUP)
        let pid = tab.pid
        q.asyncAfter(deadline: .now() + 3) { [weak self, weak tab] in
            guard let self, let tab, !tab.finished else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            self.reap(tab, wait: false, retries: 20)
        }
    }

    private func reap(_ tab: Tab, wait: Bool, retries: Int = 0) {
        guard !tab.finished else { return }
        var status: Int32 = 0
        let r = waitpid(tab.pid, &status, wait ? 0 : WNOHANG)
        if r == 0 {
            if retries > 0 {
                q.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.reap(tab, wait: false, retries: retries - 1)
                }
            }
            return
        }
        let code: Int
        if r < 0 {
            code = -1
        } else if status & 0x7f == 0 {
            code = Int((status >> 8) & 0xff)
        } else {
            code = 128 + Int(status & 0x7f)
        }
        tab.finished = true
        if !tab.ioClosed { drain(tab) }
        flush(tab)
        stopIO(tab)
        tab.processSource?.cancel()
        tab.processSource = nil
        if tabs[tab.id] === tab { tabs[tab.id] = nil }
        if tab.attached { PhoneLink.shared.sendRemote(["t": "term.exit", "id": Int(tab.id), "code": code]) }
        publishCount()
        updateSweeper()
    }

    /// The fd closes when both cancel handlers have run.
    private func stopIO(_ tab: Tab) {
        guard !tab.ioClosed else { return }
        tab.ioClosed = true
        tab.input.removeAll()
        if let ws = tab.writeSource {
            // A suspended source must be resumed before it is cancelled.
            if !tab.writeActive { ws.resume() }
            tab.writeActive = false
            ws.cancel()
            tab.writeSource = nil
        }
        if let rs = tab.readSource {
            if tab.readPaused { rs.resume(); tab.readPaused = false }
            rs.cancel()
            tab.readSource = nil
        }
    }

    private func drain(_ tab: Tab) {
        for _ in 0..<64 {
            let n = readBuffer.withUnsafeMutableBytes { read(tab.fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            append(tab, Data(readBuffer[0..<n]))
        }
    }

    private func updateSweeper() {
        let waiting = tabs.values.contains { $0.detachedAt != nil }
        if waiting, sweeper == nil {
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 30, repeating: 30)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Date()
                for tab in Array(self.tabs.values) {
                    if let at = tab.detachedAt, now.timeIntervalSince(at) > Self.keepAlive { self.close(tab) }
                }
            }
            sweeper = t
            t.resume()
        } else if !waiting, let t = sweeper {
            t.cancel()
            sweeper = nil
        }
    }

    private func publishCount() {
        let n = tabs.values.filter { !$0.finished }.count
        DispatchQueue.main.async { if self.openTabCount != n { self.openTabCount = n } }
    }
}
