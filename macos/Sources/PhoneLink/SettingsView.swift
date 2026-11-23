import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    /// Demo only: PHONELINK_DEMO_SETTINGS_HEIGHT=n makes the window n points high, so that a capture shows all rows of a tab.
    private static let demoHeight: CGFloat? = PhoneLink.isDemo
        ? ProcessInfo.processInfo.environment["PHONELINK_DEMO_SETTINGS_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } : nil

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            DeviceSettings().tabItem { Label("Phone", systemImage: "smartphone") }.tag("phone")
            ControlsSettings().tabItem { Label("Controls", systemImage: "switch.2") }.tag("controls")
            FileSettings().tabItem { Label("Files", systemImage: "folder") }.tag("files")
            ScreenSettings().tabItem { Label("Screen", systemImage: "rectangle.portrait.on.rectangle.portrait") }.tag("screen")
            RemoteAccessSettings().tabItem { Label("Remote Access", systemImage: "macbook.and.iphone") }.tag("remote")
            // The tag stays "debugging", so that saved selections and phonelink://settings/debugging still work.
            DebugSettings().tabItem { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }.tag("debugging")
        }
        .frame(width: 500)
        .frame(height: Self.demoHeight)
        .onAppear { PhoneLink.shared.checkStatusAgain {} }
    }
}

extension View {
    /// The grouped form aligns footer text trailing unless the footer sets an alignment.
    func settingsFooter() -> some View {
        foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralSettings: View {
    @AppStorage("mirrorNotifications") private var mirror = true
    @AppStorage("notificationSounds") private var sounds = true
    @AppStorage("shareClipboard") private var clipboard = true
    @AppStorage("focusSync") private var focus = false
    @AppStorage("lowBatteryAlert") private var lowBattery = true
    @AppStorage("spotlight") private var spotlight = true
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var canReadFocus = FocusSync.shared.canRead
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        Form {
            Toggle("Open Phone Link at login", isOn: $login)
                .onChange(of: login) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { login = SMAppService.mainApp.status == .enabled }
                }
            Section {
                Toggle("Show phone notifications on this Mac", isOn: $mirror)
                Toggle("Play a sound for new notifications", isOn: $sounds).disabled(!mirror)
                if mirror, !notifier.allowed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Notifications are off for Phone Link.")
                        Spacer()
                        Button("Open System Settings…") { notifier.openSystemSettings() }
                    }
                }
            } footer: {
                Text("Notifications that you dismiss on this Mac are also dismissed on the phone.")
                    .settingsFooter()
            }
            Section {
                Toggle("Share the clipboard with the phone", isOn: $clipboard)
                Toggle("Tell me when the phone battery is low", isOn: $lowBattery)
                Toggle("Show contacts and messages in Spotlight", isOn: $spotlight)
                    .onChange(of: spotlight) { SpotlightIndex.shared.update() }
            } footer: {
                Text("Passwords that you copy from a password manager are not shared.")
                    .settingsFooter()
            }
            Section {
                Toggle("Turn on Do Not Disturb on the phone during a Focus", isOn: $focus)
                    .onChange(of: focus) { _, on in
                        canReadFocus = FocusSync.shared.canRead
                        if on { FocusSync.shared.resend() } else if PhoneLink.shared.state == .connected { PhoneLink.shared.setDnd(false) }
                    }
                if focus && !canReadFocus {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Phone Link needs Full Disk Access to read the Focus.")
                        Spacer()
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                    .font(.callout)
                }
            } footer: {
                Text("Phone Link on the phone asks for Do Not Disturb access.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            canReadFocus = FocusSync.shared.canRead
        }
    }
}

