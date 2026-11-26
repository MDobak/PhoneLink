import AppKit
import CoreSpotlight
import SwiftUI

@main
struct PhoneLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var link = PhoneLink.shared
    @StateObject private var router = Router.shared
    @StateObject private var agent = AdbAgent.shared
    var body: some Scene {
        Window("Phone Link", id: "main") {
            MainView()
                .environmentObject(link)
                .environmentObject(router)
        }
        .defaultSize(width: 980, height: 640)
        .commands { PhoneLinkCommands(link: link, router: router, agent: agent) }

        Window("Phone Screen", id: "screen") {
            ScreenWindowView()
                .environmentObject(link)
                .environmentObject(router)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 780)

        WindowGroup("App", id: "app", for: String.self) { $pkg in
            AppWindowView(pkg: pkg ?? "")
                .environmentObject(link)
                .environmentObject(router)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 760)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(link)
                .environmentObject(router)
        } label: {
            // The only view at launch. It gives the Router the action that opens windows.
            MenuBarIcon(link: link)
                .modifier(WindowOpenerCapture())
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(link)
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var link: PhoneLink
    @ObservedObject private var desktop = RemoteDesktopHost.shared
    @ObservedObject private var terminal = RemoteTerminal.shared
    @ObservedObject private var agents = AgentServer.shared

    var body: some View {
        Group {
            if link.call?.state == "ringing" {
                Image(systemName: "phone.fill").symbolEffect(.pulse)
                    .accessibilityLabel("Phone Link, incoming call")
            } else if link.state == .connected, agents.active {
                Image(nsImage: Self.agent)
                    .accessibilityLabel("Phone Link, connected, an agent uses your phone")
            } else if link.state == .connected {
                Image(nsImage: Self.connected)
                    .accessibilityLabel(desktop.active ? "Phone Link, connected, your phone is controlling this Mac"
                                        : terminal.openTabCount > 0 ? "Phone Link, connected, terminal open on your phone"
                                        : "Phone Link, connected")
            } else {
                Image(nsImage: Self.dimmed)
                    .accessibilityLabel("Phone Link, not connected")
            }
        }
    }

    /// The Link mark from the app icon.
    private static let connected = linkMark()
    /// The same mark at reduced alpha, so it looks dimmed in light and dark mode.
    private static let dimmed = linkMark(alpha: 0.4)
    /// The mark with a dot at the top right: an agent uses the phone.
    private static let agent = linkMark(badge: true)

    /// Draws the Link mark from the app icon as a one-color template image on an 18 x 18 pt canvas.
    /// The phone link is on top at the upper crossing; the Mac link is on top at the lower crossing.
    private static func linkMark(alpha: CGFloat = 1, badge: Bool = false) -> NSImage {
        let w: CGFloat = 1.5, gap: CGFloat = 1, radius: CGFloat = 2.5
        let phone = CGRect(x: 1, y: 2, width: 7.5, height: 14), mac = CGRect(x: 4, y: 5.5, width: 13, height: 7)
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Fills one link and cuts the gap where the other link is on top.
            func link(_ r: CGRect, cut: CGRect) {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: w, dy: w), cornerWidth: radius - w, cornerHeight: radius - w, transform: nil))
                ctx.fillPath(using: .evenOdd)
                ctx.setBlendMode(.destinationOut); ctx.fill(cut); ctx.setBlendMode(.normal)
                ctx.endTransparencyLayer()
            }
            ctx.setAlpha(alpha)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            link(mac, cut: CGRect(x: phone.maxX - w - gap, y: mac.minY - 1, width: w + 2 * gap, height: w + 2))
            link(phone, cut: CGRect(x: phone.maxX - w - 1, y: mac.maxY - w - gap, width: w + 2, height: w + 2 * gap))
            if badge {
                let dot = CGRect(x: 12, y: 0, width: 6, height: 6)
                ctx.setBlendMode(.destinationOut)
                ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: dot)
            }
            ctx.endTransparencyLayer()
            return true
        }
        img.isTemplate = true
        return img
    }
}

