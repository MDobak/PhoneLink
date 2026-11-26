import SwiftUI

/// The menu bar window. Its layout follows the system menu bar windows (Wi-Fi, Bluetooth, Sound).
struct MenuBarView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    /// Not read here. Observed because showsControls depends on the hotspot state.
    @ObservedObject private var agent = AdbAgent.shared
    @ObservedObject private var pins = PinnedApps.shared
    @ObservedObject private var desktop = RemoteDesktopHost.shared
    @ObservedObject private var terminal = RemoteTerminal.shared
    @ObservedObject private var controls = QuickControls.shared
    @ObservedObject private var controlPins = ControlPins.shared
    @ObservedObject private var agents = AgentServer.shared
    @ObservedObject private var agentSettings = AgentSettings.shared
    @AppStorage("menuShowsSound") private var showsSoundSetting = true
    /// Demo only: media to show when the phone sends none.
    var previewMedia: MediaInfo? = nil

    /// An agent is connected and can use some tools.
    private var agentsCanAct: Bool { agentSettings.enabled && !agentSettings.groups.isEmpty && !agents.clients.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { router.show(nil) } label: { header.menuRow(vertical: 5) }
                .buttonStyle(.plain)
                .help("Open Phone Link")
                .accessibilityHint("Opens Phone Link")
                .padding(.horizontal, 5)
                .padding(.top, 5)
                .padding(.bottom, 2)

            if let call = link.call {
                CallRow(call: call)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .tile()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            if desktop.active || terminal.openTabCount > 0 || agentsCanAct {
                VStack(alignment: .leading, spacing: 0) {
                    if agentsCanAct {
                        RemoteAccessRow(title: agents.active ? "\(agents.lastClient ?? "An Agent") Is Using Your Phone" : "Agents Can Use Your Phone",
                                        symbol: "sparkles", action: "Stop") { agents.stopAll() }
                            .help("Turns off all agent tools. To turn them on again, open Settings > Agents.")
                    }
                    if desktop.active {
                        RemoteAccessRow(title: "Your Phone Is Controlling This Mac", symbol: "rectangle.inset.filled.and.person.filled",
                                        action: "Stop") { desktop.stopFromMac() }
                    }
                    if terminal.openTabCount > 0 {
                        RemoteAccessRow(title: "Terminal Open on Your Phone", symbol: "apple.terminal.fill",
                                        action: "Close All") { terminal.closeAll() }
                    }
                }
                .padding(.horizontal, 5)
            }

            if connected, let m = link.media ?? previewMedia {
                NowPlaying(media: m, art: link.mediaArt)
                    .padding(10)
                    .tile()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            if showsControls {
                separator
                MenuControlsSection()
            }

            if showsSound {
                separator
                MenuSoundSection()
                    .padding(.bottom, 2)
            }

            if hasItemRows {
                separator
                VStack(alignment: .leading, spacing: 0) { itemRows }
                    .padding(.horizontal, 5)
            }

            if showsPinnedApps {
                separator
                PinnedAppsStrip(pkgs: pins.pkgs, limit: link.call == nil ? 6 : 7)
            }

            separator
            VStack(alignment: .leading, spacing: 0) {
                textRow("Phone Link Settings…") { router.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                textRow("Quit Phone Link") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 5)
        }
        // Call controls need more width, so the window is wider during a call.
        .frame(width: link.call == nil ? 300 : 360)
        .modifier(WindowOpenerCapture())
        // Ask the phone for its controls only while this window shows.
        .background(WindowVisibilityReader { QuickControls.shared.menuVisible($0) })
    }

    private var connected: Bool { link.state == .connected }
    /// Pinned apps open in app windows. The demo shows them without a debugging link.
    private var showsPinnedApps: Bool {
        connected && (link.shows(.appWindows) || PhoneLink.isDemo) && !pins.pkgs.isEmpty
    }
    private var hasItemRows: Bool {
        if !link.hasPhone { return true }
        guard connected else { return link.isPaired }
        return !link.threads.isEmpty || !link.notifications.isEmpty || link.shows(.screen) || link.shows(.files)
    }
    /// The Controls grid shows when a side reports controls, or when a pinned control that needs no report can be used.
    private var showsControls: Bool {
        guard connected, !controlPins.ids.isEmpty else { return false }
        if PhoneLink.isDemo || controls.hasReportedControls { return true }
        return controlPins.controls.contains { $0.need == .feature && controls.unavailableReason($0) == nil }
    }
    private var showsSound: Bool { connected && showsSoundSetting && controls.hasVolume }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.phoneName.isEmpty ? "Phone Link" : link.phoneName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !connected {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    // All connections in use: the app link, then the shell helper.
                    Label(connectionText, systemImage: link.linkSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if connected {
                BatteryLabel(level: link.battery, charging: link.charging)
                    .font(.system(size: 12))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionText: String {
        let app = link.viaHotspot && !link.usesPrivateWifi ? hotspotStatus : link.linkTitle
        return [app, link.shellTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private var hotspotStatus: String {
        switch link.phoneUplink {
        case "cellular": "\(PhoneHotspot.term) · Uses Mobile Data"
        case "wifi": "\(PhoneHotspot.term) · Wi-Fi Sharing"
        default: PhoneHotspot.term
        }
    }

    private var statusText: String {
        guard link.hasPhone else { return "No phone set up" }
        return link.state.summary
    }

    private var separator: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }

    @ViewBuilder private var itemRows: some View {
        if !link.hasPhone {
            IconRow(title: "Set Up Phone Link…", symbol: "link") { router.show(nil) }
        } else if !connected {
            HotspotMenuRow()
        } else {
            if !link.threads.isEmpty {
                IconRow(title: "Messages", symbol: "message.fill",
                        value: link.unreadCount > 0 ? "\(link.unreadCount) Unread" : nil,
                        help: "Show the messages") { router.show(.messages) }
            }
            if !link.notifications.isEmpty {
                IconRow(title: "Notifications", symbol: "bell.fill", value: "\(link.notifications.count)",
                        help: "Show the notifications") { router.show(.notifications) }
            }
            if link.shows(.screen) {
                IconRow(title: "Phone Screen", symbol: "rectangle.portrait.on.rectangle.portrait.fill",
                        help: "Show the phone screen") { router.mirror() }
            }
            if link.shows(.files) {
                IconRow(title: "Send File…", symbol: "arrow.up.doc.fill", help: "Send files to the phone") {
                    FileHub.chooseAndSend(to: nil)
                }
            }
        }
    }

    private func textRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).menuRow(vertical: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct RemoteAccessRow: View {
    let title: String
    let symbol: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .controlSize(.small)
        }
        .menuRow(vertical: 3)
        .accessibilityElement(children: .contain)
    }
}

private struct IconRow: View {
    let title: String
    let symbol: String
    var value: String? = nil
    var help: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    /// In light mode a darker gray keeps the white symbol readable.
    private var fill: Color { Color(nsColor: scheme == .dark ? .tertiaryLabelColor : .systemGray) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(fill))
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                }
            }
            .menuRow(vertical: 3)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// The row does not wrap. When it is full, the last item is "More Apps".
private struct PinnedAppsStrip: View {
    let pkgs: [String]
    /// Matches the window width.
    let limit: Int

    var body: some View {
        let overflow = pkgs.count > limit
        let shown = overflow ? Array(pkgs.prefix(limit - 1)) : pkgs
        VStack(alignment: .leading, spacing: 2) {
            Text("Apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 4) {
                ForEach(shown, id: \.self) { PinnedAppTile(pkg: $0) }
                if overflow { MoreAppsTile(count: pkgs.count - shown.count) }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned Apps")
    }
}

private struct PinnedAppTile: View {
    let pkg: String
    @ObservedObject private var pins = PinnedApps.shared

    var body: some View {
        let ok = pins.isAvailable(pkg)
        let name = pins.label(pkg)
        Button { Router.shared.openApp(pkg) } label: {
            Group {
                if PhoneLink.isDemo {
                    DemoAppIcon(pkg: pkg, size: 34)
                } else {
                    // Rebuild the icon after the app check so that it loads.
                    PhoneAppIcon(pkg: pkg, size: 34).id(pins.available == nil)
                }
            }
            .iconTile()
        }
        .buttonStyle(.plain)
        .disabled(!ok)
        .opacity(ok ? 1 : 0.4)
        .help(ok ? name : "\(name) is not on the phone.")
        .accessibilityLabel(name)
        .accessibilityHint(ok ? "Opens the app in a window" : "The app is not on the phone")
    }
}

private struct MoreAppsTile: View {
    let count: Int
    @EnvironmentObject private var router: Router

    var body: some View {
        Button { router.show(.apps) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 34 * 0.225, style: .continuous).fill(.quaternary))
                .iconTile()
        }
        .buttonStyle(.plain)
        .help("\(count) More Apps")
        .accessibilityLabel("\(count) more apps")
        .accessibilityHint("Shows Apps in the main window")
    }
}

private struct IconTileStyle: ViewModifier {
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

private struct MenuRowStyle: ViewModifier {
    let vertical: CGFloat
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, vertical)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

private extension View {
    func menuRow(vertical: CGFloat) -> some View { modifier(MenuRowStyle(vertical: vertical)) }
    func iconTile() -> some View { modifier(IconTileStyle()) }

    func tile() -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
    }
}

private struct NowPlaying: View {
    @EnvironmentObject private var link: PhoneLink
    let media: MediaInfo
    let art: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let art {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(media.artist ?? media.app).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                control("backward.fill", "Previous", enabled: media.canPrevious) { link.mediaCommand("previous") }
                control(media.playing ? "pause.fill" : "play.fill", media.playing ? "Pause" : "Play", enabled: true, big: true) {
                    link.mediaCommand("toggle")
                }
                control("forward.fill", "Next", enabled: media.canNext) { link.mediaCommand("next") }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing on phone")
    }

    private func control(_ symbol: String, _ label: String, enabled: Bool, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 17 : 12))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct CallRow: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var audio = CallAudio.shared
    let call: CallInfo

    var body: some View {
        HStack(spacing: 12) {
            Monogram(name: call.name ?? "", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.title).font(.headline).lineLimit(1)
                Group {
                    if call.state == "ringing" {
                        Text("Incoming Call")
                    } else if let started = link.callStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { ctx in
                            Text("On Call · ") + Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(started)).rounded()),
                                                      format: .time(pattern: .minuteSecond)).monospacedDigit()
                        }
                    } else {
                        Text("On Call")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                audioStatus
                    .font(.caption)
                    .foregroundStyle(audio.error != nil && call.state != "ringing" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .help(audio.error ?? "")
            }
            Spacer(minLength: 8)
            if call.state == "ringing" {
                CallButton(kind: .decline) { link.hangUp() }
                CallButton(kind: .accept) { link.answer() }
            } else {
                if audio.offered && audio.callActive {
                    if audio.route == .mac {
                        AudioDevicesMenu()
                        CallControlButton(symbol: audio.micMuted ? "mic.slash.fill" : "mic.fill", on: audio.micMuted,
                                          label: audio.micMuted ? "Unmute" : "Mute") { audio.toggleMute() }
                    }
                    CallControlButton(symbol: audio.route == .mac ? "speaker.wave.2.fill" : "iphone", on: audio.route == .mac,
                                      label: audio.route == .mac ? "Use Phone for Audio" : "Use This Mac for Audio") {
                        audio.setRoute(audio.route == .mac ? .phone : .mac)
                    }
                }
                if !call.internet, link.path(forType: "call.end") != nil {
                    CallButton(kind: .decline, label: "End Call") { link.hangUp() }
                }
            }
        }
    }

    @ViewBuilder private var audioStatus: some View {
        if call.state != "ringing", let e = audio.error {
            Label(e, systemImage: "exclamationmark.triangle")
        } else if audio.audioOnMac {
            Label("Audio on This Mac", systemImage: "laptopcomputer")
        } else if audio.offered && audio.callActive && audio.route == .mac {
            Label("Connecting Audio…", systemImage: "laptopcomputer")
        } else {
            Label("Audio on Phone", systemImage: "iphone")
        }
    }
}

