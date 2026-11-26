import SwiftUI

/// Only this tab says "adb". Other tabs say "USB or Wireless debugging".
struct DebugSettings: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var adb = AdbManager.shared
    @ObservedObject private var features = PhoneFeatures.shared
    @ObservedObject private var agent = AdbAgent.shared
    @ObservedObject private var callAudio = CallAudio.shared
    @ObservedObject private var hotspot = PhoneHotspot.shared
    @AppStorage("adbAutoConnect") private var autoConnect = true
    @AppStorage("autoWirelessDebugging") private var autoWireless = true
    @AppStorage(CallAudio.mutePhoneMicKey) private var mutePhoneMic = false
    @AppStorage(Aoa.settingKey) private var useCable = true
    @AppStorage(Ble.settingKey) private var useBluetooth = true
    @AppStorage(PrivateWifi.settingKey) private var autoPrivateWifi = false
    @ObservedObject private var privateWifi = PrivateWifi.shared
    @State private var sheet: Sheet?
    @State private var wifiBusy = false
    @State private var wifiError: String?
    /// Open in demo mode so screenshots show it.
    @State private var showAdvanced = PhoneLink.isDemo

    private var appOnly: Bool { !PhoneRouter.usesDebugging }

    private enum Sheet: String, Identifiable { case features, qr, code; var id: String { rawValue } }

    var body: some View {
        Form {
            featuresSection
            if adb.adbPath == nil {
                adbMissingSection
            } else {
                debuggingSection
                wirelessSection
            }
            appConnectionSection
            hotspotSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .onAppear {
            adb.findAdb()
            link.refreshAdb()
            // Demo only: PHONELINK_DEMO_SETTINGS_SHEET=features opens the Connection per Feature sheet.
            if PhoneLink.isDemo, ProcessInfo.processInfo.environment["PHONELINK_DEMO_SETTINGS_SHEET"] == "features" { sheet = .features }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                link.refreshAdb()
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .features: FeatureChoicesSheet()
            case .qr: QRPairingSheet()
            case .code: CodePairingSheet()
            }
        }
    }

    // MARK: Connection per Feature

    /// Remote Desktop and Terminal are set in the Remote Access tab.
    static let settableFeatures = PhoneFeature.allCases.filter { $0 != .remoteDesktop && $0 != .terminal }

    @ViewBuilder private var featuresSection: some View {
        Section {
            LabeledContent {
                Button("Customize…") { sheet = .features }
            } label: {
                Text("Connection per Feature")
                Text(choicesSummary)
            }
        } footer: {
            Text("Automatic uses the best connection that is available for each feature.")
                .settingsFooter()
        }
    }

    private var choicesSummary: String {
        let choices = Self.settableFeatures.map(\.choice)
        let off = choices.filter { $0 == .none }.count
        let forced = choices.filter { $0 == .app || $0 == .shell }.count
        if off == 0 && forced == 0 { return "All features use Automatic." }
        var parts: [String] = []
        if forced > 0 { parts.append(forced == 1 ? "1 feature uses one connection." : "\(forced) features use one connection.") }
        if off > 0 { parts.append(off == 1 ? "1 feature is off." : "\(off) features are off.") }
        return parts.joined(separator: " ")
    }

    // MARK: USB and Wireless debugging

    @ViewBuilder private var adbMissingSection: some View {
        Section("USB and Wireless Debugging") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Phone Link cannot find adb", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.headline)
                Text("adb is part of Android SDK Platform-Tools. Download it, then choose the platform-tools folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Download Platform-Tools", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
                    Spacer()
                    Button("Choose adb…") { adb.chooseAdb() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var debuggingSection: some View {
        Section {
            phoneStatus
            ForEach(appOnly ? [] : adb.devices.filter { $0.serial != adb.linkedSerial }) { d in
                LabeledContent {
                    Text(otherState(d)).foregroundStyle(.secondary)
                } label: {
                    Label(d.displayModel, systemImage: d.usb ? "cable.connector" : "wifi")
                }
            }
        } header: {
            Text("USB and Wireless Debugging")
        }
    }

    @ViewBuilder private var phoneStatus: some View {
        if appOnly {
            StatusRow(symbol: "cable.connector.slash", tint: .secondary, title: "Not in use",
                      detail: "No feature uses debugging. To use it, set a feature to Automatic.")
        } else if link.state != .connected {
            StatusRow(symbol: "smartphone", tint: .secondary, title: "The phone is not connected",
                      detail: "Phone Link finds the phone in adb when the phone connects.")
        } else if let d = adb.linkedDevice {
            StatusRow(symbol: d.usb ? "cable.connector" : "wifi", tint: .green,
                      title: d.usb ? "Connected with USB" : "Connected with Wi-Fi",
                      detail: "\(link.phoneName.isEmpty ? d.displayModel : link.phoneName) · \(d.serial)")
        } else if adb.devices.contains(where: { $0.state == .unauthorized }) {
            StatusRow(symbol: "hand.raised.fill", tint: .orange, title: "Allow USB debugging on the phone",
                      detail: "Unlock the phone, select \"Always allow from this computer\", then tap Allow.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(symbol: "cable.connector.slash", tint: .secondary, title: "adb does not see \(link.phoneName.isEmpty ? "the phone" : link.phoneName)",
                          detail: "Connect the phone with a USB cable, or pair it for Wireless debugging.")
                DisclosureGroup("How to turn on USB debugging") {
                    VStack(alignment: .leading, spacing: 4) {
                        SetupStep(1, "On the phone, open Settings > About phone > Software information.")
                        SetupStep(2, "Tap Build number seven times.")
                        SetupStep(3, "Open Settings > Developer options. Turn on USB debugging.")
                        SetupStep(4, "Connect the phone to this Mac with a USB cable. Then tap Allow on the phone.")
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    private func otherState(_ d: AdbDevice) -> String {
        switch d.state {
        case .unauthorized: "Waiting for Allow"
        case .offline: "Offline"
        case .ready: adb.otherSerials.contains(d.serial) ? "Other device" : "Checking…"
        }
    }

    // MARK: Wireless

    @ViewBuilder private var wirelessSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("QR Code…") { sheet = .qr }
                    Button("Pairing Code…") { sheet = .code }
                }
            } label: {
                Text("Pair a phone")
                Text("Needs Android 11 or later.")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    if wifiBusy { ProgressView().controlSize(.small) }
                    Button("Switch to Wi-Fi") {
                        wifiBusy = true
                        wifiError = nil
                        adb.switchToWifi { err in wifiBusy = false; wifiError = err }
                    }
                    .disabled(adb.linkedDevice?.usb != true || wifiBusy)
                }
            } label: {
                Text("Use Wi-Fi without pairing")
                Text(wifiError ?? "Connect the phone with USB first. Stops when the phone restarts.")
                    .foregroundStyle(wifiError == nil ? Color.secondary : Color.red)
            }
            Toggle("Connect to paired phones automatically", isOn: $autoConnect)
            if link.isPaired, !appOnly {
                Toggle(isOn: $autoWireless) {
                    Text("Turn on Wireless debugging automatically")
                    if autoWireless && link.adbWifiGranted == false && link.adbSerial == nil {
                        Text("Connect the phone one time with USB or Wireless debugging to allow this.")
                    }
                }
            }
        } header: {
            Text("Wireless Debugging")
        }
    }

    // MARK: App connection

    @ViewBuilder private var appConnectionSection: some View {
        if link.isPaired {
            Section {
                ConnectionRow(symbol: "cable.connector", title: "USB Cable", state: cableState)
                ConnectionRow(symbol: "wifi", title: "Wi-Fi", state: wifiState)
                if link.viaHotspot, !link.usesPrivateWifi {
                    ConnectionRow(symbol: "personalhotspot", title: PhoneHotspot.term, state: .inUse(nil))
                }
                ConnectionRow(symbol: "lock.shield", title: "Private Wi-Fi", state: privateWifiState) {
                    if privateWifi.isActive {
                        Button("Stop") { privateWifi.stop() }
                    } else if privateWifi.canStart {
                        Button("Use") { privateWifi.userStart() }
                    }
                }
                ConnectionRow(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth", state: bluetoothState)
                if !appOnly {
                    ConnectionRow(symbol: "terminal", title: "USB and Wireless Debugging", state: shellState)
                }
                if link.linkKind == .bluetooth, link.state == .connected {
                    Text("On Bluetooth, screen sharing, Remote Desktop, app windows, Files and Photos need USB or Wireless debugging. Or use Private Wi-Fi.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connections")
            } footer: {
                Text("The Phone Link app uses the USB cable first, then Wi-Fi or \(PhoneHotspot.term), then Bluetooth. It changes to a faster connection when the phone is not busy.")
                    .settingsFooter()
            }
            Section {
                Toggle(isOn: $useCable) {
                    Text("Connect through the USB cable")
                    Text("With USB debugging on, Phone Link uses adb. Else it uses USB accessory mode, and the Mac cannot open the phone storage over USB.")
                }
                .onChange(of: useCable) { _, on in link.usbSettingChanged(on) }
                Toggle(isOn: $useBluetooth) {
                    Text("Connect through Bluetooth")
                    Text("When Wi-Fi and the USB cable are not available. Messages, calls, notifications and the clipboard work. Screen sharing, Files and Photos do not.")
                }
                .onChange(of: useBluetooth) { _, on in link.bluetoothSettingChanged(on) }
                Toggle(isOn: $autoPrivateWifi) {
                    Text("Create a private Wi-Fi network when needed")
                    Text("On Bluetooth, when this Mac is not on a Wi-Fi network, the phone makes a network for this Mac only. It does not share mobile data. It stops after 5 minutes without screen sharing or file transfers.")
                }
                .onChange(of: autoPrivateWifi) { _, on in privateWifi.settingChanged(on) }
            } header: {
                Text("Phone Link App")
            }
        }
    }

    private var connected: Bool { link.state == .connected }

    private var cableState: ConnectionState {
        if connected, link.linkKind == .adb { return .inUse("USB debugging") }
        if connected, link.linkKind == .usb { return .inUse("USB accessory") }
        if !useCable { return .off }
        return link.cableAvailable ? .available : .missing("Not connected")
    }

    private var wifiState: ConnectionState {
        if connected, link.linkKind == .wifi, !link.viaHotspot { return .inUse(nil) }
        return link.discovered.isEmpty ? .missing("Not found") : .available
    }

    private var privateWifiState: ConnectionState {
        switch privateWifi.phase {
        case .active: return .inUse(nil)
        case .starting, .joining: return .busy("Starting…")
        case .failed(let m): return .missing(m)
        case .idle:
            if link.linkKind == .bluetooth, connected { return .available }
            return .missing(autoPrivateWifi ? "When Phone Link uses Bluetooth" : "Off")
        }
    }

    private var bluetoothState: ConnectionState {
        if connected, link.linkKind == .bluetooth { return .inUse(nil) }
        if !useBluetooth { return .off }
        return link.bluetoothNear ? .available : .missing("Not found")
    }

    private var shellState: ConnectionState {
        if let t = link.shellTitle { return .inUse(t == "USB Debugging" ? "USB cable" : "Wi-Fi") }
        return .missing("Not connected")
    }

    // MARK: Hotspot

    @ViewBuilder private var hotspotSection: some View {
        if link.isPaired {
            let term = PhoneHotspot.term
            Section {
                if link.viaHotspot, !link.usesPrivateWifi {
                    StatusRow(symbol: "personalhotspot", tint: .green, title: "Connected through \(term)",
                              detail: link.phoneUplink == "cellular" ? "Your Mac uses the mobile data of the phone."
                                  : link.phoneUplink == "wifi" ? "The phone shares its Wi-Fi connection with your Mac."
                                  : "Your Mac uses the internet connection of the phone.")
                }
                LabeledContent {
                    if hotspot.network != nil { Button("Forget") { hotspot.forget() } }
                } label: {
                    Text("Hotspot network")
                    Text(hotspot.network.map { "“\($0.ssid)” is saved." }
                         ?? "Not saved yet. Phone Link saves it when the phone connects with USB or Wireless debugging.")
                }
                if !link.viaHotspot {
                    LabeledContent {
                        Button("Connect…") { hotspot.showSheet() }
                    } label: {
                        Text("Connect through \(term)")
                        Text("For places where your Mac and phone are not on the same Wi-Fi network.")
                    }
                }
            } header: {
                Text("Phone Hotspot")
            } footer: {
                Text("Phone Link finds the phone on its hotspot automatically. Your Mac uses the internet connection of the phone while it is on the hotspot.")
                    .settingsFooter()
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advancedSection: some View {
        Section(isExpanded: $showAdvanced) {
            if let path = adb.adbPath {
                LabeledContent {
                    Button("Change…") { adb.chooseAdb() }
                } label: {
                    Text("adb")
                    Text((adb.adbVersion.map { "Version \($0) · " } ?? "") + (path as NSString).abbreviatingWithTildeInPath)
                }
            }
            LabeledContent("Shell helper", value: agent.ready ? "Running (\(link.shellCaps.count) request types)" : "Not running")
            LabeledContent("Call audio helper", value: callAudio.available ? "Available" : "Not available")
            Toggle(isOn: $mutePhoneMic) {
                Text("Mute the phone microphone during calls on this Mac")
                Text("Experimental. Turn it off if the other person cannot hear you.")
            }
        } header: {
            Text("Advanced")
        }
    }
}

private struct StatusRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pairing sheets

struct QRPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = AdbManager.QRPairing()

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with QR Code").font(.headline)
            ZStack {
                if let img = pairing.image {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .opacity(pairing.phase == .waiting ? 1 : 0.15)
                }
                switch pairing.phase {
                case .waiting: EmptyView()
                case .pairing: ProgressView()
                case .paired: Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 56)).foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                SetupStep(1, "Connect the phone to the same Wi-Fi network as this Mac.")
                SetupStep(2, "On the phone, open Settings > Developer options > Wireless debugging.")
                SetupStep(3, "Turn on Wireless debugging. Then tap Pair device with QR code.")
                SetupStep(4, "Scan this code with the phone.")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(status).font(.callout).foregroundStyle(statusColor)

            HStack {
                Spacer()
                Button(pairing.phase == .paired ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(pairing.phase == .paired ? .defaultAction : .cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { pairing.start() }
        .onDisappear { pairing.cancel() }
    }

    private var status: String {
        switch pairing.phase {
        case .waiting: "Waiting for the phone…"
        case .pairing: "Pairing…"
        case .paired: "Paired. The phone connects with Wi-Fi in a few seconds."
        case .failed(let e): e
        }
    }

    private var statusColor: Color {
        if case .failed = pairing.phase { return .red }
        return pairing.phase == .paired ? .green : .secondary
    }
}

struct CodePairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var services: [AdbService] = []
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var paired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with Pairing Code").font(.headline).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                SetupStep(1, "On the phone, open Settings > Developer options > Wireless debugging.")
                SetupStep(2, "Tap Pair device with pairing code.")
                SetupStep(3, "Type the code that the phone shows.")
            }
            .font(.callout)

            Form {
                if services.count > 1 {
                    Picker("Phone", selection: $address) {
                        ForEach(services, id: \.address) { s in Text("\(s.address)").tag(s.address) }
                    }
                } else {
                    TextField("IP address and port", text: $address, prompt: Text(services.isEmpty ? "Looking for the phone…" : ""))
                }
                TextField("Pairing code", text: $code, prompt: Text("123456"))
                    .font(.body.monospacedDigit())
                    .onSubmit(pair)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 110)

            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if paired { Text("Paired. The phone connects with Wi-Fi in a few seconds.").font(.callout).foregroundStyle(.green) }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(paired ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !paired {
                    Button("Pair", action: pair)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || code.filter(\.isNumber).count != 6 || !address.contains(":"))
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .task {
            // The phone advertises the pairing service while it shows the code.
            while !Task.isCancelled && !paired {
                let found = await Task.detached { AdbManager.mdnsServices().filter { $0.type == "_adb-tls-pairing._tcp" } }.value
                if found != services {
                    services = found
                    // Fill in the address when the field is empty, or when exactly one phone shows a different address.
                    if address.isEmpty || (found.count == 1 && !found.contains { $0.address == address }) {
                        address = found.first?.address ?? address
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func pair() {
        guard !busy else { return }
        busy = true
        error = nil
        AdbManager.shared.pair(address: address.trimmingCharacters(in: .whitespaces), code: code.filter(\.isNumber)) { err in
            busy = false
            error = err
            paired = err == nil
        }
    }
}

// MARK: - Connection per Feature sheet

private struct FeatureChoicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var features = PhoneFeatures.shared
    @State private var confirmAllOff = false

    /// Features that are in no group go to "Other".
    private static let groups: [(title: String, features: [PhoneFeature])] = {
        let named: [(title: String, features: [PhoneFeature])] = [
            ("Messages and Calls", [.messages, .sendMessages, .deleteMessages, .contacts, .callHistory, .makeCalls, .answerCalls, .callAudio]),
            ("Notifications", [.notifications, .notificationActions, .doNotDisturb]),
            ("Screen and Apps", [.screen, .screenshots, .apps, .appWindows, .installApps]),
            ("Files and Photos", [.photos, .deletePhotos, .files, .clipboard]),
            ("Phone Controls", [.quickControls, .volume, .media, .findPhone, .openLinks, .battery, .hotspot, .deviceInfo]),
        ]
        let settable = DebugSettings.settableFeatures
        let grouped = Set(named.flatMap(\.features))
        let other = settable.filter { !grouped.contains($0) }
        return named.map { ($0.title, $0.features.filter(settable.contains)) } + (other.isEmpty ? [] : [("Other", other)])
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Connection per Feature").font(.headline)
                Text("Automatic uses the best connection that is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            Form {
                ForEach(Self.groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.features) { FeatureChoiceRow(feature: $0) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Menu("Set All To") {
                    Button("Automatic") { features.setAllInList(.auto) }
                    Button("Phone Link App") { features.setAllInList(.app) }
                    Button("USB or Wireless Debugging") { features.setAllInList(.shell) }
                    Divider()
                    Button("Off…") { confirmAllOff = true }
                }
                .fixedSize()
                .help("Features that cannot use the selected connection use Automatic.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .alert("Turn off all features?", isPresented: $confirmAllOff) {
            Button("Turn Off All", role: .destructive) { features.setAllInList(.none) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Phone Link stops using the phone for all features. You can turn them on again here.")
        }
    }
}

private struct FeatureChoiceRow: View {
    let feature: PhoneFeature
    @ObservedObject private var features = PhoneFeatures.shared

    private static func name(_ p: PhonePath) -> String { p == .app ? "the Phone Link app" : "USB or Wireless debugging" }

    var body: some View {
        let paths = feature.supportedPaths
        Group {
            if paths.count > 1 {
                Picker(selection: Binding(get: { feature.choice }, set: { features.setChoice(feature, $0) })) {
                    Text("Automatic").tag(FeatureChoice.auto)
                    Text("Phone Link App").tag(FeatureChoice.app)
                    Text("USB or Wireless Debugging").tag(FeatureChoice.shell)
                    Divider()
                    Text("Off").tag(FeatureChoice.none)
                } label: {
                    Text(feature.title)
                    if let detail { Text(detail) }
                }
                .pickerStyle(.menu)
            } else if feature == .deleteMessages, features.route(feature).path == nil {
                // Only the default SMS app can delete messages, so a switch would do nothing.
                LabeledContent {
                    Text("Not Available").foregroundStyle(.secondary)
                } label: {
                    Text(feature.title)
                    if let detail { Text(detail) }
                }
            } else {
                Toggle(isOn: Binding(get: { !feature.isOff }, set: { features.setChoice(feature, $0 ? .auto : .none) })) {
                    Text(feature.title)
                    if let detail { Text(detail) }
                }
            }
        }
        .help(feature.note)
    }

    /// Nil when off, or when a two-path feature is set to one path.
    private var detail: String? {
        if feature.isOff { return feature.supportedPaths.count == 1 ? feature.supportedPaths.first.map { "Uses \(Self.name($0))." } : nil }
        let route = features.route(feature)
        if let reason = route.reason { return reason }
        guard let p = route.path else { return nil }
        if feature.supportedPaths.count == 1 { return "Uses \(Self.name(p))." }
        return feature.choice == .auto ? "Uses \(Self.name(p)) now." : nil
    }
}

extension PhoneFeatures {
    /// Remote Desktop and Terminal are not in the list. A feature that cannot use the chosen path gets Automatic.
    fileprivate func setAllInList(_ c: FeatureChoice) {
        objectWillChange.send()
        for f in DebugSettings.settableFeatures {
            switch c {
            case .auto, .none: f.choice = c
            case .app, .shell: f.choice = f.supportedPaths.count > 1 && c.path.map(f.supportedPaths.contains) == true ? c : .auto
            }
        }
        PhoneLink.shared.featureChoicesChanged()
    }
}

/// One connection in Settings > Connections, with its state.
enum ConnectionState: Equatable {
    case inUse(String?)
    case available
    case busy(String)
    case missing(String)
    case off
}

struct ConnectionRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let state: ConnectionState
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if case .busy = state { ProgressView().controlSize(.small) }
                accessory()
            }
        } label: {
            Label {
                Text(title)
                Text(detail).foregroundStyle(isInUse ? Color.green : Color.secondary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(isInUse ? Color.green : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isInUse: Bool { if case .inUse = state { return true }; return false }

    private var detail: String {
        switch state {
        case .inUse(let d?): "In use · \(d)"
        case .inUse(nil): "In use"
        case .available: "Available"
        case .busy(let d), .missing(let d): d
        case .off: "Off"
        }
    }
}

extension ConnectionRow where Accessory == EmptyView {
    init(symbol: String, title: String, state: ConnectionState) {
        self.init(symbol: symbol, title: title, state: state) { EmptyView() }
    }
}