private struct PhoneLinkCommands: Commands {
    @ObservedObject var link: PhoneLink
    @ObservedObject var router: Router
    @ObservedObject var agent: AdbAgent
    @ObservedObject private var drive = PhoneDrive.shared
    @ObservedObject private var apps = AppsModel.shared
    @AppStorage("screenOff") private var screenOff = false

    private var connected: Bool { link.state == .connected }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Hide features that need the phone app when it is missing.
            if link.shows(.sendMessages) {
                Button("New Message") { router.show(.messages, compose: true) }
                    .keyboardShortcut("n")
            }
            if link.shows(.makeCalls) {
                Button("New Call") { router.show(.phone) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            Divider()
            if link.shows(.files) {
                Button("Send Files to Phone…") { FileHub.chooseAndSend(to: nil) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!connected)
            }
            if link.shows(.openLinks) {
                Button("Send Link to Phone…") { LinkSender.prompt() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!connected)
            }
            if link.shows(.installApps) {
                Button("Install App on Phone…") {
                    router.show(.apps)
                    apps.chooseAndInstall { if let e = $0 { link.banner = e } }
                }
                .disabled(apps.installing != nil)
            }
            Divider()
            if link.shows(.files) {
                Button("Show Phone in Finder") { drive.showInFinder() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!link.sessionConnected)
            }
            if drive.isMounted {
                Button("Eject Phone Drive") { drive.eject() }
                    .keyboardShortcut("e")
            }
        }

        // Section switches go in the View menu, above "Show Sidebar", as in Mail and Music.
        CommandGroup(before: .sidebar) {
            if link.shows(.messages) { Button("Messages") { router.show(.messages) }.keyboardShortcut("1") }
            if link.showsCalls { Button("Calls") { router.show(.phone) }.keyboardShortcut("2") }
            if link.shows(.notifications) { Button("Notifications") { router.show(.notifications) }.keyboardShortcut("3") }
            if link.shows(.photos) { Button("Photos") { router.show(.photos) }.keyboardShortcut("4") }
            if link.shows(.files) { Button("Files") { router.show(.files) }.keyboardShortcut("5") }
            if link.shows(.screen) { Button("Phone Screen") { router.mirror() }.keyboardShortcut("6") }
            if link.shows(.apps) { Button("Apps") { router.show(.apps) }.keyboardShortcut("7") }
            if link.shows(.deviceInfo) { Button("Device") { router.show(.device) }.keyboardShortcut("8") }
            Divider()
        }

        CommandMenu("Phone") {
            Section {
                if link.shows(.screen) {
                    Button("Open Phone Screen in New Window") { router.detachScreen() }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        .disabled(!connected)
                }
                if link.shows(.appWindows) {
                    Button("Open App in Window…") { router.chooseApp() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("Open Phone Desktop") { router.openDesktop() }
                    Toggle("Keep Phone Screen Off While Sharing",
                           isOn: Binding(get: { screenOff }, set: { link.setScreenOff($0) }))
                }
            }
            Divider()
            Section {
                if link.shows(.findPhone) {
                    Button(link.ringing ? "Stop Ringing" : "Find Phone") { link.ringing ? link.stopRing() : link.ring() }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                }
                Button("Show Notification Shade") { link.input(["t": "input.global", "action": "notifications"]) }
                Button("Wake Phone") { link.input(["t": "input.wake"]) }
                Button("Lock Phone") { link.input(["t": "input.global", "action": "lock"]) }
                    .keyboardShortcut("l", modifiers: [.command, .control])
            }
            .disabled(!connected)
            if link.path(for: .hotspot) != nil, let on = agent.hotspotOn {
                Divider()
                Button(on ? "Stop Sharing Phone Internet" : "Share Phone Internet") { HotspotControl.share(!on) }
                    .disabled(agent.sharingStarts)
                if on, agent.hotspotName != nil { Button("Connect This Mac to Hotspot") { HotspotControl.join() } }
            }
            if link.isPaired, !connected {
                Divider()
                Button("Connect Through \(PhoneHotspot.term)…") { PhoneHotspot.shared.showSheet() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["mirrorNotifications": true, "notificationSounds": true,
                                                  "screenQuality": ScreenQuality.high.rawValue,
                                                  "receiveFiles": true, "shareFolders": false, "shareWritable": false,
                                                  "shareClipboard": true, "focusSync": false, "lowBatteryAlert": true, "autoWirelessDebugging": true,
                                                  "screenSound": true, CallAudio.settingKey: true, "spotlight": true, "adbAutoConnect": true, "driveAutoMount": true, DockShims.settingKey: true])
        _ = DockShims.shared
        Notifier.shared.setup()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        ClipboardSync.shared.start()
        FocusSync.shared.start()
        PhoneLink.shared.start()
        AdbAgent.shared.start()
        CallAudio.shared.start()
        if !PhoneLink.isDemo { AgentServer.shared.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { LaunchState.done = true }
        _ = AppsModel.shared
        _ = PhoneDrive.shared
        CallPanelController.shared.start()
        if PhoneLink.isDemo, !["setup", "pair"].contains(ProcessInfo.processInfo.environment["PHONELINK_DEMO"] ?? "") { DemoWindows.open() }
    }

    func applicationWillFinishLaunching(_ n: Notification) {
        // Handle phonelink:// links here, so that SwiftUI does not open an empty window for them.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let u = URL(string: s) else { return }
        // At launch the windows are not ready yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + (Router.shared.openWindow == nil ? 0.8 : 0)) { URLRouter.handle(u) }
    }

    func application(_ application: NSApplication, continue activity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        SpotlightIndex.open(id)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Router.shared.show(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockShims.shared.dockMenu() }

    func applicationWillTerminate(_ n: Notification) {
        DockShims.shared.stopAll()
    }
}

enum SidebarSection: String, Hashable, CaseIterable {
    case messages, phone, notifications, photos, files, screen, apps, device
}

/// Opens windows and selects content from places that have no SwiftUI environment
/// (notification clicks, the call panel, menu commands).
final class Router: ObservableObject {
    static let shared = Router()
    @Published var section: SidebarSection = .messages
    @Published var thread: Int64?
    @Published var notification: String?
    @Published var composing = false
    @Published var composeTo: String?
    @Published var composeBody: String?
    @Published var keypadNumber: String?
    @Published var phoneRecents = false
    @Published var screenDetached = false
    @Published var appPicker = false
    /// Set by a view that has the dismissWindow action.
    var closeScreenWindow: (() -> Void)?
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    /// `tab` is a tag from SettingsView.tabs. An unknown tag keeps the current tab.
    func showSettings(_ tab: String? = nil) {
        if let tab, SettingsView.tabs.contains(tab) { UserDefaults.standard.set(tab, forKey: "settingsTab") }
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
    }

    func show(_ s: SidebarSection?, thread: Int64? = nil, notification: String? = nil, compose: Bool = false, recents: Bool = false) {
        if let s { section = s }
        if recents { phoneRecents = true }
        if let thread { self.thread = thread; composing = false }
        if let notification { self.notification = notification }
        if compose { composing = true; self.thread = nil }
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "main")
    }

    func compose(to number: String) {
        composeTo = number
        show(.messages, compose: true)
    }

    func mirror() {
        if screenDetached { detachScreen() } else { show(.screen) }
    }

    /// Needs USB or Wireless debugging.
    func openApp(_ pkg: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "app", value: pkg)
    }

    /// Needs USB or Wireless debugging.
    func chooseApp() {
        show(nil)
        appPicker = true
    }

    /// A full phone desktop on its own virtual display. Works while the phone is locked.
    func openDesktop() { openApp(AppStream.desktopID) }

    func detachScreen() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "screen")
    }
}

struct WindowOpenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onAppear { Router.shared.openWindow = openWindow; Router.shared.openSettings = openSettings }
    }
}
