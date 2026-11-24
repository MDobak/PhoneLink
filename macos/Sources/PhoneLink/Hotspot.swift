import AppKit
import Foundation
import SwiftUI

/// Lets the Mac use the phone hotspot when the Mac and the phone are not on the same Wi-Fi network.
///
/// While USB or Wireless debugging works (for example at home), the shell helper reports the hotspot name and
/// password (AdbAgent.hotspot), and this class saves them. Away from home, the Mac joins that network when the user
/// asks. PhoneLink then finds the phone at the gateway address of the network (PhoneLink.connectToGateway).
/// Main thread only.
final class PhoneHotspot: ObservableObject {
    static let shared = PhoneHotspot()

    struct Network: Codable, Equatable {
        var ssid: String
        var password: String?
    }

    enum Phase: Equatable {
        case idle
        /// The Mac tries to join the saved network until the phone turns on its hotspot.
        case joining
        /// The Mac is on the hotspot. Phone Link connects to the phone.
        case joined
        case failed(String)
    }

    enum JoinResult: Equatable { case joined, notFound, failed(String) }

    /// The hotspot of the paired phone. Nil until the shell helper reports it.
    @Published private(set) var network: Network?
    @Published private(set) var phase: Phase = .idle
    /// Low Data Mode is on for the Wi-Fi network of the Mac. Set by PhoneLink.
    @Published var lowDataMode = false
    /// Shows HotspotSheet in the main window.
    @Published var sheetShown = false

