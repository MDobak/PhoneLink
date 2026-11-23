import AVFoundation
import AudioToolbox
import Combine
import Network
import os

/// Routes mobile call audio between the phone and this Mac through the ShellCallAudio helper (adb).
/// Privacy: keeps no audio. Logs only counts, levels and delays.
final class CallAudio: ObservableObject {
    static let shared = CallAudio()
    private static let localPort: UInt16 = 47805 + AdbManager.portOffset
    static let settingKey = "callAudioOnMac"
    static let mutePhoneMicKey = "callAudioMutePhoneMic"
    fileprivate static let log = Logger(subsystem: "com.mdobak.phonelink", category: "callaudio")

    enum Route { case mac, phone }

    @Published private(set) var available = false
    var offered: Bool { available && !PhoneFeature.callAudio.isOff }
    @Published private(set) var callActive = false
    @Published private(set) var audioOnMac = false
    /// Resets to the setting at each new call.
    @Published private(set) var route: Route = .mac
    @Published private(set) var micMuted = false
    @Published private(set) var error: String?

    private let queue = DispatchQueue(label: "phonelink.callaudio")
    private var serial: String?
    private var process: Process?
    private var conn: NWConnection?
    private var generation = 0
    private var failures = 0
    private var bag = Set<AnyCancellable>()
    /// Main thread.
    private var engine: CallAudioEngine?
    private var sentWant: Bool?
    private var sentMute: Bool?
    /// Only calls made or answered on this Mac use its audio.
    private var macCallAt = Date.distantPast
    private var devicesKey = ""

