import Foundation

// phonelink-mcp: an MCP server on stdio for local agents.
// It connects stdin and stdout to the Unix socket of the Phone Link app (AgentServer).
// It starts Phone Link when the socket is not there.

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Phone Link/agent.sock").path

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("phonelink-mcp: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
        for (i, b) in bytes.enumerated() { p[i] = b }
        p[bytes.count] = 0
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok != 0 { close(fd); return nil }
    return fd
}

/// The app that contains this helper (Contents/Helpers/phonelink-mcp), or nil.
func appBundle() -> String? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app.path : nil
}

func startApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = appBundle().map { ["-g", "-a", $0] } ?? ["-g", "-b", "com.mdobak.phonelink"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

var fd = connectSocket()
if fd == nil {
    startApp()
    let end = Date().addingTimeInterval(30)
    while fd == nil, Date() < end {
        usleep(250_000)
        fd = connectSocket()
    }
}
guard let sock = fd else { fail("Phone Link did not start. Open Phone Link on this Mac and try again.") }
signal(SIGPIPE, SIG_IGN)

@Sendable func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Bool {
    var off = 0
    while off < n {
        let w = write(fd, buf + off, n - off)
        if w < 0 { if errno == EINTR { continue }; return false }
        off += w
    }
    return true
}

/// Copies bytes from one descriptor to the other until the end of the input.
@Sendable func pump(_ from: Int32, _ to: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return }
        let ok = buf.withUnsafeBytes { writeAll(to, $0.baseAddress!, n) }
        if !ok { return }
    }
}

// The socket to stdout. When Phone Link quits, the helper stops.
Thread.detachNewThread {
    pump(sock, STDOUT_FILENO)
    exit(0)
}
// stdin to the socket. When the agent closes stdin, the helper stops.
pump(STDIN_FILENO, sock)
shutdown(sock, SHUT_WR)
// Wait a short time for the last replies.
usleep(500_000)
exit(0)
