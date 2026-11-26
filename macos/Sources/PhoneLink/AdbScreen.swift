import Foundation
import Network

/// Screen sharing over adb. The screen server runs as the shell user, which can mirror the display
/// without a consent prompt. It ships in the helper APK, so it works with no app on the phone.
final class AdbScreen {
    /// App windows create their own instances, each with its own socket and port.
    static let shared = AdbScreen(port: 47801, socket: "phonelink-screen")
    private let localPort: UInt16
    private let socketName: String
    private let queue: DispatchQueue

    init(port: UInt16, socket: String) {
        localPort = port + AdbManager.portOffset
        socketName = socket
        queue = DispatchQueue(label: "phonelink.adbscreen." + socket)
    }

    /// Main thread.
    var onJSON: ((JSON) -> Void)?
    /// Network thread: (flags, H.264 Annex B frame).
    var onVideo: ((UInt8, Data) -> Void)?
    /// Main thread. The Bool is true if video arrived before the end.
    var onEnd: ((String?, Bool) -> Void)?

    private var process: Process?
    private var conn: NWConnection?
    private var generation = 0
    private var gotVideo = false

    /// extra: server options, e.g. "app=<package>" or "off=1".
    func start(serial: String, maxSize: Int, bitrate: Int, fps: Int, sound: Bool, extra: [String] = []) {
        queue.async {
            self.stopLocked()
            self.generation += 1
            let gen = self.generation
            self.gotVideo = false
            guard let adb = AdbManager.path,
                  AdbManager.run(["-s", serial, "forward", "tcp:\(self.localPort)", "localabstract:\(self.socketName)"])?.status == 0 else {
                self.end(gen, "The Mac cannot reach the phone.")
                return
            }
            let classpath = AdbManager.classpath(serial)
            guard gen == self.generation else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", serial, "shell",
                           "CLASSPATH=\(classpath) app_process / com.mdobak.phonelink.ShellServer \(maxSize) \(bitrate) \(fps) \(sound ? 1 : 0) socket=\(self.socketName) " + extra.joined(separator: " ")]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] _ in self?.queue.async { self?.end(gen, "Screen sharing stopped.") } }
            var buffer = ""
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                buffer += String(decoding: d, as: UTF8.self)
                if buffer.contains("ready") {
                    h.readabilityHandler = nil
                    self?.queue.async { if gen == self?.generation { self?.connect(gen) } }
                }
            }
            do { try p.run() } catch { self.end(gen, "Screen sharing did not start."); return }
            self.process = p
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.stopLocked()
        }
    }

    func send(_ j: JSON) {
        queue.async {
            guard let c = self.conn, let d = try? JSONSerialization.data(withJSONObject: j) else { return }
            var n = UInt32(d.count).bigEndian
            c.send(content: Data(bytes: &n, count: 4) + d, completion: .contentProcessed { _ in })
        }
    }

    private func stopLocked() {
        conn?.cancel()
        conn = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func end(_ gen: Int, _ msg: String?) {
        guard gen == generation else { return }
        generation += 1
        let had = gotVideo
        stopLocked()
        DispatchQueue.main.async { self.onEnd?(msg, had) }
    }

    private func connect(_ gen: Int) {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.read(c, gen)
            case .failed, .waiting: self.end(gen, "Phone Link could not connect to the screen server.")
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func read(_ c: NWConnection, _ gen: Int) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, done, err in
            guard let self, gen == self.generation else { return }
            guard let head, head.count == 4, err == nil else { self.end(gen, done ? "Screen sharing stopped." : err?.localizedDescription); return }
            let n = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard n > 0, n < 32 << 20 else { self.end(gen, "The screen server sent bad data."); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard gen == self.generation else { return }
                guard let body, body.count == n, err == nil else { self.end(gen, "Screen sharing stopped."); return }
                let b = Data(body)
                if b[0] == 1 {
                    if let j = (try? JSONSerialization.jsonObject(with: b.dropFirst())) as? JSON { DispatchQueue.main.async { self.onJSON?(j) } }
                } else if b[0] == 3, b.count > 1 {
                    ScreenAudioPlayer.shared.play(Data(b.dropFirst()))
                } else if b[0] == 2, b.count > 10 {
                    self.gotVideo = true
                    self.onVideo?(b[1], Data(b.dropFirst(10)))
                }
                self.read(c, gen)
            }
        }
    }
}
