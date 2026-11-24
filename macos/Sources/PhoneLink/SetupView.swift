import SwiftUI

/// First run. Either find the phone app on the network, or install it over USB or Wireless debugging.
/// Both ways end with the user confirming the same code on the Mac and the phone.
struct SetupView: View {
    @EnvironmentObject private var link: PhoneLink
    @State private var page: Page = SetupView.demoPage ?? .choose
    @State private var choice: Page = .app

    enum Page { case choose, app, debugging }

    /// Demo only: PHONELINK_DEMO_SETUP_PAGE=app or debugging opens that page, for screenshots.
    private static var demoPage: Page? {
        guard PhoneLink.isDemo else { return nil }
        switch ProcessInfo.processInfo.environment["PHONELINK_DEMO_SETUP_PAGE"] {
        case "app": return .app
        case "debugging": return .debugging
        default: return nil
        }
    }

    var body: some View {
        Group {
            if case let .pairing(code, phoneOK, macOK) = link.state {
                ConfirmCodePage(code: code, phoneOK: phoneOK, macOK: macOK)
            } else {
                switch page {
                case .choose: ChooseMethodPage(choice: $choice) { page = choice }
                case .app: AppPairingPage { page = .choose }
                case .debugging: DebuggingSetupPage { page = .choose }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .animation(.default, value: page)
    }
}

// MARK: - Layout

/// One page of the setup assistant, with the layout of the macOS Setup Assistant: the page content is in the center,
/// and the navigation buttons are in a bar at the bottom of the window. The buttons stay in the same position
/// on all pages: Back at the leading edge, the primary action at the trailing edge.
/// The column has a maximum width because the main window can be large.
private struct SetupPage<Content: View, Buttons: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                page
                    .padding(.horizontal, 30)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack(spacing: 12) { buttons }
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 40)

            // The page scrolls, so the content gets its full height. A grouped Form does not scroll itself.
            content
                .frame(maxWidth: 520)
                .padding(.top, 16)
        }
    }
}

private struct ConnectionStatus: View {
    @EnvironmentObject private var link: PhoneLink
    /// False on a page that shows the local network notice itself.
    var networkNotice = true

    var body: some View {
        Group {
            switch link.state {
            case .connecting(let name):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(name == "127.0.0.1" ? "the phone" : name)…")
                }
                .foregroundStyle(.secondary)
            case .failed where link.localNetworkBlocked:
                if networkNotice { LocalNetworkNotice().frame(maxWidth: 500) }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        }
        .font(.callout)
        .frame(minHeight: 20)
    }
}

// MARK: - Choose the method

private struct ChooseMethodPage: View {
    @Binding var choice: SetupView.Page
    let next: () -> Void

