import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

final class AppsModel: ObservableObject {
    static let shared = AppsModel()

    static let apkType = UTType("com.android.package-archive") ?? UTType(filenameExtension: "apk") ?? .data

    @Published private(set) var apps: [PhoneApp] = []
    @Published var selection: String?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var failed = false
    @Published var search = ""
    @Published private(set) var installing: String?
    @Published private(set) var installStep: (index: Int, count: Int)?
    @Published private(set) var installDone: String?
    private var installDoneClear: DispatchWorkItem?
    @Published private(set) var busy: Set<String> = []

    @AppStorage("appsShowSystem") var showSystem = false {
        willSet { objectWillChange.send() }
        didSet { reload() }
    }

    private var bag: AnyCancellable?
    private var loadGeneration = 0

    private init() {
        // Load again when the helper on the phone becomes ready.
        bag = AdbAgent.shared.$ready.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] ready in
            guard let self else { return }
            if ready { self.reload() } else if PhoneLink.shared.adbSerial == nil { self.clear() }
        }
    }

    var filtered: [PhoneApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.label.localizedCaseInsensitiveContains(q) || $0.pkg.localizedCaseInsensitiveContains(q) }
    }

    var selectedApp: PhoneApp? { selection.flatMap { s in apps.first { $0.pkg == s } } }

    /// The completion runs on the main thread after the list changes.
    func reload(done: (() -> Void)? = nil) {
        guard AdbAgent.shared.ready, PhoneLink.shared.route(.apps).isAvailable else { done?(); return }
        loadGeneration += 1
        let gen = loadGeneration
        loading = true
        AdbAgent.shared.apps(system: showSystem) { [weak self] list in
            guard let self, gen == self.loadGeneration else { return }
            self.loading = false
            self.loaded = true
            self.failed = list == nil
            if let list { self.apps = list }
            if let s = self.selection, !self.apps.contains(where: { $0.pkg == s }) { self.selection = nil }
            done?()
        }
    }

    func loadIfNeeded() {
        if apps.isEmpty && !loading { reload() }
    }

    private func clear() {
        apps = []
        selection = nil
        loaded = false
        failed = false
        busy = []
    }

    // MARK: Install

    static func isApk(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "apk" { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: apkType) == true
    }

    func chooseAndInstall(done: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Install App"
        panel.message = "Choose an APK file to install on the phone."
        panel.prompt = "Install"
        panel.allowedContentTypes = [Self.apkType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        install(urls: panel.urls, done: done)
    }

    /// Installs APKs one at a time and skips other files, then reloads and selects the new app.
    func install(urls: [URL], done: ((String?) -> Void)? = nil) {
        let apks = urls.filter(Self.isApk)
        let others = urls.filter { !Self.isApk($0) }
        guard !apks.isEmpty else {
            let names = others.map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
            done?(others.count == 1
                  ? "\(names) is not an Android app package. Only APK files can be installed."
                  : "These files are not Android app packages: \(names). Only APK files can be installed.")
            return
        }
        if let reason = PhoneLink.shared.route(.installApps).reason { done?(reason); return }
        guard installing == nil else { done?("Another app is installing. Try again when it is done."); return }
        let start = Date()
        var errors: [String] = others.map { "\($0.lastPathComponent): This file is not an APK file. It was not installed." }
        var installed: [String] = []
        installDoneClear?.cancel()
        installDone = nil

        func next(_ i: Int) {
            guard i < apks.count else {
                installing = nil
                installStep = nil
                finishInstall(since: start)
                if !installed.isEmpty {
                    showInstallDone(installed.count == 1 ? "Installed \(installed[0])" : "Installed \(installed.count) apps")
                }
                done?(errors.isEmpty ? nil : errors.joined(separator: "\n"))
                return
            }
            let url = apks[i]
            installing = url.lastPathComponent
            installStep = (i + 1, apks.count)
            AdbAgent.shared.install(url) { err in
                if let err {
                    let text = Self.installFailureText(err)
                    errors.append(urls.count > 1 ? "\(url.lastPathComponent): \(text)" : text)
                } else {
                    installed.append(url.lastPathComponent)
                }
                next(i + 1)
            }
        }
        next(0)
    }

    private func showInstallDone(_ text: String) {
        installDone = text
        let work = DispatchWorkItem { [weak self] in self?.installDone = nil }
        installDoneClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Maps installer failure codes (e.g. INSTALL_FAILED_UPDATE_INCOMPATIBLE) to a sentence for the user.
    static func installFailureText(_ raw: String) -> String {
        let known: [(String, String)] = [
            ("INSTALL_FAILED_UPDATE_INCOMPATIBLE", "A different version of this app is on the phone, signed with a different key. Uninstall the app on the phone first, then try again."),
            ("INSTALL_FAILED_VERSION_DOWNGRADE", "The phone has a newer version of this app. Uninstall the app on the phone first to install an older version."),
            ("INSTALL_FAILED_ALREADY_EXISTS", "This app is already on the phone."),
            ("INSTALL_FAILED_INSUFFICIENT_STORAGE", "The phone does not have enough free storage for this app."),
            ("INSTALL_FAILED_OLDER_SDK", "This app needs a newer version of Android than the phone has."),
            ("INSTALL_FAILED_NEWER_SDK", "This app is for an older version of Android and the phone cannot install it."),
            ("INSTALL_FAILED_DEPRECATED_SDK_VERSION", "This app is for an old version of Android. The phone does not install apps this old."),
            ("INSTALL_FAILED_NO_MATCHING_ABIS", "This app is not made for the processor of the phone."),
            ("INSTALL_FAILED_CPU_ABI_INCOMPATIBLE", "This app is not made for the processor of the phone."),
            ("INSTALL_FAILED_TEST_ONLY", "This is a test build of the app. The phone does not install test builds this way."),
            ("INSTALL_FAILED_MISSING_SHARED_LIBRARY", "This app needs a software library that is not on the phone."),
            ("INSTALL_FAILED_MISSING_FEATURE", "This app needs a hardware or software feature that the phone does not have."),
            ("INSTALL_FAILED_DUPLICATE_PERMISSION", "Another app on the phone already uses a permission that this app declares."),
            ("INSTALL_FAILED_CONFLICTING_PROVIDER", "Another app on the phone already uses a content provider that this app declares."),
            ("INSTALL_FAILED_INVALID_APK", "The APK file is damaged or not complete."),
            ("INSTALL_PARSE_FAILED_NOT_APK", "The file is not a valid APK file."),
            ("INSTALL_PARSE_FAILED_NO_CERTIFICATES", "The APK file is not signed. The phone installs only signed apps."),
            ("INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES", "The signature of the APK file is not correct."),
            ("INSTALL_PARSE_FAILED_UNEXPECTED_EXCEPTION", "The phone could not read the APK file. The file can be damaged."),
            ("INSTALL_PARSE_FAILED", "The phone could not read the APK file. The file can be damaged."),
            ("INSTALL_FAILED_USER_RESTRICTED", "The installation was stopped on the phone. Look at the phone and allow the installation, then try again."),
            ("INSTALL_FAILED_VERIFICATION_FAILURE", "The phone did not accept the app after the security check."),
            ("INSTALL_FAILED_ABORTED", "The installation was stopped on the phone."),
            ("INSTALL_FAILED_INTERNAL_ERROR", "The phone had an internal error during the installation. Try again."),
            ("INSTALL_FAILED_SESSION_INVALID", "The installation was stopped on the phone. Try again."),
            ("INSTALL_FAILED_MEDIA_UNAVAILABLE", "The storage for the app on the phone is not available."),
            ("INSTALL_FAILED_INVALID_URI", "The phone could not read the APK file."),
        ]
        if let hit = known.first(where: { raw.contains($0.0) }) { return hit.1 }
        if raw.localizedCaseInsensitiveContains("no space") { return "The phone does not have enough free storage for this app." }
        if raw.contains("Split") && raw.contains("missing") { return "This app has more than one APK file. Drop all of its APK files together." }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Selects the app that changed last, if it changed after the install started.
    private func finishInstall(since start: Date) {
        reload { [weak self] in
            guard let self else { return }
            let recent = self.apps.filter { $0.updated >= start.addingTimeInterval(-60) }
            if let app = recent.max(by: { $0.updated < $1.updated }) { self.selection = app.pkg }
        }
    }

    // MARK: Commands

    /// `check` decides if the output means success. By default any output does.
    private func run(_ pkg: String, _ args: [String], failure: String, check: ((String) -> Bool)? = nil,
             reloadAfter: Bool = false, done: @escaping (String?) -> Void) {
        busy.insert(pkg)
        AdbAgent.shared.shell(args, timeout: 60) { [weak self] out in
            guard let self else { return }
            self.busy.remove(pkg)
            var err: String?
            if let out {
                if let check, !check(out) { err = Self.failureLine(out) ?? failure }
            } else {
                err = failure
            }
            if reloadAfter { self.reload() }
            done(err)
        }
    }

    private static func failureLine(_ out: String) -> String? {
        out.split(separator: "\n").last { $0.contains("Failure") || $0.contains("rror") }.map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }

    func open(_ app: PhoneApp, done: @escaping (String?) -> Void) {
        run(app.pkg, ["monkey", "-p", app.pkg, "-c", "android.intent.category.LAUNCHER", "1"],
            failure: "The phone could not open \(app.label).", check: { !$0.contains("No activities found") && !$0.contains("aborted") },
            done: done)
    }

    func forceStop(_ app: PhoneApp, done: @escaping (String?) -> Void) {
        run(app.pkg, ["am", "force-stop", app.pkg], failure: "The phone could not stop \(app.label).", done: done)
    }

    func showOnPhone(_ app: PhoneApp, done: @escaping (String?) -> Void) {
        run(app.pkg, ["am", "start", "-a", "android.settings.APPLICATION_DETAILS_SETTINGS", "-d", "package:" + app.pkg],
            failure: "The phone could not show the app info for \(app.label).", check: { !$0.contains("Error") }, done: done)
    }

    func clearData(_ app: PhoneApp, done: @escaping (String?) -> Void) {
        run(app.pkg, ["pm", "clear", app.pkg], failure: "The phone could not clear the data of \(app.label).",
            check: { $0.contains("Success") }, done: done)
    }

    /// For an updated system app, removes only the updates.
    func uninstall(_ app: PhoneApp, done: @escaping (String?) -> Void) {
        let args = app.system ? ["pm", "uninstall-system-updates", app.pkg] : ["pm", "uninstall", app.pkg]
        let failure = app.system ? "The phone could not remove the updates of \(app.label)." : "The phone could not uninstall \(app.label)."
        run(app.pkg, args, failure: failure, check: { $0.contains("Success") }, reloadAfter: true, done: done)
    }
}

extension PhoneApp {
    /// A system app with store updates. Only the updates can be removed.
    var isUpdatedSystemApp: Bool { system && updated.timeIntervalSince(installed) > 1 }

    var canUninstall: Bool { !system || isUpdatedSystemApp }
}

// MARK: - Icon

struct PhoneAppIcon: View {
    let pkg: String
    var size: CGFloat = 32
    @State private var image: NSImage?
    @ObservedObject private var agent = AdbAgent.shared

    var body: some View {
        Group {
            if let img = image ?? AdbAgent.shared.cachedIcon(pkg) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "app").font(.system(size: size * 0.5)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
        // Retry when the helper becomes ready, and a few times if the phone sends no icon.
        .task(id: "\(pkg)|\(agent.ready)") {
            image = AdbAgent.shared.cachedIcon(pkg)
            guard image == nil, agent.ready else { return }
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2 * attempt)) }
                if Task.isCancelled { return }
                let img: NSImage? = await withCheckedContinuation { c in
                    AdbAgent.shared.icon(pkg) { c.resume(returning: $0) }
                }
                if let img { image = img; return }
            }
        }
    }
}