    func start() {
        PhoneLink.shared.$adbSerial.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.setSerial(s) }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync(); self?.devicesChanged() }.store(in: &bag)
        devicesKey = Self.currentDevicesKey()
    }

    /// The next call that starts uses this Mac's audio. Calls started on the phone stay on the phone.
    func macStartsCall() {
        guard !callActive else { return }
        macCallAt = Date()
    }

    private static func currentDevicesKey() -> String {
        let d = UserDefaults.standard
        return (d.string(forKey: AudioDevices.inputKey) ?? "") + "|" + (d.string(forKey: AudioDevices.outputKey) ?? "")
    }

    private func devicesChanged() {
        let k = Self.currentDevicesKey()
        guard k != devicesKey else { return }
        devicesKey = k
        CallAudio.log.info("call audio devices changed in the settings")
        engine?.useNewDevices()
    }

    // MARK: User controls (main thread)

    func setRoute(_ r: Route) {
        guard r != route else { return }
        route = r
        if r == .mac { error = nil }
        sync()
    }

    /// DTMF. Works only while call audio is on this Mac; the phone injects the tones.
    func sendKeys(_ digits: String) {
        guard audioOnMac, !digits.isEmpty else { return }
        send(["t": "call.dtmf", "digits": digits])
        digits.forEach { engine?.playKeyTone($0); CallRecorder.shared.addKey($0) }
    }

    func demoActiveCall() {
        available = true
        callActive = true
        route = .mac
        audioOnMac = true
    }

    func toggleMute() {
        micMuted.toggle()
        engine?.setMuted(micMuted)
        CallAudio.log.info("mac mic muted: \(self.micMuted)")
    }

    // MARK: State (main thread)

    private func sync() {
        let want = offered && callActive && route == .mac
        let mute = UserDefaults.standard.bool(forKey: Self.mutePhoneMicKey)
        guard want != sentWant || (want && mute != sentMute) else { return }
        sentWant = want
        sentMute = mute
        CallAudio.log.info("ask phone: audio \(want), muteMic \(mute)")
        send(["t": "call.audio", "on": want, "muteMic": mute])
    }

    private func handle(_ j: JSON) {
        switch j["t"] as? String {
        case "hello":
            available = j["interceptable"] as? Bool ?? false
            CallAudio.log.info("helper ready, interceptable \(self.available)")
            sentWant = nil
            sync()
        case "call.state":
            let active = j["active"] as? Bool ?? false
            let audio = j["audio"] as? Bool ?? false
            let voip = j["voip"] as? Bool ?? false
            if active != callActive {
                callActive = active
                if active {
                    // Only a call started on this Mac in the last 60 s uses the Mac. The phone can be slow to start it.
                    let fromMac = Date().timeIntervalSince(macCallAt) < 60
                    macCallAt = .distantPast
                    route = UserDefaults.standard.bool(forKey: Self.settingKey) && fromMac ? .mac : .phone
                    CallAudio.log.info("new call, made or answered on this Mac: \(fromMac)")
                    micMuted = false
                    error = nil
                }
                // VoIP calls start on the phone.
                if active, voip { route = .phone }
                PhoneLink.shared.helperCallState(active: active, internet: voip)
            }
            if let e = j["error"] as? String, active { error = e; CallAudio.log.error("phone: \(e, privacy: .public)") }
            if audio != audioOnMac { audio ? startEngine() : stopEngine() }
            // The phone stopped the audio. Ask again only after a change.
            if !audio, sentWant == true, j["error"] != nil { sentWant = false; route = .phone }
            if !active { sentWant = false }
            sync()
        case "call.stats":
            let n = { (k: String) in (j[k] as? NSNumber)?.intValue ?? -1 }
            CallAudio.log.info("phone stats: down \(n("downFrames")) frames rms \(n("downRms")), up \(n("upFrames")) frames rms \(n("upRms")), dropped \(n("upDropped")), underruns \(n("upUnderruns")), queue \(n("upQueueMs")) ms, phone mic muted \(j["micMuted"] as? Bool ?? false)")
        default: break
        }
    }

    private func startEngine() {
        audioOnMac = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: makeEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    guard self.audioOnMac else { return }
                    if ok { self.makeEngine() } else { self.micDenied() }
                }
            }
        default: micDenied()
        }
    }

    private func micDenied() {
        error = "Phone Link can’t use the microphone. Allow it in System Settings > Privacy & Security > Microphone."
        route = .phone
        stopEngine()
        sync()
    }

    private func makeEngine() {
        guard engine == nil else { return }
        let e = CallAudioEngine { [weak self] frame in self?.sendAudio(frame) }
        do {
            try e.start()
            e.setMuted(micMuted)
            engine = e
            CallAudio.log.info("mac audio started")
        } catch {
            CallAudio.log.error("mac audio did not start: \(error.localizedDescription, privacy: .public)")
            self.error = "The audio of this Mac did not start."
            route = .phone
            audioOnMac = false
            sync()
        }
    }

    private func stopEngine() {
        audioOnMac = false
        engine?.stop()
        if engine != nil { CallAudio.log.info("mac audio stopped") }
        engine = nil
    }

    // MARK: Helper process (queue)

    private func setSerial(_ s: String?) {
        queue.async {
            guard s != self.serial else { return }
            self.serial = s
            self.generation += 1
            self.failures = 0
            self.stopLocked()
            if s != nil { self.launch(self.generation) }
        }
    }

    private func launch(_ gen: Int) {
        guard gen == generation, let serial, let adb = AdbManager.path else { return }
        let classpath = AdbManager.classpath(serial)
        guard gen == generation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "shell", "CLASSPATH=\(classpath) app_process / com.mdobak.phonelink.ShellCallAudio"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.queue.async { self?.ended(gen) } }
        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            buffer += String(decoding: d, as: UTF8.self)
            if buffer.contains("ready") {
                h.readabilityHandler = nil
                self?.queue.async { self?.connect(gen) }
            }
        }
        do { try p.run() } catch { ended(gen); return }
        process = p
    }

    private func connect(_ gen: Int) {
        guard gen == generation, let serial,
              AdbManager.run(["-s", serial, "forward", "tcp:\(Self.localPort)", "localabstract:phonelink-call"])?.status == 0 else { ended(gen); return }
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.localPort)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.read(c, gen)
            case .failed, .waiting: self.ended(gen)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func ended(_ gen: Int) {
        guard gen == generation else { return }
        generation += 1
        stopLocked()
        failures += 1
        let delay = min(60.0, 2.0 * pow(2.0, Double(min(failures - 1, 5))))
        CallAudio.log.info("helper stopped, next start in \(Int(delay)) s")
        let next = generation
        queue.asyncAfter(deadline: .now() + delay) {
            guard next == self.generation, self.serial != nil else { return }
            self.launch(next)
        }
    }

    private func stopLocked() {
        conn?.cancel()
        conn = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        DispatchQueue.main.async {
            self.available = false
            self.sentWant = nil
            self.stopEngine()
            if self.callActive { self.callActive = false; PhoneLink.shared.helperCallState(active: false) }
        }
    }

    private func read(_ c: NWConnection, _ gen: Int) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, err in
            guard let self, gen == self.generation else { return }
            guard let head, head.count == 4, err == nil else { self.ended(gen); return }
            let n = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard n > 0, n < 1 << 20 else { self.ended(gen); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard gen == self.generation else { return }
                guard let body, body.count == n, err == nil else { self.ended(gen); return }
                let b = Data(body)
                if b[b.startIndex] == 3 {
                    let pcm = b.dropFirst()
                    CallRecorder.shared.addRemote(pcm)
                    DispatchQueue.main.async { self.engine?.play(pcm) }
                } else if b[b.startIndex] == 1, let j = (try? JSONSerialization.jsonObject(with: b.dropFirst())) as? JSON {
                    if self.failures > 0, j["t"] as? String == "hello" { self.failures = 0 }
                    DispatchQueue.main.async { self.handle(j) }
                }
                self.read(c, gen)
            }
        }
    }

    private func send(_ j: JSON) {
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        frame(1, d)
    }

    private func sendAudio(_ pcm: Data) {
        CallRecorder.shared.addLocal(pcm)
        frame(3, pcm)
    }

    private func frame(_ type: UInt8, _ body: Data) {
        queue.async {
            guard let c = self.conn else { return }
            var n = UInt32(body.count + 1).bigEndian
            var d = Data(bytes: &n, count: 4)
            d.append(type)
            d.append(body)
            c.send(content: d, completion: .contentProcessed { _ in })
        }
    }
}