private struct CallControlButton: View {
    let symbol: String
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(on ? Color.primary.opacity(0.85) : Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Connects through the phone hotspot from the menu bar. Shows the progress in place, so no window opens when the
/// hotspot is saved. With no saved hotspot, it opens the steps in the main window.
private struct HotspotMenuRow: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var hotspot = PhoneHotspot.shared

    private var term: String { PhoneHotspot.term }

    var body: some View {
        switch hotspot.phase {
        case .idle:
            IconRow(title: "Connect Through \(term)" + (hotspot.network == nil ? "…" : ""), symbol: "personalhotspot",
                    help: "Use the phone hotspot when your Mac and phone are not on the same Wi-Fi network") { hotspot.connect() }
        case .joining:
            StatusMenuRow(title: "Waiting for Hotspot…", detail: "Turn on \(term) on your phone.",
                          action: "Cancel") { hotspot.cancel() }
        case .joined:
            StatusMenuRow(title: "Connecting…", detail: "Your Mac is on the hotspot.", action: "Cancel") { hotspot.cancel() }
        case .failed(let why):
            StatusMenuRow(title: "Cannot Connect", detail: why, failed: true, action: "Try Again") { hotspot.connect() }
        }
    }
}

private struct StatusMenuRow: View {
    let title: String
    let detail: String
    var failed = false
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if failed {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(nsColor: .systemOrange)))
                } else {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: perform)
                .controlSize(.small)
        }
        .menuRow(vertical: 3)
        .accessibilityElement(children: .contain)
    }
}