// MARK: - Actions

private struct AppActionState {
    var confirmClear: PhoneApp?
    var confirmUninstall: PhoneApp?
    var error: String?
}

private struct AppMenuItems: View {
    let app: PhoneApp
    @Binding var state: AppActionState
    @ObservedObject private var model = AppsModel.shared

    var body: some View {
        let report: (String?) -> Void = { if let e = $0 { state.error = e } }
        Group {
            Button("Open") { model.open(app, done: report) }
            if app.launchable {
                Button("Open in Window") { Router.shared.openApp(app.pkg) }
                PinMenuItem(app: app)
            }
            Button("Force Stop") { model.forceStop(app, done: report) }
            Button("Show App Info on Phone") { model.showOnPhone(app, done: report) }
            Divider()
            Button("Copy Package Name") { copyToPasteboard(app.pkg) }
            Divider()
            Button("Clear Data…", role: .destructive) { state.confirmClear = app }
            if app.canUninstall {
                Button(app.system ? "Uninstall Updates…" : "Uninstall…", role: .destructive) { state.confirmUninstall = app }
            }
        }
        .disabled(model.busy.contains(app.pkg))
    }
}

private struct PinMenuItem: View {
    let app: PhoneApp
    @ObservedObject private var pins = PinnedApps.shared