/// Mic audio (with echo cancellation) goes to the phone as 20 ms frames of 16 kHz mono Int16.
/// Phone audio plays through a small jitter buffer.
private final class CallAudioEngine {
    private static let rate = 16_000.0
    private static let frame = 320
    /// Silence before the first frame and after an underrun, against jitter.
    private static let prebuffer = 960 // 60 ms
    /// Above this, new frames are dropped.
    private static let maxQueued = 2_560 // 160 ms

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var tonePlayer = AVAudioPlayerNode()
    private(set) var echoCancellation = true
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    private let onFrame: (Data) -> Void
    private let lock = NSLock()
    private var muted = false
    private var pending: [Int16] = []
    private var converter: AVAudioConverter?
    private var queued = 0 // main thread
    private var observer: NSObjectProtocol?
    private var statsTimer: Timer?
    private var sent = 0, played = 0, dropped = 0, underruns = 0
    private var micSq = 0.0, playSq = 0.0

    init(onFrame: @escaping (Data) -> Void) { self.onFrame = onFrame }

    func setMuted(_ m: Bool) {
        lock.lock(); muted = m; pending.removeAll(); lock.unlock()
        engine.inputNode.isVoiceProcessingInputMuted = m
    }

    func start() throws {
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            // Voice processing fails on some devices (-10875).
            CallAudio.log.error("voice processing did not start: \(error.localizedDescription, privacy: .public). Start without it.")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            // A node can be attached to one engine only.
            tonePlayer = AVAudioPlayerNode()
            echoCancellation = false
            try startEngine(voiceProcessing: false)
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.logStats() }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        // On macOS, voice processing fails (-10875) if the output node does not exist yet.
        _ = engine.outputNode
        setDevices()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.attach(tonePlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: playFormat)
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing creates a new audio unit, so set the devices on it too.
            setDevices()
        }
        try installTap()
        engine.prepare()
        try engine.start()
        player.play()
        tonePlayer.play()
        startedAt = Date()
        CallAudio.log.info("mac engine started, voice processing \(voiceProcessing, privacy: .public)")
    }

    private func installTap() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mono, to: sendFormat) else {
            throw NSError(domain: "CallAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        converter = conv
        CallAudio.log.info("mic format: \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) channels")
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 50), format: inFormat) { [weak self] buf, _ in
            self?.captured(buf, mono: mono, converter: conv)
        }
    }

    /// Element 1 of the audio unit is input, element 0 is output. Nil keeps the system default.
    private func setDevices() {
        func apply(_ unit: AudioUnit?, _ id: AudioDeviceID?, element: AudioUnitElement, what: String) {
            guard let unit, var dev = id else { return }
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { CallAudio.log.error("\(what, privacy: .public) device not set: \(st)") }
        }
        let inID = AudioDevices.chosen(input: true), outID = AudioDevices.chosen(input: false)
        let inUnit = engine.inputNode.audioUnit, outUnit = engine.outputNode.audioUnit
        apply(outUnit, outID, element: 0, what: "speaker")
        apply(inUnit, inID, element: inUnit == outUnit ? 1 : 0, what: "microphone")
        CallAudio.log.info("call devices: microphone \(inID.map(AudioDevices.name) ?? "default", privacy: .public), speaker \(outID.map(AudioDevices.name) ?? "default", privacy: .public)")
    }

    func playKeyTone(_ key: Character) {
        guard let f = DTMF.frequencies(key), engine.isRunning else { return }
        let n = AVAudioFrameCount(Self.rate * 0.12)
        guard let b = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: n), let p = b.floatChannelData?[0] else { return }
        b.frameLength = n
        let lo = 2 * Double.pi * f.low / Self.rate, hi = 2 * Double.pi * f.high / Self.rate
        for s in 0..<Int(n) {
            let fade = min(1, Double(min(s, Int(n) - s)) / 80)
            p[s] = Float((sin(lo * Double(s)) + sin(hi * Double(s))) * 0.08 * fade)
        }
        tonePlayer.scheduleBuffer(b, completionHandler: nil)
    }

    func useNewDevices() {
        startedAt = .distantPast
        restart()
    }

    /// Voice processing itself changes the devices just after start.
    private var startedAt = Date.distantPast

    /// A stopped engine does not always play again with the old player, so rebuild both.
    private func restart() {
        if engine.isRunning, Date().timeIntervalSince(startedAt) < 2 {
            CallAudio.log.info("audio devices changed just after the start, engine still runs: no restart")
            return
        }
        CallAudio.log.info("audio devices changed, new engine")
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        tonePlayer = AVAudioPlayerNode()
        playerGeneration += 1
        queued = 0
        lastDrain = Date()
        do {
            try startEngine(voiceProcessing: echoCancellation)
        } catch {
            CallAudio.log.error("restart failed: \(error.localizedDescription, privacy: .public)")
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    func stop() {
        statsTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        tonePlayer.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        logStats()
    }

    /// Tap thread. Voice processing puts the processed voice in the first channel.
    private func captured(_ buf: AVAudioPCMBuffer, mono: AVAudioFormat, converter: AVAudioConverter) {
        lock.lock(); let isMuted = muted; lock.unlock()
        if isMuted { return }
        let n = Int(buf.frameLength)
        guard n > 0, let src = buf.floatChannelData?[0],
              let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { return }
        m.frameLength = AVAudioFrameCount(n)
        m.floatChannelData![0].update(from: src, count: n)
        let cap = AVAudioFrameCount(Double(n) * Self.rate / mono.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return m
        }
        guard err == nil, out.frameLength > 0, let s = out.int16ChannelData?[0] else { return }
        var frames: [Data] = []
        lock.lock()
        pending.append(contentsOf: UnsafeBufferPointer(start: s, count: Int(out.frameLength)))
        while pending.count >= Self.frame {
            var sq = 0.0
            for i in 0..<Self.frame { let v = Double(pending[i]); sq += v * v }
            micSq += sq / Double(Self.frame)
            sent += 1
            frames.append(pending.prefix(Self.frame).withUnsafeBufferPointer { Data(buffer: $0) })
            pending.removeFirst(Self.frame)
        }
        lock.unlock()
        frames.forEach(onFrame)
    }

    /// Main thread. 16 kHz mono Int16 LE.
    func play(_ d: Data) {
        let frames = d.count / 2
        guard frames > 0 else { return }
        // Keep latency low: drop frames above 100 ms of backlog.
        if queued > 1_600, queued <= Self.maxQueued, Date().timeIntervalSince(startedAt) > 1 { dropped += 1; return }
        if queued > Self.maxQueued {
            dropped += 1
            // The player stalled (e.g. after a device change). Rebuild the engine.
            if Date().timeIntervalSince(lastDrain) > 1, Date().timeIntervalSince(startedAt) > 1 {
                CallAudio.log.error("player stalled, new engine")
                startedAt = .distantPast
                restart()
            }
            return
        }
        if queued == 0 {
            if played > 0 { underruns += 1 }
            schedule(silence(Self.prebuffer))
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let f = buf.floatChannelData![0]
        var sq = 0.0
        d.withUnsafeBytes { raw in
            for i in 0..<frames {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))
                sq += Double(v) * Double(v)
                f[i] = Float(v) / 32768
            }
        }
        playSq += sq / Double(frames)
        played += 1
        schedule(buf)
    }

    private func silence(_ frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        return b
    }

    /// Callbacks from an old player must not change `queued`.
    private var playerGeneration = 0
    private var lastDrain = Date()

    private func schedule(_ b: AVAudioPCMBuffer) {
        let n = Int(b.frameLength)
        let gen = playerGeneration
        queued += n
        player.scheduleBuffer(b) {
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.playerGeneration else { return }
                self.queued -= n
                self.lastDrain = Date()
            }
        }
    }

    private var lastSent = 0, lastPlayed = 0

    private func logStats() {
        lock.lock()
        let s = sent - lastSent; lastSent = sent
        let micRms = s > 0 ? Int((micSq / Double(s)).squareRoot()) : 0
        micSq = 0
        lock.unlock()
        let p = played - lastPlayed; lastPlayed = played
        let playRms = p > 0 ? Int((playSq / Double(p)).squareRoot()) : 0
        playSq = 0
        CallAudio.log.info("mac stats: sent \(s) frames rms \(micRms), played \(p) frames rms \(playRms), queue \(self.queued / 16) ms, dropped \(self.dropped), underruns \(self.underruns)")
    }
}
