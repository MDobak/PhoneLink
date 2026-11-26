import AppKit
import SwiftUI

// MARK: - Stream

/// Streams one phone app into its own Mac window. The phone runs the app on a virtual display.
/// Each window has its own server port, socket name and renderer.
final class AppStream: ObservableObject {
    enum Phase: Equatable {
        case idle
        case opening
        case streaming
        case failed(String)
    }

    /// The window id of the phone desktop (not a package name).
    static let desktopID = "@desktop"

    let pkg: String
    let renderer = H264Renderer()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var displayId: Int?
    private var notificationKey: String?

    private let slot: Int
    private let screen: AdbScreen
    private var viewSize: CGSize = .zero
    private var sentSize: CGSize = .zero
    private var pendingResize: DispatchWorkItem?
    /// Mac points for each Android dp. A smaller scale shows more of the app in the same window. Main thread only.
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue, videoSize != .zero else { return }
            scheduleResize(after: 0)
        }
    }
    /// Network thread only.
    private var frameSeen = false
    private let lock = NSLock()

    /// Slots in use. Each slot gives one port and one socket name.
    private static var usedSlots = Set<Int>()
    /// Main thread only.
    private static let all = NSHashTable<AppStream>.weakObjects()
    /// The Mac window and the app name, for agents (windows_read). Main thread only.
    weak var window: NSWindow?
    var label: String?

    /// The windows that show or open an app. Main thread only.
    static var open: [AppStream] { all.allObjects.filter { $0.phase != .idle } }

    /// Pending notifications for windows not open yet, by package. Main thread only.
    private static var pending: [String: (key: String, time: Date)] = [:]

    /// Opens a phone notification in its app window. Main thread only; call before the window opens.
    /// Opening the notification intent needs the encrypted session. Without it, only the app shows.
    static func openNotification(pkg: String, key: String) {
        if let s = all.allObjects.first(where: { $0.pkg == pkg && $0.phase != .idle }) {
            s.notificationKey = key
            if case .failed = s.phase { s.restart() } else { s.sendNotification() }
        } else {
            pending[pkg] = (key, Date())
        }
    }

    private func sendNotification() {
        guard let key = notificationKey, let id = displayId else { return }
        notificationKey = nil
        let link = PhoneLink.shared
        guard link.state == .connected else { return }
        link.send(["t": "notif.open", "key": key, "display": id])
    }

    init(pkg: String) {
        self.pkg = pkg
        var n = 0
        while Self.usedSlots.contains(n) { n += 1 }
        Self.usedSlots.insert(n)
        slot = n
        screen = AdbScreen(port: UInt16(47830 + n), socket: "phonelink-app-\(n)")
        renderer.onNeedKeyFrame = { [weak self] in self?.screen.send(["t": "keyframe"]) }
        screen.onVideo = { [weak self] flags, data in
            guard let self else { return }
            self.renderer.handle(flags: flags, data: data)
            self.lock.lock()
            let first = !self.frameSeen
            self.frameSeen = true
            self.lock.unlock()
            if first { DispatchQueue.main.async { if self.phase == .opening { self.phase = .streaming } } }
        }
        screen.onJSON = { [weak self] j in self?.handle(j) }
        Self.all.add(self)
        screen.onEnd = { [weak self] msg, hadVideo in
            guard let self, self.phase != .idle else { return }
            let desk = self.isDesktop
            self.phase = .failed(msg ?? (hadVideo ? (desk ? "The phone desktop closed." : "The app stopped.")
                                                  : (desk ? "The phone desktop did not open." : "The app did not open.")))
        }
    }

    deinit {
        screen.stop()
        let n = slot
        DispatchQueue.main.async { AppStream.usedSlots.remove(n) }
    }

    /// The phone must be linked.
    func start() {
        guard let serial = PhoneLink.shared.adbSerial else {
            phase = .idle
            return
        }
        lock.lock()
        frameSeen = false
        lock.unlock()
        sentSize = .zero
        videoSize = .zero
        displayId = nil
        // Use a notification from a click only a short time ago. An old one is for a window that did not open.
        if let p = Self.pending.removeValue(forKey: pkg), Date().timeIntervalSince(p.time) < 30 { notificationKey = p.key }
        phase = .opening
        let q = ScreenQuality(rawValue: UserDefaults.standard.string(forKey: "screenQuality") ?? "") ?? .high
        screen.start(serial: serial, maxSize: q.maxSize, bitrate: q.bitrate, fps: 60, sound: false, extra: ["app=\(pkg)"])
    }

    /// The phone closes the virtual display.
    func stop() {
        pendingResize?.cancel()
        pendingResize = nil
        if phase == .opening || phase == .streaming { screen.send(["t": "stop"]) }
        phase = .idle
        // Let the stop message go out before the connection closes.
        let s = screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self == nil || self?.phase == .idle { s.stop() }
        }
    }

    func restart() {
        pendingResize?.cancel()
        pendingResize = nil
        screen.stop()
        phase = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.start()
        }
    }

    func send(_ j: JSON) {
        guard phase == .streaming || phase == .opening else { return }
        screen.send(j)
    }

    func back() { send(["t": "input.global", "action": "back"]) }
    func home() { send(["t": "input.global", "action": "home"]) }
    func launch(_ pkg: String) { send(["t": "app.launch", "pkg": pkg]) }

    var isDesktop: Bool { pkg == Self.desktopID }

    /// Sends the view size to the phone after 0.3 s without changes.
    func viewResized(to size: CGSize) {
        viewSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard videoSize != .zero else { return } // The first screen.state sends the size.
        scheduleResize(after: 0.3)
    }

    private func scheduleResize(after delay: TimeInterval) {
        pendingResize?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sendResize() }
        pendingResize = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// At scale 1, one Mac point is one Android dp.
    private func sendResize() {
        let dp = CGSize(width: (viewSize.width / scale).rounded(), height: (viewSize.height / scale).rounded())
        guard phase == .opening || phase == .streaming, dp.width >= 1, dp.height >= 1, dp != sentSize else { return }
        sentSize = dp
        screen.send(["t": "resize", "w": Int(dp.width), "h": Int(dp.height)])
    }

    private func handle(_ j: JSON) {
        if j.str("t") == "display.id" {
            displayId = (j["id"] as? NSNumber)?.intValue
            sendNotification()
            return
        }
        guard j.str("t") == "screen.state", j.str("state") == "streaming" else { return }
        let w = (j["width"] as? NSNumber)?.doubleValue ?? 0
        let h = (j["height"] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return }
        let first = videoSize == .zero
        videoSize = CGSize(width: w, height: h)
        // First frame: make the display fit the window.
        if first { scheduleResize(after: 0) }
    }
}

