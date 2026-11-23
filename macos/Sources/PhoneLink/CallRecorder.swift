import AVFoundation
import AppKit
import Combine
import os

/// Records a call into one 16 kHz mono AAC file: remote voice, local mic after voice processing, and DTMF tones.
/// Audio threads only copy frames; a serial queue mixes and writes, so recording never affects live audio.
/// Privacy: logs only counts and errors.
final class CallRecorder: ObservableObject {
    static let shared = CallRecorder()
    /// Set after the user saw the legal notice about telling the other party.
    static let disclosureKey = "callRecordingDisclosureShown"
    private static let log = Logger(subsystem: "com.mdobak.phonelink", category: "callrecorder")
    private static let rate = 16_000.0
    /// Write 250 ms behind real time, against network jitter.
    private static let delay = 4_000
    /// 800 ms. Trim the oldest audio past this (clock drift).
    private static let maxBacklog = 12_800

    /// Main thread.
    @Published private(set) var recording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastFile: URL?
    @Published var error: String?

    private let queue = DispatchQueue(label: "phonelink.callrecorder", qos: .utility)
    /// Any thread.
    private let active = OSAllocatedUnfairLock(initialState: false)
    private var bag = Set<AnyCancellable>()
    private var observing = false
    private var url: URL?

    // Queue only.
    private var file: AVAudioFile?
    private var remote: [Int16] = []
    private var local: [Int16] = []
    private var tones: [Float] = []
    private var clockStart: UInt64 = 0
    private var written: Int64 = 0
    private var timer: DispatchSourceTimer?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    static var folder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Link/Call Recordings", isDirectory: true)
    }

    // MARK: Hooks (any thread)

    func addRemote(_ pcm: Data) {
        guard active.withLock({ $0 }) else { return }
        queue.async { if self.file != nil { Self.append(pcm, to: &self.remote) } }
    }

    /// Mic audio sent to the phone. 16 kHz mono Int16 LE.
    func addLocal(_ pcm: Data) {
        guard active.withLock({ $0 }) else { return }
        queue.async { if self.file != nil { Self.append(pcm, to: &self.local) } }
    }

    func addKey(_ key: Character) {
        guard active.withLock({ $0 }) else { return }
        queue.async { if self.file != nil { self.tones.append(contentsOf: Self.tone(key)) } }
    }

    private static func append(_ d: Data, to a: inout [Int16]) {
        let n = d.count / 2
        a.reserveCapacity(a.count + n)
        d.withUnsafeBytes { raw in
            for i in 0..<n { a.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))) }
        }
    }

    private static func tone(_ key: Character) -> [Float] {
        guard let f = DTMF.frequencies(key) else { return [] }
        let n = Int(rate * 0.15)
        let lo = 2 * Double.pi * f.low / rate, hi = 2 * Double.pi * f.high / rate
        return (0..<n).map { s in
            let fade = min(1, Double(min(s, n - s)) / 80)
            return Float((sin(lo * Double(s)) + sin(hi * Double(s))) * 0.15 * fade)
        }
    }

    // MARK: Control (main thread)

    func start(title: String) {
        guard !recording else { return }
        let audio = CallAudio.shared
        guard audio.audioOnMac, audio.route == .mac else { return }
        observe()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(clean.isEmpty ? "Phone Call" : clean) \(df.string(from: Date()))"
        let dir = Self.folder
        var u = dir.appendingPathComponent(base + ".m4a")
        var k = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) \(k).m4a"); k += 1 }
        let f: AVAudioFile
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            f = try AVAudioFile(forWriting: u, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            Self.log.error("recording did not start: \(error.localizedDescription, privacy: .public)")
            self.error = "Phone Link can’t make the recording file in Music > Phone Link > Call Recordings."
            return
        }
        url = u
        lastFile = nil
        recording = true
        startedAt = Date()
        queue.async {
            self.file = f
            self.remote = []; self.local = []; self.tones = []
            self.written = 0
            self.clockStart = DispatchTime.now().uptimeNanoseconds
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.mix(final: false) }
            t.resume()
            self.timer = t
            self.active.withLock { $0 = true }
        }
        Self.log.info("recording started")
    }

    func stop() {
        guard recording else { return }
        recording = false
        startedAt = nil
        let u = url
        active.withLock { $0 = false }
        queue.async {
            // A start block may have run after the line above set active again.
            self.active.withLock { $0 = false }
            self.timer?.cancel()
            self.timer = nil
            self.mix(final: true)
            let frames = self.written
            // Releasing the file writes the end of the AAC file.
            self.file = nil
            self.remote = []; self.local = []; self.tones = []
            Self.log.info("recording stopped, \(frames / 16_000) s")
            if frames == 0, let u { try? FileManager.default.removeItem(at: u) }
            DispatchQueue.main.async {
                guard let u, frames > 0 else { return }
                self.lastFile = u
                Notifier.shared.postRecording(url: u)
            }
        }
    }

    func showInFinder() {
        guard let u = lastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    /// Also finishes the file when the app quits.
    private func observe() {
        guard !observing else { return }
        observing = true
        let audio = CallAudio.shared
        audio.$audioOnMac.receive(on: DispatchQueue.main).sink { [weak self] on in if !on { self?.stop() } }.store(in: &bag)
        audio.$route.receive(on: DispatchQueue.main).sink { [weak self] r in if r != .mac { self?.stop() } }.store(in: &bag)
        audio.$callActive.receive(on: DispatchQueue.main).sink { [weak self] a in
            if !a { self?.stop() } else { self?.lastFile = nil }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            guard let self else { return }
            self.stop()
            self.queue.sync {}
        }.store(in: &bag)
    }

    // MARK: Mixer (queue)

    /// Writes audio up to now - delay. A side without audio gives silence.
    private func mix(final: Bool) {
        guard let file else { return }
        var n: Int
        if final {
            n = max(remote.count, local.count, tones.count)
        } else {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1e9
            n = Int(Int64(elapsed * Self.rate) - Int64(Self.delay) - written)
        }
        guard n > 0 else { return }
        if !final {
            // Phone and Mac clocks drift. Keep the normal delay.
            if remote.count > n + Self.maxBacklog { remote.removeFirst(remote.count - n - Self.delay) }
            if local.count > n + Self.maxBacklog { local.removeFirst(local.count - n - Self.delay) }
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let r = min(n, remote.count), l = min(n, local.count), t = min(n, tones.count)
        for i in 0..<n {
            var v: Float = 0
            if i < r { v += Float(remote[i]) / 32768 }
            if i < l { v += Float(local[i]) / 32768 }
            if i < t { v += tones[i] }
            out[i] = max(-1, min(1, v))
        }
        remote.removeFirst(r); local.removeFirst(l); tones.removeFirst(t)
        do {
            try file.write(from: buf)
            written += Int64(n)
        } catch {
            Self.log.error("recording write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum DTMF {
    private static let keys = Array("123456789*0#ABCD")
    private static let low: [Double] = [697, 697, 697, 770, 770, 770, 852, 852, 852, 941, 941, 941, 697, 770, 852, 941]
    private static let high: [Double] = [1209, 1336, 1477, 1209, 1336, 1477, 1209, 1336, 1477, 1209, 1336, 1477, 1633, 1633, 1633, 1633]

    static func frequencies(_ key: Character) -> (low: Double, high: Double)? {
        guard let i = keys.firstIndex(of: key) else { return nil }
        return (low[i], high[i])
    }
}