private struct DeviceSettings: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var adb = AdbManager.shared
    @ObservedObject private var features = PhoneFeatures.shared
    @State private var confirmUnpair = false
    @State private var confirmStopDirect = false
    @State private var showDirectPicker = false
    @State private var checking = false
    @AppStorage(CallAudio.settingKey) private var callAudioOnMac = true
    private var appOnly: Bool { !PhoneRouter.usesDebugging }
    private var canTurnOn: Bool { !appOnly && adb.linkedSerial != nil && link.sessionConnected }
    private var phoneName: String { link.phoneName.isEmpty ? "the phone" : link.phoneName }

    var body: some View {
        Form {
            Section {
                LabeledContent("Phone", value: link.phoneName.isEmpty ? "None" : link.phoneName)
                LabeledContent("Status", value: link.state.summary)
                if link.state == .connected {
                    LabeledContent("Connected through", value: connectionText)
                }
                if link.state == .connected, let b = link.battery {
                    LabeledContent("Battery") {
                        HStack(spacing: 3) {
                            Text("\(b)%").monospacedDigit()
                            if link.charging { Image(systemName: "bolt.fill").imageScale(.small).accessibilityLabel("Charging") }
                        }
                    }
                }
            }
            if link.state == .connected, !link.perms.isEmpty {
                accessSection
            }
            Section {
                Toggle(isOn: $callAudioOnMac) {
                    Text("Use this Mac for call audio")
                    if let callAudioDetail { Text(callAudioDetail) }
                }
                if callAudioOnMac {
                    AudioDevicePicker("Microphone", input: true)
                    AudioDevicePicker("Speaker", input: false)
                }
            } header: {
                Text("Calls")
            }
            // Hidden unless the "showUseWithoutApp" default is set.
            if UserDefaults.standard.bool(forKey: "showUseWithoutApp") {
                directSection
            }
            Section {
                HStack {
                    Spacer()
                    Button("Unpair…", role: .destructive) { confirmUnpair = true }
                        .disabled(!link.isPaired)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 600)
        .sheet(isPresented: $showDirectPicker) { DirectPhonePicker() }
        .confirmationDialog("Stop using \(AdbManager.directPhoneName ?? "the phone") without the phone app?", isPresented: $confirmStopDirect) {
            Button("Stop Using", role: .destructive) { AdbManager.shared.stopUsingWithoutApp() }
        } message: {
            Text(link.isPaired ? "The paired connection continues to work." : "Phone Link forgets this phone. You can choose it again in Setup.")
        }
        .confirmationDialog("Unpair \(phoneName)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { link.unpair() }
        } message: {
            Text("To connect again, you need to pair the phone again.")
        }
    }

    @ViewBuilder private var accessSection: some View {
        let missing = AdbManager.SetupItem.allCases.filter { AdbManager.isOn($0, perms: link.perms) != true }
        Section {
            ForEach(AdbManager.SetupItem.allCases) { item in
                AccessRow(item: item, on: AdbManager.isOn(item, perms: link.perms) == true, canTurnOn: canTurnOn,
                          busy: adb.busy == item, error: adb.setupErrors[item]) {
                    adb.turnOn([item])
                }
            }
            // A grouped form puts the footer of a section with a ForEach next to the last row. Thus the text is in a row.
            HStack(spacing: 12) {
                Text(missing.isEmpty ? "All access is on."
                     : canTurnOn ? "Turn On uses USB or Wireless debugging."
                     : "To turn on access, open Phone Link on the phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if checking { ProgressView().controlSize(.small) }
                Button("Check Again") {
                    checking = true
                    link.checkStatusAgain { checking = false }
                }
                .disabled(checking)
                if canTurnOn, !missing.isEmpty {
                    Button("Turn On All") { adb.turnOn(missing) }
                        .disabled(adb.busy != nil)
                }
            }
        } header: {
            Text("Access on the Phone")
        }
    }

    @ViewBuilder private var directSection: some View {
        Section {
            if link.usesDirect {
                LabeledContent {
                    Button("Stop…") { confirmStopDirect = true }
                } label: {
                    Text(AdbManager.directPhoneName ?? "Phone")
                    Text(directStatus)
                }
            } else {
                LabeledContent {
                    Button("Choose Phone…") { showDirectPicker = true }
                } label: {
                    Text("Not in use")
                    Text("Use a phone with USB or Wireless debugging only.")
                }
            }
        } header: {
            Text("Use Without the Phone App")
        } footer: {
            if link.usesDirect {
                Text("To send messages, answer calls and use files, install Phone Link on the phone.")
                    .settingsFooter()
            }
        }
    }

    private var callAudioDetail: String? {
        if PhoneFeature.callAudio.isOff { return "Off in Settings > Connections > Connection per Feature." }
        if appOnly { return "Needs USB or Wireless debugging. Set it up in Settings > Connections." }
        if link.adbSerial == nil { return "Needs the phone connected with USB or Wireless debugging." }
        return nil
    }

    private var connectionText: String {
        let usb = adb.devices.first { $0.serial == link.adbSerial }?.usb
        let debug = link.adbSerial == nil ? nil : (usb == true ? "USB cable" : "Wireless debugging")
        switch (link.sessionConnected, debug) {
        case (true, let d?): return "Phone Link app and \(d)"
        case (true, nil): return "Phone Link app"
        case (false, let d?): return d
        default: return "None"
        }
    }

    private var directStatus: String {
        guard let s = link.directSerial else { return "Not connected" }
        let usb = adb.devices.first { $0.serial == s }?.usb ?? !s.contains(":") && !s.contains("._tcp")
        return usb ? "Connected with a USB cable" : "Connected with Wireless debugging"
    }
}

private struct AccessRow: View {
    let item: AdbManager.SetupItem
    let on: Bool
    let canTurnOn: Bool
    let busy: Bool
    let error: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                Text(error ?? item.detail)
                    .font(.callout)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if on {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else if canTurnOn {
                Button("Turn On", action: action).controlSize(.small)
            } else {
                Text("Off").foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileSettings: View {
    @AppStorage("receiveFiles") private var receive = true
    @AppStorage("receiveFolder") private var receiveFolder = ""
    @AppStorage("shareFolders") private var share = false
    @AppStorage("shareWritable") private var writable = false
    @AppStorage("driveAutoMount") private var autoMount = true
    @State private var folders = FileHub.sharedFolders
    @State private var selected: String?

    var body: some View {
        Form {
            Section {
                Toggle("Receive files from the phone", isOn: $receive)
                LabeledContent("Save files in") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: FileHub.receiveFolder.path)).resizable().frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: FileHub.receiveFolder.path))
                        Button("Choose…") { chooseReceiveFolder() }
                    }
                }
                .disabled(!receive)
            }

            Section {
                Toggle("Show the phone in Finder", isOn: $autoMount)
                    .onChange(of: autoMount) { _, on in if on { PhoneDrive.shared.mount(open: false) } else { PhoneDrive.shared.eject() } }
            }

            Section {
                Toggle("Let the phone browse folders on this Mac", isOn: $share)
                if share {
                    List(selection: $selected) {
                        ForEach(folders, id: \.self) { p in
                            HStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 16, height: 16)
                                Text(FileManager.default.displayName(atPath: p))
                                Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            .tag(p)
                        }
                    }
                    .frame(minHeight: 90)
                    .overlay { if folders.isEmpty { Text("No shared folders").foregroundStyle(.secondary) } }
                    HStack(spacing: 0) {
                        Button { addFolders() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                            .help("Share a folder")
                        Divider().frame(height: 16)
                        Button { remove() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                            .disabled(selected == nil)
                            .help("Stop sharing the selected folder")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    Toggle("Let the phone add files to these folders", isOn: $writable)
                }
            } footer: {
                if share {
                    Text("Only your paired phone can see these folders, over an encrypted connection.")
                        .settingsFooter()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 480)
    }

    private func chooseReceiveFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.directoryURL = FileHub.receiveFolder
        if p.runModal() == .OK, let u = p.url { receiveFolder = u.path }
    }

    private func addFolders() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Share"
        p.message = "The phone can browse and copy the files in these folders."
        guard p.runModal() == .OK else { return }
        for u in p.urls where !folders.contains(u.path) { folders.append(u.path) }
        FileHub.sharedFolders = folders
    }

    private func remove() {
        folders.removeAll { $0 == selected }
        selected = nil
        FileHub.sharedFolders = folders
    }
}

private struct ScreenSettings: View {
    @AppStorage("screenQuality") private var quality = ScreenQuality.high.rawValue
    @AppStorage("screenSound") private var sound = true
    @AppStorage(DockShims.settingKey) private var dockIcons = true

    var body: some View {
        Form {
            Picker("Quality", selection: $quality) {
                ForEach(ScreenQuality.allCases) { q in
                    VStack(alignment: .leading) {
                        Text(q.title)
                        Text(q.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(q.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            Section {
                Toggle("Play phone sound on this Mac", isOn: $sound)
                    .onChange(of: sound) { _, on in PhoneLink.shared.setScreenSound(on) }
            } footer: {
                Text("The phone speaker is muted while you share the screen.")
                    .settingsFooter()
            }
            Section {
                Toggle("Show app windows in the Dock", isOn: $dockIcons)
            }
            Section {
                LabeledContent("Click", value: "Tap")
                LabeledContent("Click and hold", value: "Long press")
                LabeledContent("Drag", value: "Swipe")
                LabeledContent("Scroll", value: "Scroll")
                LabeledContent("Right-click or Esc", value: "Back")
                LabeledContent("Command-V", value: "Paste")
            } header: {
                Text("Controls")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 680)
    }
}

private struct RemoteAccessSettings: View {
    @AppStorage(RemoteDesktopHost.enabledKey) private var desktop = false
    @AppStorage(RemoteTerminal.enabledKey) private var terminal = false
    @ObservedObject private var host = RemoteDesktopHost.shared
    @ObservedObject private var term = RemoteTerminal.shared

    var body: some View {
        Form {
            Section {
                Toggle("Allow your phone to control this Mac", isOn: $desktop)
                    .onChange(of: desktop) { _, on in
                        changed()
                        if on { host.requestPermissions() }
                    }
                if host.active {
                    LabeledContent {
                        Button("Stop") { host.stopFromMac() }
                    } label: {
                        Label("Your phone is controlling this Mac", systemImage: "rectangle.inset.filled.and.person.filled")
                    }
                }
            } header: {
                Text("Remote Desktop")
            } footer: {
                Text("The phone can see the screen, move the pointer and type. Only your paired phone can connect, over an encrypted connection.")
                    .settingsFooter()
            }
            if desktop {
                Section {
                    permission("Screen Recording", key: "screenRecording",
                               detail: "Shows this screen on the phone.")
                    permission("Accessibility", key: "accessibility",
                               detail: "Lets the phone click and type.")
                } header: {
                    Text("Permissions")
                } footer: {
                    if !host.missing.isEmpty {
                        Text("Turn on Phone Link in Privacy & Security. If it is already on, turn it off and on again.")
                            .settingsFooter()
                    }
                }
            }
            Section {
                Toggle("Allow Terminal access from your phone", isOn: $terminal)
                    .onChange(of: terminal) { changed() }
                if term.openTabCount > 0 {
                    LabeledContent {
                        Button("Close All") { term.closeAll() }
                    } label: {
                        Label(term.openTabCount == 1 ? "1 terminal tab is open on your phone" : "\(term.openTabCount) terminal tabs are open on your phone",
                              systemImage: "apple.terminal")
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("A shell can run any command as your user. Shells stay open for a short time after the phone disconnects.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .task {
            // System Settings does not report permission changes, so check every 2 seconds.
            host.refreshPermissions()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if desktop { host.refreshPermissions() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshPermissions()
        }
    }

    /// When a setting is off, Remote Desktop and Terminal stop at once.
    private func changed() {
        NotificationCenter.default.post(name: RemoteDesktopHost.accessChanged, object: nil)
    }

    private func permission(_ title: String, key: String, detail: String) -> some View {
        let ok = !host.missing.contains(key)
        return LabeledContent {
            if ok {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Open System Settings…") {
                    host.requestPermissions()
                    RemoteDesktopHost.openPrivacySettings(key)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !ok { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