// MARK: - Views

struct AppWindowView: View {
    let pkg: String
    @EnvironmentObject private var link: PhoneLink
    @StateObject private var stream: AppStream
    @ObservedObject private var agent = AdbAgent.shared
    @State private var label: String?
    @State private var icon: NSImage?
    @State private var visible = false
    @State private var showLauncher = true
    @State private var window: NSWindow?
    @State private var scale: CGFloat

    init(pkg: String) {
        self.pkg = pkg
        _stream = StateObject(wrappedValue: AppStream(pkg: pkg))
        let saved = UserDefaults.standard.double(forKey: Self.scaleKey(pkg))
        _scale = State(initialValue: saved > 0 ? CGFloat(saved) : 1)
    }

    /// Each app keeps its own scale.
    private static func scaleKey(_ pkg: String) -> String { "appWindowScale." + pkg }

    private var isDesktop: Bool { pkg == AppStream.desktopID }
    private var name: String { isDesktop ? "Phone Desktop" : (label ?? pkg) }

    var body: some View {
        content
            .frame(minWidth: 240, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            .navigationTitle(name)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { stream.back() } label: { Label("Back", systemImage: "chevron.backward") }
                        .help("Back")
                        .disabled(stream.phase != .streaming)
                }
                if isDesktop {
                    ToolbarItem(placement: .navigation) {
                        Button { stream.home(); showLauncher = true } label: { Label("Home", systemImage: "circle") }
                            .help("Home")
                            .keyboardShortcut("h", modifiers: [.command, .shift])
                            .disabled(stream.phase != .streaming)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $showLauncher) { Label("Apps", systemImage: "square.grid.2x2") }
                            .help(showLauncher ? "Hide Apps" : "Show Apps")
                            .disabled(stream.phase != .streaming)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ScaleMenu(scale: scale, help: "The size of the app content. At a smaller scale, more of the app fits in the window.") { scale = $0 }
                        .disabled(stream.phase != .streaming)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { stream.restart() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .help("Reload")
                        .keyboardShortcut("r")
                        .disabled(!link.route(.appWindows).isAvailable || pkg.isEmpty)
                }
            }
            .background(WindowAccessor { w in
                window = w
                stream.window = w
                updateDock()
            })
            .onAppear {
                visible = true
                stream.scale = scale
                lookUpApp()
                if link.adbSerial != nil, !pkg.isEmpty { stream.start() }
            }
            .onDisappear {
                visible = false
                stream.stop()
                DockShims.shared.closed(pkg: pkg)
            }
            .onChange(of: label) { _, l in stream.label = l; updateDock() }
            .onChange(of: scale) { _, s in
                stream.scale = s
                if s == 1 { UserDefaults.standard.removeObject(forKey: Self.scaleKey(pkg)) }
                else { UserDefaults.standard.set(Double(s), forKey: Self.scaleKey(pkg)) }
            }
            .onChange(of: icon) { _, _ in updateDock() }
            .onChange(of: link.adbSerial) { _, serial in
                guard visible, !pkg.isEmpty else { return }
                if serial == nil { stream.stop() } else if stream.phase == .idle { stream.start() }
            }
            .onChange(of: agent.ready) { _, ready in if ready { lookUpApp() } }
    }