    var body: some View {
        if pins.isPinned(app.pkg) {
            Button("Remove from Sidebar") { pins.unpin(app.pkg) }
        } else {
            Button("Add to Sidebar") { pins.pin(app) }
        }
    }
}

private struct AppActionDialogs: ViewModifier {
    @Binding var state: AppActionState
    @ObservedObject private var model = AppsModel.shared

    func body(content: Content) -> some View {
        content
            .confirmationDialog(state.confirmClear.map { "Clear the data of “\($0.label)”?" } ?? "",
                                isPresented: Binding(get: { state.confirmClear != nil }, set: { if !$0 { state.confirmClear = nil } }),
                                presenting: state.confirmClear) { app in
                Button("Clear Data", role: .destructive) { model.clearData(app) { if let e = $0 { state.error = e } } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("All files, settings, accounts and databases of this app are permanently deleted.")
            }
            .confirmationDialog(state.confirmUninstall.map { $0.system ? "Uninstall updates to “\($0.label)”?" : "Uninstall “\($0.label)”?" } ?? "",
                                isPresented: Binding(get: { state.confirmUninstall != nil }, set: { if !$0 { state.confirmUninstall = nil } }),
                                presenting: state.confirmUninstall) { app in
                Button(app.system ? "Uninstall Updates" : "Uninstall", role: .destructive) {
                    model.uninstall(app) { if let e = $0 { state.error = e } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { app in
                Text(app.system ? "The app goes back to the version that came with the phone."
                                : "The app and all of its data are removed from the phone.")
            }
            .alert("The Action Could Not Be Completed",
                   isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
                Button("OK") { state.error = nil }
            } message: {
                Text(state.error ?? "")
            }
    }
}

struct InstallProgressOverlay: View {
    @ObservedObject private var model = AppsModel.shared

    var body: some View {
        if model.installing != nil || model.installDone != nil {
            HStack(spacing: 8) {
                if let name = model.installing {
                    ProgressView().controlSize(.small)
                    Text("Installing \(name)…").font(.callout).lineLimit(1).truncationMode(.middle)
                    if let step = model.installStep, step.count > 1 {
                        Text("\(step.index) of \(step.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if let done = model.installDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(done).font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(12)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - List

struct AppsList: View {
    @ObservedObject private var features = PhoneFeatures.shared
    @ObservedObject private var model = AppsModel.shared
    @ObservedObject private var agent = AdbAgent.shared
    @State private var actions = AppActionState()
    @State private var installError: String?
    @State private var dropTargeted = false

    var body: some View {
        content
            .navigationTitle("Apps")
            .navigationSubtitle(subtitle)
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search Apps")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.chooseAndInstall { installError = $0 } } label: {
                        Label("Install App…", systemImage: "plus")
                    }
                    .help("Install an app on the phone from an APK file")
                    .disabled(!features.available(.installApps) || model.installing != nil)
                    Menu {
                        Toggle("Show System Apps", isOn: Binding(get: { model.showSystem }, set: { model.showSystem = $0 }))
                        Divider()
                        Button("Reload") { model.reload() }
                            .disabled(!agent.ready || model.loading)
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help("Show or hide system apps")
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Accept all files. The install function tells the user about files that are not APK files.
                guard !urls.isEmpty else { return false }
                model.install(urls: urls) { installError = $0 }
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) { InstallProgressOverlay() }
            .animation(.easeInOut(duration: 0.2), value: model.installing)
            .animation(.easeInOut(duration: 0.2), value: model.installDone)
            .modifier(AppActionDialogs(state: $actions))
            .alert("The App Could Not Be Installed",
                   isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
                Button("OK") { installError = nil }
            } message: {
                Text(installError ?? "")
            }
            .onAppear { model.loadIfNeeded() }
    }

    private var subtitle: String {
        guard model.loaded, !model.apps.isEmpty else { return "" }
        let n = model.filtered.count
        return n == 1 ? "1 app" : "\(n) apps"
    }

    @ViewBuilder private var content: some View {
        if let reason = features.reason(.apps) {
            ContentUnavailableView("Apps Not Available", systemImage: "square.grid.2x2", description: Text(reason))
        } else if model.apps.isEmpty && (!agent.ready || model.loading || !model.loaded) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.apps.isEmpty && model.failed {
            ContentUnavailableView {
                Label("Apps Not Available", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The phone did not send the list of apps.")
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else if model.apps.isEmpty {
            ContentUnavailableView("No Apps", systemImage: "square.grid.2x2",
                                   description: Text("Drop APK files here to install them."))
        } else {
            List(selection: $model.selection) {
                ForEach(model.filtered) { app in
                    AppRow(app: app)
                        .tag(app.pkg)
                        .onDrag { app.launchable ? NSItemProvider(object: app.pkg as NSString) : NSItemProvider() }
                        .contextMenu { AppMenuItems(app: app, state: $actions) }
                }
            }
            .overlay {
                if model.filtered.isEmpty { ContentUnavailableView.search(text: model.search) }
            }
        }
    }
}

private struct AppRow: View {
    let app: PhoneApp
    @ObservedObject private var model = AppsModel.shared

    var body: some View {
        HStack(spacing: 10) {
            PhoneAppIcon(pkg: app.pkg, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.label).lineLimit(1)
                if !app.version.isEmpty {
                    Text(app.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.busy.contains(app.pkg) { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
        .opacity(app.enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .help(app.pkg)
    }
}

// MARK: - Detail

struct AppDetail: View {
    @ObservedObject private var model = AppsModel.shared
    @State private var actions = AppActionState()

    var body: some View {
        Group {
            if let app = model.selectedApp {
                details(app)
            } else {
                ContentUnavailableView("No App Selected", systemImage: "square.grid.2x2")
            }
        }
        .modifier(AppActionDialogs(state: $actions))
    }

    private func details(_ app: PhoneApp) -> some View {
        let busy = model.busy.contains(app.pkg)
        let report: (String?) -> Void = { if let e = $0 { actions.error = e } }
        return Form {
            Section {
                HStack(spacing: 14) {
                    PhoneAppIcon(pkg: app.pkg, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.label).font(.title2.weight(.semibold)).lineLimit(2)
                        Text(app.pkg).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if busy { ProgressView().controlSize(.small) }
                    Button("Open") { model.open(app, done: report) }
                        .buttonStyle(.borderedProminent)
                        .help("Open the app on the phone")
                    Menu {
                        if app.launchable {
                            PinMenuItem(app: app)
                            Divider()
                        }
                        Button("Force Stop") { model.forceStop(app, done: report) }
                        Button("Show App Info on Phone") { model.showOnPhone(app, done: report) }
                        Divider()
                        Button("Copy Package Name") { copyToPasteboard(app.pkg) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .labelStyle(.iconOnly)
                    .fixedSize()
                    .help("More actions")
                }
                .disabled(busy)
                .padding(.vertical, 4)
                if app.launchable {
                    LabeledContent {
                        Button("Open in Window") { Router.shared.openApp(app.pkg) }.disabled(busy)
                    } label: {
                        Text("Use on This Mac")
                        Text("Opens the app in its own window.")
                    }
                }
            }
            Section("Information") {
                LabeledContent("Version", value: app.version.isEmpty ? "Unknown" : app.version)
                LabeledContent("Installed", value: dateText(app.installed))
                LabeledContent("Updated", value: dateText(app.updated))
                LabeledContent("Size", value: app.size > 0 ? ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file) : "Unknown")
                LabeledContent("Type", value: app.system ? "System app" : "User app")
                if !app.enabled { LabeledContent("Status", value: "Turned off") }
            }
            Section("Storage") {
                LabeledContent {
                    Button("Clear Data…", role: .destructive) { actions.confirmClear = app }.disabled(busy)
                } label: {
                    Text("App Data")
                    Text("Resets the app to its installed state.")
                }
                if app.canUninstall {
                    LabeledContent {
                        Button(app.system ? "Uninstall Updates…" : "Uninstall…", role: .destructive) { actions.confirmUninstall = app }
                            .disabled(busy)
                    } label: {
                        Text(app.system ? "Updates" : "App")
                        Text(app.system ? "Goes back to the version that came with the phone." : "Removes the app and its data from the phone.")
                    }
                } else if app.system {
                    LabeledContent("App", value: "Came with the phone")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.label)
        .navigationSubtitle(app.pkg)
    }

    private func dateText(_ d: Date) -> String {
        d.timeIntervalSince1970 > 0 ? d.formatted(date: .abbreviated, time: .shortened) : "Unknown"
    }
}
