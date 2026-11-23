import AppKit
import Combine
import CryptoKit
import Foundation
import Network

enum LinkState: Equatable {
    case idle
    case searching
    case connecting(String)
    case pairing(code: String, phoneConfirmed: Bool, macConfirmed: Bool)
    case connected
    case failed(String)
}

private struct Pairing: Codable {
    var phoneName: String
    var key: Data
    var host: String?
}

private let serviceType = "_phonelink._tcp"
private let port: UInt16 = 47800

/// The connection to the phone and the phone data the UI shows.
/// Network callbacks run on `queue`; published properties change on the main thread only.
final class PhoneLink: ObservableObject {
    static let shared = PhoneLink()

    /// Also .connected while the phone is used without the phone app.
    @Published private(set) var state: LinkState = .idle
    /// Main thread only.
    private var sessionState: LinkState = .idle { didSet { updateState() } }
    @Published private(set) var sessionConnected = false
    /// The phone used without the phone app, while adb sees it.
    @Published private(set) var directSerial: String?
    @Published private(set) var usesDirect = AdbManager.directPhoneID != nil
    /// A copy of AdbAgent.caps for the views.
    @Published private(set) var shellCaps: Set<String> = []
    /// Whether the app has WRITE_SECURE_SETTINGS to turn on Wireless debugging. Nil if unknown.
    @Published private(set) var adbWifiGranted: Bool?
    @Published private(set) var phoneName = ""
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    /// For example "SM-S928B". Used to find the phone in adb.
    @Published private(set) var phoneModel = ""
    @Published private(set) var adbSerial: String?
    private var screenViaAdb = false
    @Published private(set) var perms: [String: Bool] = [:]
    @Published private(set) var discovered: [Discovered] = []
    @Published private(set) var isPaired = false
    @Published private(set) var localNetworkBlocked = false