    var body: some View {
        SetupPage(title: "Set Up Phone Link",
                  subtitle: "Use your Android phone from this Mac.") {
            VStack(spacing: 10) {
                Text("How do you want to connect the phone?")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
                MethodCard(symbol: "wifi", tint: .blue,
                           title: "With the Phone Link App",
                           detail: "Phone Link is on the phone. Pair over Wi-Fi or Bluetooth.",
                           selected: choice == .app) { choice = .app } open: { choice = .app; next() }
                MethodCard(symbol: "cable.connector", tint: .green,
                           title: "With USB or Wireless Debugging",
                           detail: "Installs Phone Link for you. Needs Developer options.",
                           selected: choice == .debugging) { choice = .debugging } open: { choice = .debugging; next() }
            }
            .fixedSize(horizontal: false, vertical: true)
            // The same width as the sections of a grouped Form on the other pages.
            .padding(.horizontal, 20)
            .onKeyPress(.upArrow) { choice = .app; return .handled }
            .onKeyPress(.downArrow) { choice = .debugging; return .handled }
        } buttons: {
            Spacer()
            Button("Continue", action: next)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A double-click selects and continues.
private struct MethodCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let selected: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .padding(14)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

// MARK: - With the phone app

private struct AppPairingPage: View {
    @EnvironmentObject private var link: PhoneLink
    let back: () -> Void
    @State private var address = ""

    var body: some View {
        SetupPage(title: "Pair with the Phone Link App",
                  subtitle: "On the phone, open Phone Link and tap Pair a new Mac. Then click Pair next to the phone.") {
            VStack(spacing: 8) {
                Form {
                    Section {
                        if link.localNetworkBlocked {
                            LocalNetworkNotice()
                        }
                        if link.discovered.isEmpty && link.nearbyPhones.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Looking for phones…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(link.discovered) { d in
                            let name = d.name.hasPrefix("Phone Link ") ? String(d.name.dropFirst(11)) : d.name
                            if d.pairable {
                                phoneRow(name, via: "Wi-Fi") { link.connect(service: d.name) }
                            } else {
                                // The phone is on the network, but pairing is not open on it.
                                NotReadyPhoneRow(name: name, via: "Wi-Fi")
                            }
                        }
                        // A phone on the same Wi-Fi network shows one time only.
                        ForEach(link.nearbyPhones.filter { p in !link.discovered.contains { $0.name.replacingOccurrences(of: "Phone Link ", with: "").hasPrefix(p.name) } }, id: \.id) { p in
                            // The phone sends only the first 10 bytes of its name.
                            phoneRow(p.name.utf8.count >= 9 ? p.name + "…" : p.name, via: "Bluetooth") { link.connect(bluetooth: p.id) }
                        }
                    } header: {
                        Text("Phones Nearby")
                    } footer: {
                        Text("The phone must be on the same Wi-Fi network as this Mac, or near this Mac with Bluetooth on. You do not need to pair the phone in Bluetooth settings.").settingsFooter()
                    }

                    Section {
                        LabeledContent {
                            HStack {
                                TextField("IP address", text: $address, prompt: Text("192.168.1.20"))
                                    .labelsHidden()
                                    .frame(width: 140)
                                    .onSubmit(connectToAddress)
                                Button("Connect", action: connectToAddress)
                                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                            }
                        } label: {
                            Text("Connect with IP Address")
                            Text("Phone Link on the phone shows its address.")
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

                ConnectionStatus(networkNotice: false)
            }
        } buttons: {
            Button("Back", action: back).keyboardShortcut(.cancelAction)
            Spacer()
        }
        .onAppear { link.startPairingScan() }
        .onDisappear { link.stopPairingScan() }
    }

    private func phoneRow(_ name: String, via: String, pair: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "smartphone").font(.title3).foregroundStyle(.tint).frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(via).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Pair", action: pair).disabled(isBusy)
        }
    }

    private var isBusy: Bool {
        if case .connecting = link.state { return true }
        return false
    }

    private func connectToAddress() {
        guard !isBusy, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        link.connect(host: address)
    }
}

/// A phone that is near, but does not have pairing open. The row is dimmed. A click on the row or on the info
/// button shows a popover with the step that makes the phone ready.
private struct NotReadyPhoneRow: View {
    let name: String
    let via: String
    /// Demo only: PHONELINK_DEMO_NOT_READY=1 opens the popover, for screenshots.
    @State private var showHelp = PhoneLink.isDemo && ProcessInfo.processInfo.environment["PHONELINK_DEMO_NOT_READY"] == "1"

    var body: some View {
        Button { showHelp.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "smartphone").font(.title3).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    Text(via).font(.caption)
                }
                Spacer()
                Image(systemName: "info.circle")
                    .font(.body)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Not ready to pair")
        .accessibilityLabel("\(name), \(via), not ready to pair")
        .accessibilityHint("Shows how to make the phone ready")
        .popover(isPresented: $showHelp, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not Ready to Pair").font(.headline)
                Text("On the phone, open Phone Link and tap Pair a new Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 260, alignment: .leading)
        }
    }
}

// MARK: - With USB or Wireless debugging

private struct DebuggingSetupPage: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var adb = AdbManager.shared
    @StateObject private var setup = DebuggingSetup()
    let back: () -> Void
    @State private var devices: [AdbDevice] = []
    @State private var loaded = false
    @State private var sheet: Sheet?
    @State private var showDirect = false

    private enum Sheet: String, Identifiable { case qr, code; var id: String { rawValue } }

    var body: some View {
        SetupPage(title: "Set Up with USB or Wireless Debugging",
                  subtitle: "Phone Link installs its app on the phone. Then you confirm a code on both devices.") {
            VStack(spacing: 8) {
                Form {
                    if adb.adbPath == nil {
                        toolsSection
                    } else {
                        phonesSection
                        helpSection
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

                ConnectionStatus()
            }
        } buttons: {
            Button("Back", action: back)
                .keyboardShortcut(.cancelAction)
                .disabled(setup.running != nil)
            // Hidden unless the "showUseWithoutApp" default is true (defaults write ... showUseWithoutApp -bool true).
            if UserDefaults.standard.bool(forKey: "showUseWithoutApp") {
                Button("Use Without Installing…") { showDirect = true }
                    .buttonStyle(.link)
                    .controlSize(.regular)
            }
            Spacer()
        }
        .sheet(isPresented: $showDirect) { DirectPhonePicker() }
        .sheet(item: $sheet) { s in
            switch s {
            case .qr: QRPairingSheet()
            case .code: CodePairingSheet()
            }
        }
        .onAppear { adb.findAdb() }
        .task(id: adb.adbPath) {
            // Refresh the list while the page shows. Without the tools, keep looking: the user can install them now.
            while !Task.isCancelled {
                if PhoneLink.isDemo {
                    devices = DebuggingSetup.demoDevices
                } else if adb.adbPath == nil {
                    if AdbManager.path != nil { adb.findAdb(); return }
                } else {
                    devices = await Task.detached { AdbManager.listDevices() }.value
                }
                loaded = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var toolsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Get Android Platform-Tools").font(.headline)
                } icon: {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                }
                Text("Phone Link needs Android Platform-Tools from Google. Download and unzip them, then choose the platform-tools folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Download Platform-Tools", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
                    Spacer()
                    Button("Choose Folder…") { adb.chooseAdb() }
                }
            }
            .padding(.vertical, 4)
        } footer: {
            HStack(spacing: 4) {
                Text("Or use Homebrew:")
                Text("brew install android-platform-tools").font(.callout.monospaced()).textSelection(.enabled)
            }
            .settingsFooter()
        }
    }

    @ViewBuilder private var phonesSection: some View {
        Section {
            if devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(loaded ? "Connect the phone with a USB cable, or pair it for Wireless debugging." : "Looking for phones…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(devices) { d in row(d) }
        } header: {
            Text("Phones Connected to This Mac")
        } footer: {
            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsFooter()
            }
        }
    }

    @ViewBuilder private var helpSection: some View {
        Section {
            DisclosureGroup("Turn On USB Debugging") {
                VStack(alignment: .leading, spacing: 4) {
                    SetupStep(1, "On the phone, open Settings > About phone > Software information.")
                    SetupStep(2, "Tap Build number seven times. Developer options become available.")
                    SetupStep(3, "Open Settings > Developer options. Turn on USB debugging.")
                    SetupStep(4, "Connect the phone to this Mac with a USB cable. Then tap Allow on the phone.")
                }
                .font(.callout)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledContent {
                HStack {
                    Button("QR Code…") { sheet = .qr }
                    Button("Pairing Code…") { sheet = .code }
                }
            } label: {
                Text("Connect Without a Cable")
                Text("Wireless debugging, Android 11 or later.")
            }
        } header: {
            Text("No Phone in the List?")
        }
    }

    @ViewBuilder private func row(_ d: AdbDevice) -> some View {
        let isRunning = setup.running == d.serial
        HStack(spacing: 10) {
            Image(systemName: d.usb ? "cable.connector" : "wifi")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.displayModel)
                Text(isRunning ? setup.stepText : subtitle(d))
                    .font(.caption)
                    .foregroundStyle(d.state == .unauthorized && !isRunning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Set Up") { setup.start(d) }
                    .disabled(d.state != .ready || setup.running != nil || isConnecting)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isConnecting: Bool {
        if case .connecting = link.state { return true }
        return false
    }

    private func subtitle(_ d: AdbDevice) -> String {
        switch d.state {
        case .ready: d.usb ? "USB cable" : "Wi-Fi"
        case .unauthorized: "Unlock the phone and tap Allow"
        case .offline: "Not available. Connect the cable again."
        }
    }
}

struct SetupStep: View {
    let n: Int
    let text: String
    init(_ n: Int, _ text: String) { self.n = n; self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Installs Phone Link over USB or Wireless debugging, opens pairing on the phone and connects through it.
@MainActor final class DebuggingSetup: ObservableObject {
    enum Step { case installing, opening, connecting }

    @Published private(set) var running: String?
    @Published private(set) var step: Step = .installing
    @Published private(set) var error: String?

    var stepText: String {
        switch step {
        case .installing: "Installing Phone Link… If the phone asks, allow the installation."
        case .opening: "Opening Phone Link on the phone…"
        case .connecting: "Connecting…"
        }
    }

    /// Demo only: invented phones. Phone Link sends no commands to them.
    static let demoDevices = [
        AdbDevice(serial: "R5CX21DEMO", state: .ready, model: "SM_S928B", usb: true),
        AdbDevice(serial: "192.168.1.31:41225", state: .unauthorized, model: "Pixel_8", usb: false),
    ]

    func start(_ d: AdbDevice) {
        guard running == nil, !PhoneLink.isDemo else { return }
        running = d.serial
        step = .installing
        error = nil
        let serial = d.serial
        Task.detached {
            let err = Self.prepare(serial) { s in Task { @MainActor in self.step = s } }
            await MainActor.run {
                if let err {
                    self.error = err
                } else {
                    self.step = .connecting
                    PhoneLink.shared.connectUSB(serial: serial)
                }
                self.running = nil
            }
        }
    }

    /// Blocks. Returns an error message, or nil when the phone waits for the Mac.
    nonisolated private static func prepare(_ serial: String, step: (Step) -> Void) -> String? {
        let pkg = AdbManager.package
        if let apk = AdbManager.bundledAppURL {
            guard let r = AdbManager.run(["-s", serial, "install", "-r", apk.path], timeout: 300) else {
                return "The installation did not finish. Try again."
            }
            // A newer Phone Link on the phone is also correct.
            if !(r.status == 0 && r.output.contains("Success")) && !r.output.contains("INSTALL_FAILED_VERSION_DOWNGRADE") {
                let line = r.output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("rror") }
                return line.map { AppsModel.installFailureText(String($0)) } ?? "The phone did not install Phone Link."
            }
        } else if AdbManager.shell(serial, ["pm", "path", pkg])?.output.contains("package:") != true {
            return "This copy of Phone Link has no phone app inside. Install Phone Link on the phone, then use the other setup method."
        }
        step(.opening)
        // "pair" opens pairing for 2 minutes. Only shell and system can call dumpsys, so other apps cannot.
        _ = AdbManager.shell(serial, ["am", "start", "-n", pkg + "/.MainActivity"])
        for _ in 0..<20 {
            let out = AdbManager.shell(serial, ["dumpsys", "activity", "service", pkg + "/.LinkService", "pair"], timeout: 8)?.output
            if out?.contains("phonelink-pairing=on") == true { return nil }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return "Phone Link did not start on the phone. Unlock the phone and try again."
    }
}

// MARK: - Confirm the code

private struct ConfirmCodePage: View {
    @EnvironmentObject private var link: PhoneLink
    let code: String
    let phoneOK: Bool
    let macOK: Bool

    var body: some View {
        SetupPage(title: "Confirm the Code",
                  subtitle: "Make sure that \(link.phoneName.isEmpty ? "your phone" : link.phoneName) shows the same code. This keeps other devices out of the connection.") {
            VStack(spacing: 22) {
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(2)
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                VStack(alignment: .leading, spacing: 8) {
                    step("Confirmed on this Mac", done: macOK, remote: false)
                    step("Confirmed on the phone", done: phoneOK, remote: true)
                }
            }
            .padding(.vertical, 20)
            .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Spacer()
            Button("Cancel", role: .cancel) { link.confirmPairing(false) }
                .keyboardShortcut(.cancelAction)
            Button("Codes Match") { link.confirmPairing(true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(macOK)
        }
    }

    private func step(_ text: String, done: Bool, remote: Bool) -> some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if !remote {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small).frame(width: 16)
            }
            Text(text).foregroundStyle(done ? .primary : .secondary)
        }
    }
}