    private var task: Task<Void, Never>?
    /// The time for the user to turn on the hotspot on the phone.
    private static let joinTimeout: TimeInterval = 120
    /// The time for the session to start after the Mac joins the hotspot.
    private static let sessionTimeout: TimeInterval = 30

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Link", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("hotspot.json")
    }

    private init() {
        if PhoneLink.isDemo {
            network = Network(ssid: "Galaxy S24 Ultra", password: nil)
            return
        }
        if let d = try? Data(contentsOf: Self.storeURL) { network = try? JSONDecoder().decode(Network.self, from: d) }
    }

    var isBusy: Bool { phase == .joining || phase == .joined }

    /// The name that the phone shows for the hotspot. Samsung calls it Mobile Hotspot.
    static var term: String {
        let model = PhoneLink.shared.phoneModel.isEmpty ? UserDefaults.standard.string(forKey: "lastPhoneModel") ?? "" : PhoneLink.shared.phoneModel
        return model.uppercased().hasPrefix("SM") || PhoneLink.isDemo ? "Mobile Hotspot" : "Hotspot"
    }

    // MARK: Saved network

    func remember(ssid: String, password: String?) {
        guard !ssid.isEmpty, !PhoneLink.isDemo else { return }
        let n = Network(ssid: ssid, password: password?.isEmpty == true ? nil : password)
        guard n != network else { return }
        network = n
        save()
    }

    func forget() {
        cancel()
        network = nil
        save()
    }

    private func save() {
        let url = Self.storeURL
        if let n = network, let d = try? JSONEncoder().encode(n) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Connect

    /// Joins the saved hotspot, and tries again while the user turns it on. With no saved hotspot, shows the steps.
    func connect() {
        guard let n = network else { showSheet(); return }
        guard !PhoneLink.shared.viaHotspot else { phase = .idle; return }
        task?.cancel()
        phase = .joining
        if PhoneLink.isDemo { return }
        task = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.joinTimeout)
            while !Task.isCancelled {
                let r = await Self.join(ssid: n.ssid, password: n.password)
                guard let self, !Task.isCancelled else { return }
                switch r {
                case .joined:
                    self.phase = .joined
                    self.waitForSession()
                    return
                case .failed(let why):
                    self.phase = .failed(why)
                    return
                case .notFound:
                    if Date() > deadline {
                        self.phase = .failed("Phone Link cannot find “\(n.ssid)”. Make sure \(Self.term) is on, then try again.")
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase != .idle { phase = .idle }
    }

    func showSheet() {
        Router.shared.show(nil)
        sheetShown = true
    }

    /// Called by PhoneLink when a session through the hotspot starts.
    func sessionStarted() {
        task?.cancel()
        task = nil
        if phase != .idle { phase = .idle }
    }

    private func waitForSession() {
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.sessionTimeout))
            guard let self, !Task.isCancelled, self.phase == .joined, PhoneLink.shared.state != .connected else { return }
            self.phase = .failed("Your Mac is on the hotspot, but the phone does not answer. Make sure Phone Link is on the phone.")
        }
    }

    /// Demo only. See PhoneLink.loadDemoHotspot.
    func loadDemo(_ mode: String) {
        switch mode {
        case "joined": phase = .joined
        case "failed": phase = .failed("Phone Link cannot find “Galaxy S24 Ultra”. Make sure \(Self.term) is on, then try again.")
        case "manual": network = nil
        case "connected": phase = .idle
        default: phase = .joining
        }
    }

    static func openWiFiSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { NSWorkspace.shared.open(u) }
    }

    // MARK: networksetup

    /// Joins a Wi-Fi network. Turns on Wi-Fi first if it is off. Does not change the network if it is not found.
    static func join(ssid: String, password: String?) async -> JoinResult {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let device = wifiDevice()
                if run(["-getairportpower", device]).hasSuffix("Off") { _ = run(["-setairportpower", device, "on"]) }
                var args = ["-setairportnetwork", device, ssid]
                if let password, !password.isEmpty { args.append(password) }
                let out = run(args)
                if out.isEmpty { done.resume(returning: .joined) }
                else if out.contains("Could not find network") { done.resume(returning: .notFound) }
                else {
                    NSLog("Phone Link: networksetup: %@", out)
                    done.resume(returning: .failed("Your Mac cannot join “\(ssid)”. If the hotspot password changed, connect the phone with USB or Wireless debugging one time, or choose the network in Wi-Fi settings."))
                }
            }
        }
    }

    /// Removes a network from the known networks of the Mac. It can fail without administrator rights.
    static func forgetNetwork(ssid: String) {
        DispatchQueue.global(qos: .utility).async {
            let out = run(["-removepreferredwirelessnetwork", wifiDevice(), ssid])
            if !out.lowercased().contains("removed") { NSLog("Phone Link: networksetup: %@", out) }
        }
    }

    /// For example "en0".
    private static func wifiDevice() -> String {
        let ports = run(["-listallhardwareports"]).components(separatedBy: "\n")
        if let i = ports.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }), i + 1 < ports.count,
           let r = ports[i + 1].range(of: "Device: ") {
            return String(ports[i + 1][r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return "en0"
    }

    /// Returns the output without the last line break.
    private static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "Error: networksetup did not start." }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sheet

/// The steps to connect through the phone hotspot. Opens from the main window, the menu bar and Settings.
struct HotspotSheet: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var hotspot = PhoneHotspot.shared
    @Environment(\.dismiss) private var dismiss

    private var connected: Bool { link.state == .connected }
    private var phoneName: String { link.phoneName.isEmpty ? "your phone" : link.phoneName }
    private var term: String { PhoneHotspot.term }
    private var failure: String? { if case .failed(let m) = hotspot.phase { return m }; return nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(alignment: .leading, spacing: 14) {
                HotspotStep(number: 1, state: turnOnState,
                            title: "Turn on \(term) on \(phoneName)",
                            detail: "Swipe down from the top of the phone screen, then tap \(term).")
                joinStep
                HotspotStep(number: 3, state: connectState,
                            title: "Phone Link connects",
                            detail: connected ? "Connected through \(term)." : "This happens automatically.")
            }
            if let failure {
                Label { Text(failure).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                .font(.callout)
            }
            note
            HStack {
                if failure != nil, hotspot.network != nil {
                    Button("Try Again") { hotspot.connect() }.keyboardShortcut(.defaultAction)
                }
                Spacer()
                if connected {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { hotspot.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            // After a failure, the user reads the message and chooses Try Again.
            if !connected, hotspot.network != nil, hotspot.phase == .idle { hotspot.connect() }
        }
        .task(id: link.viaHotspot) {
            // Show the finished steps for a moment, then close.
            guard link.viaHotspot else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { dismiss() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "personalhotspot")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Through \(term)").font(.title2.weight(.semibold))
                Text("Use Phone Link when your Mac and phone are not on the same Wi-Fi network.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var joinStep: some View {
        if let n = hotspot.network {
            HotspotStep(number: 2, state: joinState,
                        title: "Connect this Mac to “\(n.ssid)”",
                        detail: joinState == .done ? "Your Mac is on the hotspot." : "Phone Link joins the network when \(term) is on.")
        } else {
            HotspotStep(number: 2, state: connected ? .done : .waiting,
                        title: "Connect this Mac to the hotspot",
                        detail: "Choose the network of your phone in the Wi-Fi menu. Your Mac remembers it for the next time.") {
                Button("Open Wi-Fi Settings…") { PhoneHotspot.openWiFiSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var onHotspot: Bool { link.viaHotspot || hotspot.phase == .joined }

    /// The step of the user. It shows as the current step while the Mac looks for the network.
    private var turnOnState: HotspotStepState {
        onHotspot || connected ? .done : .waiting
    }

    private var joinState: HotspotStepState {
        if onHotspot || connected { return .done }
        return hotspot.phase == .joining ? .active : .pending
    }

    private var connectState: HotspotStepState {
        if connected { return .done }
        return hotspot.phase == .joined ? .active : .pending
    }

    private var note: some View {
        Label {
            Text(noteText).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var noteText: String {
        let base = "On the hotspot, your Mac uses the internet connection of the phone."
        // Samsung phones can share a Wi-Fi connection through the hotspot (Wi-Fi sharing).
        return PhoneHotspot.term == "Mobile Hotspot"
            ? base + " To use Wi-Fi instead of mobile data, turn on Wi-Fi sharing in the Mobile Hotspot settings of the phone."
            : base
    }
}

/// One numbered step. The indicator shows the number, a progress spinner or a check mark.
enum HotspotStepState { case pending, waiting, active, done }

struct HotspotStep<Accessory: View>: View {
    let number: Int
    let state: HotspotStepState
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            indicator
                .frame(width: 22, height: 22)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory().padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateText)
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .active:
            ProgressView().controlSize(.small)
        case .pending, .waiting:
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(state == .waiting ? Color.accentColor : .secondary)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(state == .waiting ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5))
        }
    }

    private var stateText: String {
        switch state {
        case .done: "Done"
        case .active: "In progress"
        case .pending, .waiting: "Step \(number)"
        }
    }
}

extension HotspotStep where Accessory == EmptyView {
    init(number: Int, state: HotspotStepState, title: String, detail: String) {
        self.init(number: number, state: state, title: title, detail: detail) { EmptyView() }
    }
}