    static func openLocalNetworkSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(u) }
    }

    private static let demoBlocked = ProcessInfo.processInfo.environment["PHONELINK_DEMO_LOCAL_NETWORK"] == "blocked"

    private func setLocalNetworkBlocked(_ b: Bool) {
        if Self.demoBlocked { return }
        onMain { if self.localNetworkBlocked != b { self.localNetworkBlocked = b } }
    }

    @Published private(set) var threads: [SmsThread] = []
    @Published private(set) var messages: [Int64: [SmsMessage]] = [:]
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var notifications: [PhoneNotification] = []
    @Published private(set) var call: CallInfo? {
        didSet {
            if call == nil { callStartedAt = nil }
            else if call?.state == "active", oldValue?.state != "active" { callStartedAt = Date() }
        }
    }
    /// Nil while ringing or with no call.
    @Published private(set) var callStartedAt: Date?
    @Published private(set) var screen: ScreenState = .stopped(nil)
    @Published private(set) var screenSound = false
    /// The phone shows a PIN or password lock screen during USB screen sharing.
    @Published var phoneLocked = false
    @Published private(set) var callLog: [CallLogEntry] = []
    @Published private(set) var media: MediaInfo?
    @Published private(set) var mediaArt: NSImage?
    @Published private(set) var ringing = false
    @Published private(set) var photos: [PhonePhoto] = []
    @Published private(set) var photosError: String?
    @Published private(set) var photoThumbs: [Int64: NSImage] = [:]
    /// Hidden from the list until the phone replies.
    private var deletingPhotos = Set<Int64>()
    @Published private(set) var mmsImages: [Int64: NSImage] = [:]
    private var requestedParts = Set<Int64>()
    private var lowBatteryShown = false
    @Published var banner: String?
    @Published var focusThread: Int64?
    private var newMessageAddress: String?

    /// Called on the network queue with (flags, Annex B data).
    var videoSink: ((UInt8, Data) -> Void)?

    let queue = DispatchQueue(label: "phonelink.link", qos: .userInteractive)
    private var browser: NWBrowser?
    private var caps: AnyCancellable?
    private var endpoints: [String: NWEndpoint] = [:]
    private var conn: NWConnection?
    private var generation = 0
    private var tx: FrameCipher?
    private var rx: FrameCipher?
    private var pingTimer: Timer?
    private var lastReceive = Date()
    private var retry: DispatchWorkItem?
    /// On queue. Stops an attempt that gets no handshake reply in time.
    private var connectTimeout: DispatchWorkItem?
    /// On queue. Reconnect attempts since the last session; selects the address to try.
    private var attempts = 0
    /// On queue. Used when the phone does not answer Bonjour, which happens when its screen is off.
    private var lastAddress: NWEndpoint?
    private var pendingSends: [String: String] = [:] // ref -> thread id text
    /// On queue. Kept so that a failed request can go again to the shell helper.
    private var appRequests: [String: JSON] = [:]
    /// On queue. Kept so that a failed request can go again to the app.
    private var shellRequests: [String: JSON] = [:]
    /// On queue.
    private var routePerms: [String: Bool] = [:]
    private var watchingNotifications = false
    private var directTicks = 0
    private var grantTried = false
    private var wifiAsked = false
    private var lastWifiAsk = Date.distantPast

    // Handshake values that live only until the session keys exist.
    private var nonceM = Data()
    private var pairPrivate: P256.KeyAgreement.PrivateKey?
    private var pairKey: Data?
    private var phoneConfirmed = false
    private var macConfirmed = false
    private var handshakeSalt = Data()
    private var handshakeName = ""
    private var connectingHost: String?

    /// Access on queue only. isPaired is the copy for the views.
    private var pairing: Pairing? {
        didSet {
            savePairing()
            let paired = pairing != nil
            onMain { self.isPaired = paired }
        }
    }

    private let macId: String = {
        if let id = UserDefaults.standard.string(forKey: "macId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "macId")
        return id
    }()

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Link", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("pairing.json")
    }

    private init() {
        if Self.demoBlocked { localNetworkBlocked = true }
        if let d = try? Data(contentsOf: Self.storeURL), let p = try? JSONDecoder().decode(Pairing.self, from: d) {
            pairing = p
            isPaired = true
            phoneName = p.phoneName
        }
    }

    private func savePairing() {
        let url = Self.storeURL
        if let p = pairing, let d = try? JSONEncoder().encode(p) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    // MARK: - Discovery

    func start() {
        if Self.isDemo {
            if ProcessInfo.processInfo.environment["PHONELINK_DEMO"] == "setup" {
                discovered = [Discovered(name: "Galaxy S24 Ultra")]
            } else if ProcessInfo.processInfo.environment["PHONELINK_DEMO"] == "pair" {
                phoneName = "Galaxy S24 Ultra"
                sessionState = .pairing(code: "482913", phoneConfirmed: true, macConfirmed: false)
            } else { loadDemo() }
            return
        }
        let agent = AdbAgent.shared
        agent.onPush = { [weak self] j in self?.handleShell(j) }
        agent.onReady = { [weak self] on in
            guard let self else { return }
            // A restarted helper does not watch notifications yet, and caps can stay the same. Ask again.
            self.watchingNotifications = false
            self.updateNotificationWatch()
        }
        caps = agent.$caps.receive(on: DispatchQueue.main).sink { [weak self] c in self?.shellCapsChanged(c) }
        updateState()
        queue.async {
            self.startBrowser()
            if let host = self.pairing?.host { self.connect(host: host) }
        }
        if usesDirect { refreshAdb() }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Call on queue. Restarts after 3 s if the browser fails, for example after a network change.
    private func startBrowser() {
        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var map: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint { map[name] = r.endpoint }
            }
            self.endpoints = map
            if !map.isEmpty { self.setLocalNetworkBlocked(false) }
            if self.pairing != nil, self.conn == nil, let first = map.keys.sorted().first, let ep = map[first] {
                self.open(ep, label: first, host: nil)
            }
            let names = map.keys.sorted().map { Discovered(name: $0) }
            self.onMain { self.discovered = names }
        }
        b.stateUpdateHandler = { [weak self, weak b] st in
            guard let self else { return }
            // -65570: the system does not let this app use mDNS (no local network access).
            if case .waiting(let e) = st, case .dns(let code) = e, code == -65570 { self.setLocalNetworkBlocked(true) }
            guard case .failed(let e) = st, let b, self.browser === b else { return }
            NSLog("Phone Link: the Bonjour browser failed (%@). It starts again.", e.localizedDescription)
            b.cancel()
            self.browser = nil
            self.queue.asyncAfter(deadline: .now() + 3) { if self.browser == nil { self.startBrowser() } }
        }
        browser = b
        b.start(queue: queue)
    }

    // MARK: - Connect

    func connect(service name: String) {
        queue.async {
            guard let ep = self.endpoints[name] else { return }
            self.open(ep, label: name, host: nil)
        }
    }

    func connect(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        queue.async {
            self.open(.hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: port)!), label: h, host: h)
        }
    }

    /// Forwards the phone port with adb, then connects to localhost.
    /// serial nil: the linked phone, else a phone on a cable.
    func connectUSB(serial chosen: String? = nil) {
        guard AdbManager.path != nil else {
            fail("To connect with USB, set up USB debugging in Settings > Connections.")
            return
        }
        let linked = AdbManager.shared.linkedSerial
        DispatchQueue.global().async {
            // adb needs a serial when more than one device is attached.
            let ready = AdbManager.listDevices().filter { $0.state == .ready }
            let serial = chosen ?? linked ?? ready.first(where: \.usb)?.serial ?? ready.first?.serial
            let args = (serial.map { ["-s", $0] } ?? []) + ["forward", "tcp:\(port)", "tcp:\(port)"]
            if AdbManager.run(args)?.status == 0 { self.connect(host: "127.0.0.1") }
            else { self.fail("The Mac cannot connect through the USB cable. See Settings > Connections.") }
        }
    }

    func unpair() {
        send(["t": "unpair"])
        queue.asyncAfter(deadline: .now() + 0.3) {
            self.retry?.cancel()
            self.closeConnection()
            self.pairing = nil
            self.onMain { self.sessionState = .idle }
        }
        onMain {
            self.phoneName = ""
            // A phone used without the phone app can stay linked, so keep its data.
            if self.directSerial == nil { self.clearPhoneData() }
        }
    }

    /// Main thread.
    private func clearPhoneData() {
        threads = []; messages = [:]; mmsImages = [:]; requestedParts = []
        contacts = []; callLog = []
        photos = []; photoThumbs = [:]; photosError = nil
        notifications = []
        battery = nil; media = nil; mediaArt = nil
        Notifier.shared.removeAll()
        SpotlightIndex.shared.update()
    }

    /// Call on queue.
    private func open(_ ep: NWEndpoint, label: String, host: String?) {
        closeConnection()
        retry?.cancel()
        generation += 1
        let gen = generation
        connectingHost = host
        // Bonjour can wait forever with no error (for example when the phone does not answer mDNS), which blocks
        // retries. Give up after 15 s with no handshake reply. Pairing has no limit: the user compares the codes.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, self.tx == nil, self.pairKey == nil else { return }
            self.lost("The phone does not answer.")
        }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let c = NWConnection(to: ep, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        onMain { self.sessionState = .connecting(label) }
        c.stateUpdateHandler = { [weak self] st in
            guard let self, gen == self.generation else { return }
            switch st {
            case .ready:
                if case let .hostPort(h, p)? = c.currentPath?.remoteEndpoint { self.lastAddress = .hostPort(host: h, port: p) }
                if host != "127.0.0.1" { self.setLocalNetworkBlocked(false) }
                self.sendHello()
            case .failed(let e): self.lost("Connection failed: \(e.localizedDescription)")
            case .waiting(let e):
                if c.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    self.setLocalNetworkBlocked(true)
                    self.lost("No access to the local network")
                } else {
                    self.lost("Cannot reach the phone: \(e.localizedDescription)")
                }
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// Call on queue.
    private func closeConnection() {
        if tx != nil {
            AdbManager.shared.sessionEnded()
            FileHub.shared.sessionEnded()
            RemoteDesktopHost.shared.linkClosed()
            RemoteTerminal.shared.linkClosed()
        }
        connectTimeout?.cancel()
        connectTimeout = nil
        remoteVideoQueued = 0
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        tx = nil
        rx = nil
        pairPrivate = nil
        pairKey = nil
        generation += 1
        onMain {
            ScreenAudioPlayer.shared.stop()
            self.media = nil
            self.ringing = false
            if case .streaming = self.screen { self.screen = .stopped(nil) }
            if case .waiting = self.screen { self.screen = .stopped(nil) }
        }
    }

    /// Call on queue.
    private func lost(_ why: String) {
        let wasConnected = tx != nil
        closeConnection()
        onMain {
            self.sessionState = .failed(wasConnected ? "Connection lost" : why)
            // A call that only the call audio helper reports continues without the app session.
            if self.call?.fromHelper != true, self.call != nil { self.call = nil; Notifier.shared.removeCall() }
            if self.directSerial == nil {
                if self.screenViaAdb { self.stopScreen() }
                self.adbSerial = nil
            }
            self.refreshAdb()
        }
        guard pairing != nil else { return }
        let host = connectingHost
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.conn == nil else { return }
            self.reconnect(host: host)
        }
        retry?.cancel()
        retry = w
        queue.asyncAfter(deadline: .now() + 3, execute: w)
    }

    /// Rotates through the Bonjour service, the last address and the saved host, so that one dead address cannot
    /// block the reconnect. Call on queue.
    private func reconnect(host: String?) {
        // Every second attempt uses adb when it sees the phone: it needs no local network permission and works
        // when Bonjour does not.
        if attempts % 2 == 0, AdbManager.path != nil {
            attempts += 1
            DispatchQueue.main.async {
                guard PhoneRouter.usesDebugging else { self.queue.async { self.reconnect(host: host) }; return }
                AdbManager.shared.pairedPhoneSerial { serial in
                    guard let serial else { self.queue.async { self.reconnect(host: host) }; return }
                    DispatchQueue.global().async {
                        let ok = AdbManager.run(["-s", serial, "forward", "tcp:\(port)", "tcp:\(port)"])?.status == 0
                        self.queue.async {
                            guard self.conn == nil, self.pairing != nil else { return }
                            if ok {
                                self.open(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), label: "127.0.0.1", host: "127.0.0.1")
                            } else {
                                self.reconnect(host: host)
                            }
                        }
                    }
                }
            }
            return
        }
        var tries: [(NWEndpoint, String, String?)] = []
        if let name = endpoints.keys.sorted().first, let ep = endpoints[name] { tries.append((ep, name, nil)) }
        if let ep = lastAddress, case let .hostPort(h, _) = ep { tries.append((ep, "\(h)", nil)) }
        // 127.0.0.1 works only through "adb forward".
        if let h = (host == "127.0.0.1" ? nil : host) ?? pairing?.host, h != "127.0.0.1" {
            tries.append((.hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: port)!), h, h))
        }
        guard !tries.isEmpty else { return }
        let (ep, label, h) = tries[attempts % tries.count]
        attempts += 1
        open(ep, label: label, host: h)
    }

    private func fail(_ msg: String) { onMain { self.sessionState = .failed(msg) } }

    // MARK: - Framing

    private func frame(_ body: Data) -> Data {
        var n = UInt32(body.count).bigEndian
        var d = Data(bytes: &n, count: 4)
        d.append(body)
        return d
    }

    private func readFrame(_ done: @escaping (Data) -> Void) {
        guard let c = conn else { return }
        let gen = generation
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, eof, err in
            guard let self, gen == self.generation else { return }
            guard let head, head.count == 4, err == nil else { self.lost(eof ? "The phone closed the connection." : "The connection was interrupted."); return }
            let n = head.reduce(0) { $0 << 8 | Int($1) }
            guard n <= 16 << 20 else { self.lost("The phone sent data that Phone Link cannot read."); return }
            if n == 0 { self.lastReceive = Date(); done(Data()); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard gen == self.generation else { return }
                guard let body, body.count == n, err == nil else { self.lost("The connection was interrupted."); return }
                self.lastReceive = Date()
                done(body)
            }
        }
    }

    private func sendPlain(_ j: JSON) {
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        conn?.send(content: frame(d), completion: .contentProcessed { _ in })
    }

    private func readPlain(_ done: @escaping (JSON) -> Void) {
        readFrame { [weak self] d in
            guard let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { self?.lost("The phone did not complete the connection. Try again."); return }
            done(j)
        }
    }

    // MARK: - Handshake

    private func sendHello() {
        nonceM = LinkCrypto.random(32)
        phoneConfirmed = false
        macConfirmed = false
        var hello: JSON = ["t": "hello", "v": 1, "id": macId, "name": Host.current().localizedName ?? "Mac",
                           "nonce": nonceM.base64EncodedString()]
        if pairing == nil {
            let k = P256.KeyAgreement.PrivateKey()
            pairPrivate = k
            hello["pub"] = k.publicKey.derRepresentation.base64EncodedString()
        }
        sendPlain(hello)
        readPlain { [weak self] r in self?.onHelloReply(r) }
    }

    private func onHelloReply(_ r: JSON) {
        guard let nonceP = r.str("nonce").flatMap({ Data(base64Encoded: $0) }) else {
            switch r.str("status") {
            case "denied": closeConnection(); fail("On the phone, open Phone Link and tap \"Pair a new Mac\". Then try again.")
            case "unknown":
                closeConnection()
                pairing = nil
                fail("The phone does not know this Mac. Pair again.")
            default: lost("The phone did not complete the connection. Try again.")
            }
            return
        }
        handshakeSalt = nonceM + nonceP
        let name = r.str("name") ?? "Phone"
        handshakeName = name
        onMain { self.phoneName = name }

        if r.str("status") == "pair", let priv = pairPrivate,
           let pubData = r.str("pub").flatMap({ Data(base64Encoded: $0) }),
           let pub = try? P256.KeyAgreement.PublicKey(derRepresentation: pubData),
           let secret = try? priv.sharedSecretFromKeyAgreement(with: pub) {
            let shared = secret.withUnsafeBytes { Data($0) }
            pairKey = LinkCrypto.hkdf(shared, salt: handshakeSalt, info: "phonelink pair v1")
            let code = LinkCrypto.sas(shared, salt: handshakeSalt)
            onMain { self.sessionState = .pairing(code: code, phoneConfirmed: false, macConfirmed: false) }
            readPlain { [weak self] c in self?.onPhoneConfirm(c) }
        } else if r.str("status") == "ok", let key = pairing?.key {
            startSession(key: key)
        } else {
            lost("The phone did not complete the connection. Try again.")
        }
    }

    private func onPhoneConfirm(_ c: JSON) {
        guard let key = pairKey else { return }
        let mac = c.str("mac").flatMap { Data(base64Encoded: $0) } ?? Data()
        guard c.bool("ok"), LinkCrypto.equal(mac, LinkCrypto.hmac(key, "p-confirm")) else {
            closeConnection()
            fail("Pairing was cancelled on the phone.")
            return
        }
        phoneConfirmed = true
        updatePairingState()
        finishPairingIfReady()
    }

    func confirmPairing(_ ok: Bool) {
        queue.async {
            guard let key = self.pairKey else { return }
            guard ok else {
                self.sendPlain(["t": "confirm", "ok": false])
                self.closeConnection()
                self.onMain { self.sessionState = .idle }
                return
            }
            self.macConfirmed = true
            self.sendPlain(["t": "confirm", "ok": true, "mac": LinkCrypto.hmac(key, "m-confirm").base64EncodedString()])
            self.updatePairingState()
            self.finishPairingIfReady()
        }
    }

    private func updatePairingState() {
        let p = phoneConfirmed, m = macConfirmed
        onMain {
            if case let .pairing(code, _, _) = self.sessionState { self.sessionState = .pairing(code: code, phoneConfirmed: p, macConfirmed: m) }
        }
    }

    private func finishPairingIfReady() {
        guard phoneConfirmed, macConfirmed, let key = pairKey else { return }
        pairing = Pairing(phoneName: handshakeName, key: key, host: connectingHost)
        startSession(key: key)
    }

    private func startSession(key: Data) {
        tx = FrameCipher(LinkCrypto.hkdf(key, salt: handshakeSalt, info: "m2p"))
        rx = FrameCipher(LinkCrypto.hkdf(key, salt: handshakeSalt, info: "p2m"))
        pairPrivate = nil
        pairKey = nil
        // Save this address for the next start. A USB address (127.0.0.1 through "adb forward") does not replace a
        // saved Wi-Fi address, because the forward ends when adb stops.
        if let h = connectingHost, let saved = pairing, saved.host != h, saved.host == nil || h != "127.0.0.1" { pairing?.host = h }
        attempts = 0
        // Only the linked phone knows this token, so adb can find that phone (see AdbManager).
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        AdbManager.shared.sessionStarted(token: token)
        appRequests = [:]
        onMain {
            self.grantTried = false
            self.wifiAsked = false
            self.sessionState = .connected
            self.send(["t": "adb.token", "token": token])
            self.send(["t": "sms.threads"])
            self.send(["t": "notif.list"])
            self.send(["t": "contacts"])
            self.send(["t": "calls.log", "limit": 100])
            FocusSync.shared.resend()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshAdb() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.askWirelessDebugging() }
        }
        readLoop()
    }

    // MARK: - Session

    private func readLoop() {
        readFrame { [weak self] sealed in
            guard let self, let rx = self.rx else { return }
            guard let plain = try? rx.open(sealed), let type = plain.first else { self.lost("Phone Link could not decrypt the data from the phone. Pair again."); return }
            let body = plain.dropFirst()
            if type == 1 {
                if let j = (try? JSONSerialization.jsonObject(with: body)) as? JSON {
                    let t = j.str("t") ?? ""
                    if t.hasPrefix("fs.") { FileHub.shared.handle(j) }
                    // Remote Desktop and Terminal: these handlers run on the link queue and must not block it.
                    else if t.hasPrefix("rd.") { RemoteDesktopHost.shared.handle(j) }
                    else if t.hasPrefix("term.") { RemoteTerminal.shared.handle(j) }
                    else { self.onMain { self.handle(j) } }
                }
            } else if type == 3, body.count >= 4 {
                let id = body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                FileHub.shared.onChunk(id, Data(body.dropFirst(4)))
            } else if type == 4 {
                ScreenAudioPlayer.shared.play(Data(body))
            } else if type == 6, body.count >= 4 {
                // Terminal input from the phone: [tab id u32 BE][bytes].
                let id = body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                RemoteTerminal.shared.input(id: id, data: Data(body.dropFirst(4)))
            } else if type == 2, body.count > 9 {
                let flags = body[body.startIndex]
                self.videoSink?(flags, Data(body.dropFirst(9)))
            }
            self.readLoop()
        }
    }

    /// Routes through PhoneRouter. Replies from both paths go to handle(_:). Safe to call from any thread.
    func send(_ j: JSON) {
        guard let type = j.str("t") else { return }
        if PhoneFeature.owner(of: type)?.isOff == true {
            // "status" also carries the app permissions for Settings and Setup, so ask for it even when Battery is off.
            if type == "status" { queue.async { self.sendToApp(j) } }
            return
        }
        queue.async {
            let can = self.shellCan(type, j)
            switch PhoneRouter.decide(type, session: self.tx != nil, perms: self.routePerms, shellCan: can) {
            case .app?:
                if PhoneRouter.canRetry(type, from: .app) { self.appRequests[type] = j }
                self.sendToApp(j)
            case .shell?:
                self.sendToShell(j)
            case nil:
                break
            }
        }
    }

    private func shellCan(_ type: String, _ j: JSON? = nil) -> Bool {
        let agent = AdbAgent.shared
        // Older helpers can set only text ("clip.set").
        if type == "clip" { return agent.can("clip") || (j?["image"] == nil && agent.can("clip.set")) }
        return agent.can(type)
    }

    /// Falls back to the app session when the helper fails and the app can do the request.
    private func sendToShell(_ j: JSON) {
        guard let type = j.str("t") else { return }
        shellRequests[type] = j
        var m = j
        if type == "clip", !AdbAgent.shared.can("clip") {
            guard let text = j.str("text") else { return }
            m = ["t": "clip.set", "text": text]
        }
        // These requests have no reply, or more than one reply (photos.thumb). Their replies come as pushes.
        if ["photos.thumb", "clip", "clip.set", "ring", "ring.stop", "url.open", "call.dial", "notif.dismiss"].contains(m.str("t") ?? "") {
            AdbAgent.shared.request(m)
            return
        }
        AdbAgent.shared.request(m, timeout: 45) { [weak self] r in
            guard let self else { return }
            if let r, r.str("error") == nil || type == "photos.list" && !self.sessionConnected {
                self.handle(r, from: .shell)
                return
            }
            if !PhoneRouter.canRetry(type, from: .shell) { return }
            if self.sessionConnected { self.queue.async { self.sendToApp(j) } }
        }
    }

    /// Call on queue.
    private func sendToApp(_ j: JSON) {
        guard let tx = self.tx, let c = self.conn,
              let d = try? JSONSerialization.data(withJSONObject: j),
              let sealed = try? tx.seal(Data([1]) + d) else { return }
        c.send(content: self.frame(sealed), completion: .contentProcessed { _ in })
    }

    /// Do not read on queue (it uses queue.sync).
    var isSessionOpen: Bool { queue.sync { tx != nil } }

    /// Sends a sealed binary frame (file data). sent runs when the network took it, or at once with no session.
    func sendRaw(_ plain: Data, sent: @escaping () -> Void) {
        queue.async {
            guard let tx = self.tx, let c = self.conn, let sealed = try? tx.seal(plain) else { sent(); return }
            c.send(content: self.frame(sealed), completion: .contentProcessed { _ in sent() })
        }
    }

    // MARK: - Remote Desktop and Terminal

    /// "rd.*" and "term.*" messages. Safe to call from any thread.
    func sendRemote(_ j: JSON) { queue.async { self.sendToApp(j) } }

    /// No routing: the controls select the side themselves. Safe to call from any thread.
    func sendAppOnly(_ j: JSON) { queue.async { self.sendToApp(j) } }

    /// On queue.
    private var remoteVideoQueued = 0

    /// Type 5 frame: [flags][pts µs u64 BE][Annex B]. Flags: 1 = config (SPS/PPS), 2 = key frame.
    /// Returns false with no session or more than 1.5 MB queued; the encoder must then make a key frame.
    /// Do not call on the link queue (it uses queue.sync).
    @discardableResult
    func sendRemoteVideo(flags: UInt8, ptsUs: UInt64, data: Data) -> Bool {
        queue.sync {
            guard let tx = self.tx, let c = self.conn else { return false }
            if flags & 3 == 0, remoteVideoQueued > 1_500_000 { return false }
            var plain = Data([5, flags])
            var be = ptsUs.bigEndian
            plain.append(Data(bytes: &be, count: 8))
            plain.append(data)
            guard let sealed = try? tx.seal(plain) else { return false }
            let f = frame(sealed)
            let n = f.count
            let gen = generation
            remoteVideoQueued += n
            c.send(content: f, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async { if self.generation == gen { self.remoteVideoQueued = max(0, self.remoteVideoQueued - n) } }
            })
            return true
        }
    }

    /// Type 6 frame: [tab id u32 BE][bytes]. Safe to call from any thread.
    func sendTerminal(id: UInt32, data: Data) {
        queue.async {
            guard let tx = self.tx, let c = self.conn else { return }
            var plain = Data([6])
            var be = id.bigEndian
            plain.append(Data(bytes: &be, count: 4))
            plain.append(data)
            guard let sealed = try? tx.seal(plain) else { return }
            c.send(content: self.frame(sealed), completion: .contentProcessed { _ in })
        }
    }

    private func tick() {
        // While the session is down, keep looking for the paired phone in adb, so that a reconnect can use it.
        if usesDirect || state == .connected || isPaired { refreshAdb() }
        // Without the app, poll the helper for the battery every 30 s. Without the notification watch (sms.new),
        // poll the conversations too.
        if !sessionConnected, adbSerial != nil {
            directTicks += 1
            if directTicks % 3 == 0 {
                let types = watchingNotifications ? ["status"] : ["sms.threads", "status"]
                for t in types where path(forType: t) == .shell { send(["t": t]) }
            }
        }
        guard sessionConnected else { return }
        queue.async {
            self.sendToApp(["t": "ping"])
            if self.tx != nil, Date().timeIntervalSince(self.lastReceive) > 35 { self.lost("The phone does not answer.") }
        }
    }

    // MARK: - Messages from the phone (main thread)

    private func handleShell(_ j: JSON) {
        if let t = j.str("t"), j.str("error") != nil, t != "photos.list" {
            if sessionConnected, PhoneRouter.canRetry(t, from: .shell) {
                queue.async { if let r = self.shellRequests[t] { self.sendToApp(r) } }
            }
            return
        }
        handle(j, from: .shell)
    }

    private func handle(_ j: JSON, from source: PhonePath = .app) {
        // Drop traffic of features that are off. Keep "status": it has the permissions.
        if let t = j.str("t"), t != "status", PhoneFeature.owner(of: t)?.isOff == true { return }
        switch j.str("t") {
        case "status":
            if j["battery"] != nil, !PhoneFeature.battery.isOff { battery = j.int("battery") }
            charging = j.bool("charging")
            if let m = j.str("model"), !m.isEmpty, m != phoneModel { phoneModel = m; refreshAdb() }
            // The shell helper has no app permissions. Only the app reports them.
            guard source == .app else {
                if !sessionConnected, !isPaired, let n = j.str("name"), !n.isEmpty { phoneName = n }
                checkBattery()
                return
            }
            var p = (j["perms"] as? [String: Bool]) ?? [:]
            if let w = j["adbWifi"] as? JSON {
                adbWifiGranted = w["granted"] as? Bool
                if let g = adbWifiGranted { p["adbWifi"] = g }
            }
            perms = p
            queue.async { self.routePerms = p }
            updateNotificationWatch()
            maybeGrantWirelessDebugging()
            statusWaiters.forEach { $0() }
            statusWaiters = []
            if let n = j.str("name") { phoneName = n }
            checkBattery()

        case "sms.threads":
            threads = (j["threads"] as? [JSON] ?? []).map(SmsThread.init)
            NSLog("Phone Link: %d conversations from the %@", threads.count, source.rawValue)
            SpotlightIndex.shared.update()
        case "sms.messages":
            if let t = j.i64("thread") { messages[t] = (j["messages"] as? [JSON] ?? []).map(SmsMessage.init) }
        case "sms.new":
            guard let m = (j["message"] as? JSON).map(SmsMessage.init) else { return }
            if let list = messages[m.thread], !list.contains(where: { $0.id == m.id }) { messages[m.thread]?.append(m) }
            if m.outgoing, let a = newMessageAddress, Self.sameNumber(a, m.address) {
                newMessageAddress = nil
                focusThread = m.thread
            }
            if let i = threads.firstIndex(where: { $0.id == m.thread }) {
                var t = threads.remove(at: i)
                t.snippet = m.body
                t.date = m.date
                if !m.outgoing { t.unread += 1 }
                threads.insert(t, at: 0)
            } else {
                send(["t": "sms.threads"])
            }
        case "sms.sent":
            if !j.bool("ok") { banner = ["The message was not sent.", j.str("error")].compactMap { $0 }.joined(separator: " ") }
            if let ref = j.str("ref"), let t = pendingSends.removeValue(forKey: ref), let id = Int64(t) { loadMessages(thread: id) }
            else { send(["t": "sms.threads"]) }
        case "sms.delete":
            // Only a phone app that is the default SMS app can do this request (see canDeleteMessages).
            if !j.bool("ok") { banner = ["The phone did not delete the messages.", j.str("error")].compactMap { $0 }.joined(separator: " ") }
            send(["t": "sms.threads"])
            if let t = j.i64("thread"), messages[t] != nil { loadMessages(thread: t) }
        case "contacts":
            // A contact in more than one phone account comes more than one time. Keep each name and number once.
            var seen = Set<String>()
            contacts = (j["items"] as? [JSON] ?? []).map(Contact.init).filter {
                seen.insert($0.name + "|" + String($0.number.filter(\.isNumber).suffix(9))).inserted
            }
            SpotlightIndex.shared.update()

        case "notif.list":
            let items = j["items"] as? [JSON] ?? []
            items.forEach { Notifier.shared.cacheIcon($0) }
            notifications = items.map(PhoneNotification.init).reversed()
            NSLog("Phone Link: %d notifications from the %@", notifications.count, source.rawValue)
        case "notif.posted":
            guard let nj = j["n"] as? JSON else { return }
            Notifier.shared.cacheIcon(nj)
            let n = PhoneNotification(nj)
            let old = notifications.first { $0.key == n.key }
            notifications.removeAll { $0.key == n.key }
            notifications.insert(n, at: 0)
            if old?.title != n.title || old?.text != n.text || old == nil { Notifier.shared.post(n, update: old != nil || n.silent) }
        case "notif.removed":
            if let k = j.str("key") {
                notifications.removeAll { $0.key == k }
                Notifier.shared.remove(key: k)
            }

        case "call.state":
            let st = j.str("state") ?? "idle"
            if st == "idle" { call = nil; Notifier.shared.removeCall() }
            else {
                let c = CallInfo(state: st, number: j.str("number"), name: j.str("name"))
                if st == "ringing", call?.state != "ringing" { Notifier.shared.postCall(c) }
                if st == "active" { Notifier.shared.removeCall() }
                call = c
            }

        case "screen.state":
            switch j.str("state") {
            case "streaming": screen = .streaming(width: j.int("width") ?? 0, height: j.int("height") ?? 0)
            case "waiting": screen = .waiting(j.str("msg") ?? "Waiting for the phone…")
            default: screen = .stopped(j.str("msg"))
            }
        case "screen.locked": phoneLocked = j.bool("locked")
        case "screen.audio":
            screenSound = j.bool("on")
            if !screenSound { ScreenAudioPlayer.shared.stop() }
            if let msg = j.str("msg"), UserDefaults.standard.bool(forKey: "screenSound") { banner = msg }

        case "clip": ClipboardSync.shared.received(j)
        case "url.open":
            if let s = j.str("url"), let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
        case "ring.state": ringing = j.bool("ringing")
        case "controls": QuickControls.shared.received(j, from: source)

        case "media":
            guard j.bool("active"), let title = j.str("title") else { media = nil; mediaArt = nil; return }
            media = MediaInfo(app: j.str("app") ?? "", title: title, artist: j.str("artist"), playing: j.bool("playing"),
                              position: j.i64("position") ?? 0, duration: j.i64("duration") ?? 0,
                              canNext: j.bool("canNext"), canPrevious: j.bool("canPrevious"), updated: Date())
            if j.keys.contains("art") { mediaArt = j.str("art").flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:)) }

        case "calls.log":
            callLog = (j["items"] as? [JSON] ?? []).map(CallLogEntry.init)
        case "call.missed":
            Notifier.shared.postMissedCall(number: j.str("number"), name: j.str("name"))
            send(["t": "calls.log", "limit": 100])

        case "photos.list":
            photos = (j["items"] as? [JSON] ?? []).map(PhonePhoto.init).filter { !deletingPhotos.contains($0.id) }
            photosError = j.str("error")
            NSLog("Phone Link: %d photos from the %@", photos.count, source.rawValue)
            let missing = photos.map(\.id).filter { photoThumbs[$0] == nil }
            if !missing.isEmpty { send(["t": "photos.thumb", "ids": missing]) }
        case "photos.thumb":
            // The app sends one message for each photo. A helper can also send a list.
            for item in (j["items"] as? [JSON]) ?? [j] {
                if let id = item.i64("id"), let d = item.str("data").flatMap({ Data(base64Encoded: $0) }), let img = NSImage(data: d) { photoThumbs[id] = img }
            }
        case "photos.changed":
            if !photos.isEmpty || photosError != nil { loadPhotos() }

        case "mms.part":
            if let id = j.i64("id"), let d = j.str("data").flatMap({ Data(base64Encoded: $0) }), let img = NSImage(data: d) { mmsImages[id] = img }

        case "adb.wifi":
            if j.bool("ok") { reconnectWireless(tries: 6) }
            else { NSLog("Phone Link: the phone did not turn on wireless debugging: %@", j.str("error") ?? "unknown") }

        case "error":
            // The controls show their errors in the menu, not in the main window.
            if let req = j.str("req"), QuickControls.owns(req) {
                QuickControls.shared.failed(req: req, msg: j.str("msg"), from: source)
                return
            }
            // A read request that failed in the app (for example, no permission) goes again to the shell helper.
            if let req = j.str("req"), PhoneRouter.canRetry(req, from: .app), shellCan(req) {
                queue.async { if let r = self.appRequests[req] { self.sendToShell(r) } }
                return
            }
            banner = j.str("msg")
        default:
            break
        }
    }

    // MARK: - Photos and messages (main thread)

    func ring() { ringing = true; send(["t": "ring"]) }
    func stopRing() { ringing = false; send(["t": "ring.stop"]) }
    func mediaCommand(_ action: String) {
        if var m = media, action == "toggle" { m.playing.toggle(); media = m }
        send(["t": "media.cmd", "action": action])
    }
    func openOnPhone(_ url: URL) { send(["t": "url.open", "url": url.absoluteString]) }
    func loadCallLog() { send(["t": "calls.log", "limit": 100]) }
    func loadPhotos() { send(["t": "photos.list", "limit": 90]) }

    /// Android 11 and later move deleted photos to the trash. Earlier versions delete them for good.
    var photosGoToTrash: Bool { Self.isDemo || shellCaps.contains("photos.trash") }

    func loadDemoPhotos() {
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPink, .systemTeal, .systemIndigo, .systemYellow, .systemRed, .systemMint]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        photos = (0..<18).map { i in PhonePhoto(["id": Int64(i + 1), "name": "IMG_20261121_\(1000 + i).jpg", "date": now - Int64(i) * 3_600_000, "size": 2_400_000, "width": 4000, "height": 3000]) }
        for (i, p) in photos.enumerated() {
            let c = colors[i % colors.count]
            photoThumbs[p.id] = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { r in
                NSGradient(starting: c.blended(withFraction: 0.35, of: .white) ?? c, ending: c)?.draw(in: r, angle: Double(30 + i * 20))
                return true
            }
        }
    }

    func deletePhotos(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        photos.removeAll { ids.contains($0.id) }
        if Self.isDemo { return }
        deletingPhotos.formUnion(ids)
        AdbAgent.shared.request(["t": "photos.delete", "ids": Array(ids)], timeout: 30 + Double(ids.count) * 5) { [weak self] r in
            guard let self else { return }
            self.deletingPhotos.subtract(ids)
            let gone = Set((r?["ids"] as? [NSNumber] ?? []).map(\.int64Value))
            let failed = ids.subtracting(gone).count
            if failed > 0 {
                self.banner = ids.count == 1 ? "The phone did not delete the photo." : "The phone did not delete \(failed) of \(ids.count) photos."
            }
            // Photos that the phone did not delete come back with the next list.
            self.loadPhotos()
        }
    }

    /// Android lets only the default SMS app write to the SMS and MMS providers, so this needs "smsDelete" from
    /// the app. RCS chats are not in these providers.
    var canDeleteMessages: Bool { route(.deleteMessages).isAvailable }

    /// ids nil deletes the whole conversation. The reply ("sms.delete") loads the list again.
    func deleteMessages(thread: Int64, ids: Set<Int64>?) {
        guard canDeleteMessages else { return }
        if let ids {
            messages[thread]?.removeAll { ids.contains($0.id) }
            if let i = threads.firstIndex(where: { $0.id == thread }), let last = messages[thread]?.last {
                threads[i].snippet = last.body
                threads[i].date = last.date
            }
        } else {
            threads.removeAll { $0.id == thread }
            messages[thread] = nil
        }
        if Self.isDemo { return }
        var j: JSON = ["t": "sms.delete", "thread": thread]
        if let ids { j["ids"] = Array(ids) }
        send(j)
    }
    func setDnd(_ on: Bool) { send(["t": "dnd", "on": on]) }

    func loadPart(_ id: Int64) {
        guard mmsImages[id] == nil, !requestedParts.contains(id) else { return }
        requestedParts.insert(id)
        send(["t": "mms.part", "id": id])
    }

    func sendMms(to addresses: [String], body: String, image: Data?, thread: Int64?) {
        let ref = UUID().uuidString
        if let thread { pendingSends[ref] = String(thread) } else { newMessageAddress = addresses.first }
        var j: JSON = ["t": "mms.send", "addresses": addresses, "body": body, "ref": ref]
        if let image { j["image"] = image.base64EncodedString() }
        send(j)
    }

    private func checkBattery() {
        guard let b = battery else { return }
        if charging || b > 25 { lowBatteryShown = false; return }
        if b <= 20, !lowBatteryShown, UserDefaults.standard.bool(forKey: "lowBatteryAlert") {
            lowBatteryShown = true
            Notifier.shared.postLowBattery(level: b, phone: phoneName)
        }
    }

    // MARK: - Demo

    func demoApply(phone: String, battery: Int, threads t: [JSON], messages m: [JSON], notifications n: [JSON], contacts c: [JSON]) {
        phoneName = phone
        self.battery = battery
        charging = false
        isPaired = true
        sessionState = .connected
        threads = t.map(SmsThread.init)
        messages = [1: m.map(SmsMessage.init)]
        notifications = n.map(PhoneNotification.init)
        contacts = c.map(Contact.init)
        perms = ["sms": true, "contacts": true, "phone": true, "notifications": true, "control": false]
        if ProcessInfo.processInfo.environment["PHONELINK_DEMO"] == "call" {
            // Demo only: PHONELINK_DEMO_CALL=active shows an active call with the audio on this Mac.
            let activeCall = ProcessInfo.processInfo.environment["PHONELINK_DEMO_CALL"] == "active"
            call = CallInfo(state: activeCall ? "active" : "ringing", number: "+1 415 555 0132", name: "Emma Carter")
            if activeCall { CallAudio.shared.demoActiveCall() }
        }
    }

    // MARK: - Actions (main thread)

    func loadMessages(thread: Int64) { send(["t": "sms.messages", "thread": thread, "limit": 300]) }

    func sendSms(to address: String, body: String, thread: Int64?) {
        let ref = UUID().uuidString
        if let thread { pendingSends[ref] = String(thread) } else { newMessageAddress = address }
        send(["t": "sms.send", "address": address, "body": body, "ref": ref])
    }

    func markRead(thread: Int64) {
        if let i = threads.firstIndex(where: { $0.id == thread }) { threads[i].unread = 0 }
    }

    func dial(_ number: String) { CallAudio.shared.macStartsCall(); send(["t": "call.dial", "number": number]) }
    func answer() { CallAudio.shared.macStartsCall(); send(["t": "call.answer"]) }
    func hangUp() { send(["t": "call.end"]) }

    /// Shows a call only when the app session did not report one (for example with no app on the phone).
    func helperCallState(active: Bool, internet: Bool = false) {
        if active, call == nil { call = CallInfo(state: "active", number: nil, name: nil, fromHelper: true, internet: internet) }
        else if !active, call?.fromHelper == true { call = nil }
    }

    func dismiss(_ key: String) {
        notifications.removeAll { $0.key == key }
        send(["t": "notif.dismiss", "key": key])
    }

    func runAction(_ key: String, index: Int, text: String? = nil) {
        guard sessionConnected else {
            banner = "Notification actions need Phone Link on the phone."
            return
        }
        var j: JSON = ["t": "notif.action", "key": key, "action": index]
        if let text { j["text"] = text }
        send(j)
    }

    /// Finds the linked phone and the phone used without the app in adb. Over adb the screen needs no prompt on the phone.
    func refreshAdb() {
        if Self.isDemo { return }
        guard PhoneRouter.usesDebugging else { stopDebugging(); return }
        let session = sessionConnected
        AdbManager.shared.refresh(model: session ? phoneModel : "") { linked, direct in
            // The mode can change while adb runs.
            guard PhoneRouter.usesDebugging else { self.stopDebugging(); return }
            if self.directSerial != direct { self.directSerial = direct; self.updateState() }
            var s: String?
            if self.sessionConnected {
                // The chosen phone is the session phone only if it is the same model.
                s = linked ?? (direct != nil && Self.sameModel(AdbManager.directPhoneModel, self.phoneModel) ? direct : nil)
            } else {
                s = direct
            }
            if self.adbSerial != s {
                self.adbSerial = s
                if s == nil, self.screenViaAdb, !self.sessionConnected { self.stopScreen() }
            }
            self.maybeGrantWirelessDebugging()
            // Wireless debugging stops when the phone changes or loses Wi-Fi. Ask again, at most once in 60 s.
            self.askWirelessDebugging()
        }
    }

    private static func sameModel(_ a: String, _ b: String) -> Bool {
        func n(_ s: String) -> String { String(s.uppercased().filter { $0.isLetter || $0.isNumber }) }
        return !a.isEmpty && n(a) == n(b)
    }

    // MARK: - Paths (main thread)

    private func updateState() {
        let s = sessionState == .connected
        if sessionConnected != s { sessionConnected = s }
        var merged = sessionState
        if directSerial != nil {
            switch sessionState {
            case .connected, .pairing: break
            default: merged = .connected
            }
        }
        if state != merged { state = merged }
        if !isPaired, phoneName.isEmpty, let n = AdbManager.directPhoneName { phoneName = n }
        updateNotificationWatch()
    }

    /// The shell helper and call audio stop when adbSerial is nil.
    private func stopDebugging() {
        if screenViaAdb { stopScreen() }
        if adbSerial != nil { adbSerial = nil }
        if directSerial != nil { directSerial = nil; updateState() }
    }

    /// Applies Settings > Connections at once: stops or restarts adb, drops data of features that are off, and
    /// loads the rest again from their current path.
    func featureChoicesChanged() {
        wifiAsked = false
        grantTried = false
        refreshAdb()
        updateNotificationWatch()
        if PhoneFeature.messages.isOff { threads = []; messages = [:]; mmsImages = [:]; requestedParts = [] }
        if PhoneFeature.contacts.isOff { contacts = [] }
        if PhoneFeature.callHistory.isOff { callLog = [] }
        if PhoneFeature.notifications.isOff { notifications = []; Notifier.shared.removeAll() }
        if PhoneFeature.photos.isOff { photos = []; photoThumbs = [:]; photosError = nil }
        if PhoneFeature.media.isOff { media = nil; mediaArt = nil }
        if PhoneFeature.battery.isOff { battery = nil }
        if PhoneFeature.findPhone.isOff { ringing = false }
        if PhoneFeature.screen.isOff, isStreaming { stopScreen() }
        QuickControls.shared.choicesChanged()
        SpotlightIndex.shared.update()
        guard state == .connected, !Self.isDemo else { return }
        // send() drops the requests of the features that are off.
        for j: JSON in [["t": "status"], ["t": "sms.threads"], ["t": "notif.list"], ["t": "contacts"], ["t": "calls.log", "limit": 100]] { send(j) }
    }

    func directPhoneChanged() {
        usesDirect = AdbManager.directPhoneID != nil
        if !usesDirect {
            directSerial = nil
            if !sessionConnected {
                adbSerial = nil
                clearPhoneData()
            }
            if !isPaired { phoneName = "" }
        } else if !isPaired {
            phoneName = AdbManager.directPhoneName ?? ""
        }
        updateState()
        refreshAdb()
    }

    private func shellCapsChanged(_ c: Set<String>) {
        let added = c.subtracting(shellCaps)
        shellCaps = c
        updateNotificationWatch()
        guard !added.isEmpty else { return }
        let loads: [JSON] = [["t": "status"], ["t": "sms.threads"], ["t": "notif.list"], ["t": "contacts"], ["t": "calls.log", "limit": 100]]
        for j in loads where added.contains(j.str("t")!) && path(forType: j.str("t")!) == .shell { send(j) }
        if added.contains("photos.list"), !photos.isEmpty || photosError != nil { loadPhotos() }
    }

    /// The shell helper watches notifications while the app cannot (no session, or no notification access).
    private func updateNotificationWatch() {
        let want = AdbAgent.shared.ready && shellCaps.contains("notif.list") && path(forType: "notif.list") == .shell
        guard want != watchingNotifications else { return }
        watchingNotifications = want
        AdbAgent.shared.request(["t": "notif.watch", "on": want])
    }

    func path(forType t: String) -> PhonePath? {
        let can = t == "clip" ? shellCaps.contains("clip") || shellCaps.contains("clip.set") : shellCaps.contains(t)
        return PhoneRouter.decide(t, session: sessionConnected, perms: perms, shellCan: AdbAgent.shared.ready && can)
    }

    /// When an app permission is off and no other path can do the feature, this gives .app, so that the app tells
    /// what is missing. Use route(_:) for the reason.
    func path(for f: PhoneFeature) -> PhonePath? {
        FeatureRouting.route(f, featureSnapshot, lastResort: true).path
    }

    var showsCalls: Bool { shows(.callHistory) || shows(.contacts) || shows(.makeCalls) }

    /// A paired phone, or a phone used without the phone app.
    var hasPhone: Bool {
        // Demo only: the setup screenshots show no phone, also on a Mac that has one.
        if Self.isDemo, ["setup", "pair"].contains(ProcessInfo.processInfo.environment["PHONELINK_DEMO"] ?? "") { return false }
        return isPaired || usesDirect
    }

    func shows(_ f: PhoneFeature) -> Bool {
        if f.isOff { return false }
        if path(for: f) != nil { return true }
        if sessionConnected { return false }
        if directSerial != nil || (!isPaired && usesDirect) {
            // The helper is starting: use the types it had last time.
            guard let t = f.requestType else { return f == .screen }
            let saved = Set(UserDefaults.standard.stringArray(forKey: "directCaps") ?? [])
            return !AdbAgent.shared.ready && saved.contains(t)
        }
        return f.spec.app != nil
    }

    // MARK: - Wireless debugging (main thread)

    /// Main thread. Each runs once at the next status reply.
    private var statusWaiters: [() -> Void] = []

    /// done runs at the reply, or after 5 s.
    func checkStatusAgain(done: @escaping () -> Void) {
        refreshAdb()
        guard sessionConnected else { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done); return }
        var called = false
        let once = { if !called { called = true; done() } }
        statusWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: once)
        queue.async { self.sendToApp(["t": "status"]) }
    }

    /// The user allowed one automatic change: grant the app WRITE_SECURE_SETTINGS over adb, so that it can turn on
    /// Wireless debugging. Once per session.
    private func maybeGrantWirelessDebugging() {
        guard sessionConnected, PhoneRouter.usesDebugging, adbWifiGranted == false, !grantTried, let serial = adbSerial else { return }
        grantTried = true
        grantWirelessDebugging(serial: serial)
    }

    private func grantWirelessDebugging(serial: String) {
        DispatchQueue.global(qos: .utility).async {
            let r = AdbManager.shell(serial, ["pm", "grant", AdbManager.package, "android.permission.WRITE_SECURE_SETTINGS"], timeout: 10)
            let ok = r?.status == 0 && r?.output.contains("Exception") == false
            NSLog("Phone Link: wireless debugging permission grant %@", ok ? "ok" : "failed")
            DispatchQueue.main.async {
                if self.sessionConnected { self.queue.async { self.sendToApp(["t": "status"]) } }
            }
        }
    }

    private func askWirelessDebugging() {
        guard sessionConnected, PhoneRouter.usesDebugging, adbSerial == nil, UserDefaults.standard.bool(forKey: "autoWirelessDebugging"),
              Date().timeIntervalSince(lastWifiAsk) > 60 else { return }
        wifiAsked = true
        lastWifiAsk = Date()
        queue.async { self.sendToApp(["t": "adb.wifi"]) }
    }

    private func reconnectWireless(tries: Int) {
        guard tries > 0, adbSerial == nil, PhoneRouter.usesDebugging else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 6 ? 2 : 3.5)) {
            guard self.adbSerial == nil, self.sessionConnected else { return }
            AdbManager.shared.connectWireless {
                self.refreshAdb()
                self.reconnectWireless(tries: tries - 1)
            }
        }
    }

    /// Android 11 and earlier cannot copy the sound through adb.
    private var adbSoundUnavailable = false

    /// adb is preferred: no permission prompt, and the Mac can unlock the phone. Use the app only when the user
    /// wants sound and adb cannot carry it.
    var usesAdbScreen: Bool { adbSerial != nil && !(adbSoundUnavailable && UserDefaults.standard.bool(forKey: "screenSound")) }

    func startScreen() {
        guard state == .connected else { screen = .stopped("The phone is not connected."); return }
        if PhoneFeature.screen.isOff { screen = .stopped(FeatureRouting.turnedOff); return }
        screen = .waiting("Starting screen sharing…")
        let q = ScreenQuality(rawValue: UserDefaults.standard.string(forKey: "screenQuality") ?? "") ?? .high
        if usesAdbScreen, let serial = adbSerial {
            screenViaAdb = true
            let a = AdbScreen.shared
            a.onJSON = { [weak self] j in
                guard let self, self.screenViaAdb else { return }
                // Text that the shell cannot type (for example emoji) goes through the accessibility service.
                if j.str("t") == "input.fallback" { if let t = j.str("text") { self.send(["t": "input.text", "text": t]) }; return }
                if j.str("t") == "screen.audio.unavailable" { self.adbSoundUnavailable = true; self.screenSound = false; return }
                self.handle(j)
            }
            a.onVideo = { [weak self] flags, data in self?.videoSink?(flags, data) }
            a.onEnd = { [weak self] msg, hadVideo in
                guard let self, self.screenViaAdb else { return }
                self.screenViaAdb = false
                self.phoneLocked = false
                // If adb did not work, use the phone app (it asks for permission on the phone).
                if hadVideo || !self.sessionConnected { self.screen = .stopped(msg ?? "Screen sharing did not start.") }
                else { self.send(["t": "screen.start", "maxSize": q.maxSize, "bitrate": q.bitrate, "fps": 60, "audio": UserDefaults.standard.bool(forKey: "screenSound")]) }
            }
            let sound = UserDefaults.standard.bool(forKey: "screenSound")
            screenSound = sound
            a.start(serial: serial, maxSize: q.maxSize, bitrate: q.bitrate, fps: 60, sound: sound,
                    extra: UserDefaults.standard.bool(forKey: "screenOff") ? ["off=1"] : [])
            return
        }
        send(["t": "screen.start", "maxSize": q.maxSize, "bitrate": q.bitrate, "fps": 60,
              "audio": UserDefaults.standard.bool(forKey: "screenSound")])
    }

    func setScreenSound(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "screenSound")
        if !on { ScreenAudioPlayer.shared.stop() }
        if screenViaAdb { screenSound = on && !adbSoundUnavailable; AdbScreen.shared.send(["t": "audio", "on": on]) }
        else { send(["t": "screen.audio", "on": on]) }
    }

    /// Only for screen sharing through adb.
    func setScreenOff(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "screenOff")
        if screenViaAdb { AdbScreen.shared.send(["t": "display.power", "on": !on]) }
    }

    func requestKeyFrame() {
        if screenViaAdb { AdbScreen.shared.send(["t": "keyframe"]) } else { send(["t": "screen.keyframe"]) }
    }

    /// Over USB the adb screen server injects input, so it also works on the lock screen. Without screen sharing
    /// and without the app, the phone buttons use key events through adb.
    func input(_ j: JSON) {
        if screenViaAdb { AdbScreen.shared.send(j); return }
        if !sessionConnected, adbSerial != nil {
            var cmd: [String]?
            switch (j.str("t"), j.str("action") ?? j.str("key")) {
            case ("input.wake", _): cmd = ["input", "keyevent", "224"]
            case ("input.global", "lock"): cmd = ["input", "keyevent", "223"]
            case ("input.global", "notifications"): cmd = ["cmd", "statusbar", "expand-notifications"]
            case ("input.global", "home"), ("input.key", "home"): cmd = ["input", "keyevent", "3"]
            case ("input.global", "back"), ("input.key", "back"): cmd = ["input", "keyevent", "4"]
            case ("input.global", "recents"), ("input.key", "recents"): cmd = ["input", "keyevent", "187"]
            default: break
            }
            if let cmd { AdbAgent.shared.shell(cmd, timeout: 10) }
            return
        }
        send(j)
    }

    func dismissAll() {
        let keys = notifications.map(\.key)
        notifications.removeAll()
        keys.forEach { send(["t": "notif.dismiss", "key": $0]) }
    }

    static func sameNumber(_ a: String, _ b: String) -> Bool {
        let da = a.filter(\.isNumber), db = b.filter(\.isNumber)
        guard da.count >= 6, db.count >= 6 else { return a == b }
        return da.suffix(9) == db.suffix(9)
    }

    var unreadCount: Int { threads.reduce(0) { $0 + $1.unread } }

    func stopScreen() {
        screen = .stopped(nil)
        phoneLocked = false
        screenSound = false
        ScreenAudioPlayer.shared.stop()
        if screenViaAdb {
            screenViaAdb = false
            AdbScreen.shared.stop()
        } else {
            send(["t": "screen.stop"])
        }
    }
}
