import AppKit
import Foundation

/// The private Wi-Fi network of the phone: the local-only hotspot of Android (PrivateWifi.kt on the phone). It does
/// not share the internet connection of the phone, so the Mac cannot use mobile data through it.
///
/// Rules:
/// 1. Phone Link never turns on the hotspot that shares mobile data. The user turns it on (PhoneHotspot).
/// 2. The private network starts only while the session uses Bluetooth, because the Mac asks the phone through it.
/// 3. It starts automatically only when the setting is on and the Mac is not on a Wi-Fi network. Then the Mac loses
///    no network. Else the user starts it, and Phone Link first tells the user that the Mac leaves its network.
/// 4. It stops after 5 minutes with no screen sharing, file transfer, Remote Desktop or terminal. Then macOS joins a
///    known network again. After an automatic stop, it does not start automatically again until the next connection.
///
/// Main thread only.
final class PrivateWifi: ObservableObject {
    static let shared = PrivateWifi()
    /// "Create a private Wi-Fi network when needed". Off by default.
    static let settingKey = "privateWifi"
    static var autoOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }
    private static let idleLimit: TimeInterval = 5 * 60

    enum Phase: Equatable {
        case idle
        /// The Mac asked the phone to start the network.
        case starting
        /// The Mac joins the network.
        case joining
        /// The Mac is on the network.
        case active
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ssid: String?
    private var password: String?
    /// The automatic start was used for this Bluetooth connection.
    private var autoUsed = false
    private var lastBusy = Date()
    private var offlineTicks = 0
    private var task: Task<Void, Never>?

    var isActive: Bool { phase == .active }
    var isBusy: Bool { phase == .starting || phase == .joining }

    /// The user can start the network now.
    var canStart: Bool {
        let link = PhoneLink.shared
        return link.state == .connected && link.linkKind == .bluetooth && !isBusy && !isActive
    }

    /// The user asks for the network. When the Mac is on a Wi-Fi network, asks the user first.
    func userStart() {
        guard canStart else { return }
        if PhoneLink.shared.macOnWifi {
            let a = NSAlert()
            a.messageText = "Use a Private Wi-Fi Network?"
            a.informativeText = "Your Mac leaves its Wi-Fi network and joins a private network of the phone. Your Mac has no internet connection while it uses this network. Phone Link stops the network after 5 minutes without screen sharing or file transfers. Then your Mac joins a known network again."
            a.addButton(withTitle: "Use Private Wi-Fi")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        start()
    }

    private func start() {
        task?.cancel()
        phase = .starting
        lastBusy = Date()
        PhoneLink.shared.sendAppOnly(["t": "lohs.start"])
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.phase == .starting else { return }
            self.phase = .failed("The phone did not start the private Wi-Fi network.")
        }
    }

    /// The reply to "lohs.start".
    func phoneReplied(_ j: JSON) {
        guard phase == .starting else { return }
        task?.cancel()
        if let e = j.str("error") { phase = .failed(e); return }
        guard let s = j.str("ssid"), !s.isEmpty else { phase = .failed("The phone did not give the network name."); return }
        ssid = s
        password = j.str("pass")
        join()
    }

    /// The network in "links": nil when it is off.
    func phoneReported(_ n: JSON?) {
        if n == nil, phase == .active || phase == .joining { finish() }
    }

    private func join() {
        guard let s = ssid else { return }
        phase = .joining
        let pass = password
        task = Task { @MainActor [weak self] in
            // The new network can take some seconds to show.
            let deadline = Date().addingTimeInterval(30)
            while !Task.isCancelled {
                let r = await PhoneHotspot.join(ssid: s, password: pass)
                guard let self, !Task.isCancelled else { return }
                switch r {
                case .joined:
                    // PhoneLink sees the network change and connects to the phone at the gateway address.
                    self.phase = .active
                    self.lastBusy = Date()
                    return
                case .failed(let why):
                    self.phase = .failed(why)
                    self.stopOnPhone()
                    return
                case .notFound:
                    if Date() > deadline {
                        self.phase = .failed("Your Mac cannot find the private Wi-Fi network of the phone.")
                        self.stopOnPhone()
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops the network on the phone. The session then changes back to Bluetooth or to a known network.
    func stop() {
        guard phase != .idle else { return }
        stopOnPhone()
        finish()
    }

    private func stopOnPhone() {
        PhoneLink.shared.sendAppOnly(["t": "lohs.stop"])
    }

    private func finish() {
        task?.cancel()
        task = nil
        // Do not keep the network in the list of known networks: the phone makes a new one each time.
        if let s = ssid { PhoneHotspot.forgetNetwork(ssid: s) }
        ssid = nil
        password = nil
        if phase != .idle { phase = .idle }
    }

    /// From PhoneLink when a session starts.
    func sessionStarted(kind: LinkKind?) {
        if kind != .bluetooth {
            // A new connection that is not Bluetooth (and not this network) allows the automatic start again.
            if !isActive && !isBusy { autoUsed = false }
            return
        }
        if case .failed = phase { phase = .idle }
        // Rule 3: automatic only when the Mac loses no network.
        guard Self.autoOn, !autoUsed, phase == .idle, !PhoneLink.shared.macOnWifi else { return }
        autoUsed = true
        // Let the session send its first requests.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.canStart, !PhoneLink.shared.macOnWifi else { return }
            self.start()
        }
    }

    /// Every 10 seconds from PhoneLink. busy: screen sharing, file transfers, Remote Desktop or a terminal.
    func tick(busy: Bool) {
        guard isActive else { offlineTicks = 0; return }
        if busy { lastBusy = Date() }
        // Rule 4.
        if Date().timeIntervalSince(lastBusy) > Self.idleLimit { stop(); return }
        // About 100 seconds with no session: the phone stopped the network.
        offlineTicks = PhoneLink.shared.state == .connected ? 0 : offlineTicks + 1
        if offlineTicks > 9 { finish() }
    }

    /// The setting changed.
    func settingChanged(_ on: Bool) {
        autoUsed = false
        if on { sessionStarted(kind: PhoneLink.shared.linkKind) }
    }
}