    @ViewBuilder private var content: some View {
        if let reason = link.route(.appWindows).reason {
            ContentUnavailableView {
                Label("Phone Not Linked", systemImage: "iphone.slash")
            } description: {
                Text(reason)
            } actions: {
                Button("Try Again") { if link.adbSerial != nil { stream.start() } }
                Button("Open Settings") { Router.shared.showSettings("debugging") }
            }
        } else if case .failed(let msg) = stream.phase {
            ContentUnavailableView {
                Label("Can’t Open \(name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(msg)
            } actions: {
                Button("Try Again") { stream.restart() }
            }
        } else {
            GeometryReader { geo in
                AppScreenRepresentable(stream: stream)
                    .onAppear { stream.viewResized(to: geo.size) }
                    .onChange(of: geo.size) { _, size in stream.viewResized(to: size) }
            }
            .background(Color.black)
            .overlay {
                if isDesktop, showLauncher, stream.phase == .streaming {
                    DesktopLauncher { pkg in
                        stream.launch(pkg)
                        showLauncher = false
                    } close: { showLauncher = false }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showLauncher)
            .overlay {
                if stream.phase != .streaming {
                    VStack(spacing: 12) {
                        if isDesktop {
                            Image(systemName: "rectangle.on.rectangle").font(.system(size: 36)).foregroundStyle(.white.opacity(0.8))
                                .accessibilityHidden(true)
                        } else if let icon {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 48, height: 48)
                                .accessibilityHidden(true)
                        }
                        ProgressView().controlSize(.regular).tint(.white)
                        Text("Opening \(name)…").font(.callout).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }
        }
    }

    private func updateDock() {
        guard let window, !pkg.isEmpty else { return }
        DockShims.shared.update(pkg: pkg, window: window, label: label, icon: icon)
    }

    private func lookUpApp() {
        guard !pkg.isEmpty, !isDesktop, agent.ready else { return }
        if icon == nil {
            if let i = agent.cachedIcon(pkg) { icon = i } else { agent.icon(pkg) { icon = $0 } }
        }
        guard label == nil else { return }
        agent.apps(system: true) { apps in
            if let app = apps?.first(where: { $0.pkg == pkg }) { label = app.label }
        }
    }
}

/// Mac-side app grid drawn over the phone desktop video.
private struct DesktopLauncher: View {
    let open: (String) -> Void
    let close: () -> Void
    @State private var apps: [PhoneApp] = []
    @State private var loaded = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var agent = AdbAgent.shared

    private var shown: [PhoneApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.label.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Apps", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = shown.first { open(first.pkg) } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(12)

            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(apps.isEmpty ? "No Apps" : "No Results")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 8)], spacing: 14) {
                        ForEach(shown) { app in
                            Button { open(app.pkg) } label: {
                                VStack(spacing: 6) {
                                    PhoneAppIcon(pkg: app.pkg, size: 48)
                                    Text(app.label)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(app.label)
                            .onDrag { NSItemProvider(object: app.pkg as NSString) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(.regularMaterial)
        .onExitCommand(perform: close)
        .onAppear {
            searchFocused = true
            load()
        }
        .onChange(of: agent.ready) { _, ready in if ready { load() } }
    }

    private func load() {
        guard agent.ready else { return }
        agent.apps(system: false) { list in
            // With no list, show "No Apps", not an endless progress indicator.
            apps = (list ?? []).filter(\.launchable)
            loaded = true
        }
    }
}

private struct AppScreenRepresentable: NSViewRepresentable {
    let stream: AppStream

    func makeNSView(context: Context) -> PhoneScreenNSView {
        // This renderer is not the phone screen renderer, so the view does not count PIN keys.
        let v = PhoneScreenNSView(renderer: stream.renderer)
        v.send = { [weak stream] in stream?.send($0) }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: PhoneScreenNSView, context: Context) {}
}
