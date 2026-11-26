import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var hotspot = PhoneHotspot.shared
    @State private var photo: Int64?

    var body: some View {
        Group {
            if link.hasPhone, !isPairingNow {
                split
            } else {
                SetupView()
                    .frame(minWidth: 620, minHeight: 560)
            }
        }
        .modifier(WindowOpenerCapture())
        .background(LaunchHider { dismissWindow(id: "main") })
        .sheet(isPresented: $router.appPicker) { AppPickerSheet() }
        .sheet(isPresented: $hotspot.sheetShown) { HotspotSheet() }
        .alert("Phone Link", isPresented: Binding(get: { link.banner != nil }, set: { if !$0 { link.banner = nil } })) {
            Button("OK") { link.banner = nil }
        } message: {
            Text(link.banner ?? "")
        }
    }

    private var isPairingNow: Bool {
        if case .pairing = link.state { return true }
        return false
    }

    @ViewBuilder private var split: some View {
        if router.section == .notifications {
            // Notifications have no list column: one column of cards fills the window.
            NavigationSplitView {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            } detail: {
                NotificationFeed()
            }
            .frame(minWidth: 860, minHeight: 520)
        } else {
            threeColumns
        }
    }

    private var threeColumns: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            switch router.section {
            case .messages: ThreadList().navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            case .phone: PhoneList().navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            case .photos: PhotosGrid(selection: $photo).navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
            case .notifications: EmptyView()
            case .files: FileLocationsList().navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            case .screen: ScreenControls().navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            case .apps: AppsList().navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            case .device: DeviceSummary().navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            }
        } detail: {
            switch router.section {
            case .messages: MessagesDetail()
            case .phone:
                if let call = link.call { ActiveCallView(call: call) } else { KeypadView() }
            case .photos: PhotoDetail(id: photo)
            case .notifications: NotificationFeed()
            case .files: FilesDetail()
            case .screen: ScreenPane()
            case .apps: AppDetail()
            case .device: DeviceDetail()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @ObservedObject private var pins = PinnedApps.shared

    var body: some View {
        List(selection: Binding(get: { router.section }, set: { if let s = $0 { router.section = s } })) {
            ForEach(visible, id: \.self) { s in
                Label(s.title, systemImage: s.symbol).badge(badge(s)).tag(s)
            }
            if link.shows(.appWindows) {
                PinnedAppsSection()
            }
        }
        // A drop on any part of the sidebar pins the app at the end of the list.
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard link.shows(.appWindows) else { return false }
            return pins.accept(providers)
        }
        .onChange(of: visible) { _, v in keepSelection(in: v) }
        .onAppear { keepSelection(in: visible) }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { DeviceFooter() }
    }
}

extension Sidebar {
    /// The sections that the phone can serve now.
    var visible: [SidebarSection] {
        var v: [SidebarSection] = []
        if link.shows(.messages) { v.append(.messages) }
        if link.showsCalls { v.append(.phone) }
        if link.shows(.notifications) { v.append(.notifications) }
        if link.shows(.photos) { v.append(.photos) }
        if link.shows(.files) { v.append(.files) }
        if link.shows(.screen) { v.append(.screen) }
        if link.shows(.apps) { v.append(.apps) }
        if link.shows(.deviceInfo) { v.append(.device) }
        return v
    }

    func keepSelection(in sections: [SidebarSection]) {
        if !sections.contains(router.section), let first = sections.first { router.section = first }
    }

    /// Zero shows no badge.
    func badge(_ s: SidebarSection) -> Int {
        switch s {
        case .messages: link.unreadCount
        case .notifications: link.notifications.count
        default: 0
        }
    }
}

extension SidebarSection {
    var title: String {
        switch self {
        case .messages: "Messages"
        case .phone: "Calls"
        case .notifications: "Notifications"
        case .photos: "Photos"
        case .files: "Files"
        case .screen: "Phone Screen"
        case .apps: "Apps"
        case .device: "Device"
        }
    }

    var symbol: String {
        switch self {
        case .messages: "message"
        case .phone: "phone"
        case .notifications: "bell"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .screen: "rectangle.portrait.on.rectangle.portrait"
        case .apps: "square.grid.2x2"
        case .device: "info.circle"
        }
    }
}

private struct DeviceFooter: View {
    @EnvironmentObject private var link: PhoneLink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "smartphone")
                    .font(.title3)
                    .foregroundStyle(link.state == .connected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.phoneName.isEmpty ? "Phone" : link.phoneName).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(link.state == .connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(link.state == .connected ? "Connected" : link.state.summary).lineLimit(1)
                        if link.state == .connected, let title = link.linkTitle, title != "Wi-Fi" {
                            Image(systemName: link.linkSymbol).imageScale(.small)
                                .help("Connected through \(title)")
                                .accessibilityLabel("through \(title)")
                        }
                        if link.state == .connected, let b = link.battery {
                            Text("· \(b)%").monospacedDigit()
                            if link.charging {
                                Image(systemName: "bolt.fill").imageScale(.small).accessibilityLabel("Charging")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

struct NotConnectedView: View {
    @EnvironmentObject private var link: PhoneLink
    var body: some View {
        if link.localNetworkBlocked {
            ContentUnavailableView {
                Label("Allow Local Network Access", systemImage: "network.slash")
            } description: {
                Text("Phone Link needs it to find and connect to your phone on Wi-Fi.")
            } actions: {
                Button("Open Privacy Settings…") { PhoneLink.openLocalNetworkSettings() }
                    .buttonStyle(.borderedProminent)
                if AdbManager.path != nil, link.isPaired { Button("Connect with USB") { link.connectUSB() } }
            }
        } else {
            notConnected
        }
    }

    private var notConnected: some View {
        ContentUnavailableView {
            Label("Phone Not Connected", systemImage: "smartphone")
        } description: {
            if !link.isPaired, link.usesDirect {
                Text("Connect the phone to this Mac with a USB cable, or turn on Wireless debugging on the phone.")
            } else {
                Text(link.state == .idle ? "Make sure the phone is on the same Wi-Fi network and Phone Link is open on it." : link.state.summary)
            }
        } actions: {
            // One button for each line: the list column can be narrow.
            if link.isPaired {
                VStack(spacing: 8) {
                    Button("Use \(PhoneHotspot.term)…") { PhoneHotspot.shared.showSheet() }
                        .buttonStyle(.borderedProminent)
                        .help("Connect when your Mac and phone are not on the same Wi-Fi network")
                    if AdbManager.path != nil { Button("Connect with USB") { link.connectUSB() } }
                }
            }
        }
    }
}

/// At launch a paired Mac starts as a menu bar helper only. SwiftUI opens the main window at launch, so make the
/// window transparent before it shows, then close it. Later the window opens normally.
private struct LaunchHider: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> NSView { HiderView(close: close) }
    func updateNSView(_ v: NSView, context: Context) {}

    final class HiderView: NSView {
        static var atLaunch = true
        let close: () -> Void

        init(close: @escaping () -> Void) {
            self.close = close
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewWillMove(toWindow w: NSWindow?) {
            super.viewWillMove(toWindow: w)
            guard let w, Self.atLaunch, !LaunchState.done else { return }
            Self.atLaunch = false
            guard PhoneLink.shared.hasPhone, !PhoneLink.isDemo else { return }
            w.alphaValue = 0
            DispatchQueue.main.async {
                self.close()
                // The window object can show again later. Give it back its normal alpha after it closes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { w.alphaValue = 1 }
            }
        }
    }
}

enum LaunchState { static var done = false }
