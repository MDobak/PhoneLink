import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Apps pinned to the sidebar. Stored in UserDefaults ("pinnedApps") as package names, in user order.
final class PinnedApps: ObservableObject {
    static let shared = PinnedApps()

    private static let listKey = "pinnedApps"
    private static let labelsKey = "pinnedAppLabels"

    @Published private(set) var pkgs: [String] = []
    /// Last known names, shown before the app list loads.
    @Published private(set) var labels: [String: String] = [:]
    /// Packages that can open in a window. Nil until the full app list loads.
    @Published private(set) var available: Set<String>?

    private var bag = Set<AnyCancellable>()
    private var generation = 0

    private init() {
        let d = UserDefaults.standard
        pkgs = Self.unique(d.stringArray(forKey: Self.listKey) ?? [])
        labels = d.dictionary(forKey: Self.labelsKey) as? [String: String] ?? [:]
        AdbAgent.shared.$ready.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] ready in
            if ready { self?.refresh() } else { self?.available = nil }
        }.store(in: &bag)
        AppsModel.shared.$apps.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] list in
            guard let self, !list.isEmpty else { return }
            self.learn(list)
            self.refresh()
        }.store(in: &bag)
    }

    func isPinned(_ pkg: String) -> Bool { pkgs.contains(pkg) }

    func label(_ pkg: String) -> String {
        AppsModel.shared.apps.first { $0.pkg == pkg }?.label ?? labels[pkg] ?? pkg
    }

    /// False only when a successful load shows that the app is not on the phone, or that it cannot open.
    func isAvailable(_ pkg: String) -> Bool { available?.contains(pkg) ?? true }

    func pin(_ pkg: String, label: String? = nil) {
        if let label { labels[pkg] = label }
        if !pkgs.contains(pkg) { pkgs.append(pkg) }
        save()
    }

    func pin(_ app: PhoneApp) {
        guard app.launchable else { return }
        pin(app.pkg, label: app.label)
    }

    func unpin(_ pkg: String) {
        pkgs.removeAll { $0 == pkg }
        labels.removeValue(forKey: pkg)
        save()
    }

    func toggle(_ app: PhoneApp) {
        if isPinned(app.pkg) { unpin(app.pkg) } else { pin(app) }
    }

    func move(from source: IndexSet, to destination: Int) {
        pkgs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// A package that is already pinned moves to the new position.
    func insert(_ new: [String], at index: Int) {
        var list = pkgs
        var i = min(max(index, 0), list.count)
        for pkg in new {
            if let old = list.firstIndex(of: pkg) {
                list.remove(at: old)
                if old < i { i -= 1 }
            }
            list.insert(pkg, at: i)
            i += 1
        }
        for pkg in new where labels[pkg] == nil {
            if let app = AppsModel.shared.apps.first(where: { $0.pkg == pkg }) { labels[pkg] = app.label }
        }
        pkgs = list
        save()
    }

    /// Demo only: invented pins, not saved. PHONELINK_DEMO_PINS=n sets the count (0 to 8).
    func loadDemo() {
        let all: [(String, String)] = [
            ("com.whatsapp", "WhatsApp"), ("com.spotify.music", "Spotify"), ("com.google.android.apps.maps", "Maps"),
            ("com.revolut.revolut", "Revolut"), ("com.google.android.calendar", "Calendar"),
            ("com.instagram.android", "Instagram"), ("com.netflix.mediaclient", "Netflix"), ("com.duolingo", "Duolingo"),
        ]
        let n = Int(ProcessInfo.processInfo.environment["PHONELINK_DEMO_PINS"] ?? "") ?? 5
        let list = Array(all.prefix(max(0, min(n, all.count))))
        pkgs = list.map(\.0)
        labels = Dictionary(uniqueKeysWithValues: list)
    }

    /// Loads the full app list, including system apps, to find which pins can open.
    func refresh() {
        guard AdbAgent.shared.ready, !pkgs.isEmpty, PhoneLink.shared.route(.appWindows).isAvailable else { return }
        generation += 1
        let gen = generation
        AdbAgent.shared.apps(system: true) { [weak self] list in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, let list else { return }
                self.learn(list)
                self.available = Set(list.filter(\.launchable).map(\.pkg))
            }
        }
    }

    private func learn(_ list: [PhoneApp]) {
        var changed = false
        for app in list where pkgs.contains(app.pkg) && labels[app.pkg] != app.label {
            labels[app.pkg] = app.label
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        // The demo data must not replace the real list.
        if PhoneLink.isDemo { return }
        let d = UserDefaults.standard
        d.set(pkgs, forKey: Self.listKey)
        d.set(labels.filter { pkgs.contains($0.key) }, forKey: Self.labelsKey)
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Pins package names dropped as text. Returns false if no item is text.
    @discardableResult
    func accept(_ providers: [NSItemProvider], at index: Int? = nil) -> Bool {
        let items = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !items.isEmpty else { return false }
        for p in items {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = (obj as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      Self.isPackageName(s) else { return }
                DispatchQueue.main.async {
                    if let app = AppsModel.shared.apps.first(where: { $0.pkg == s }) {
                        guard app.launchable else { return }
                        self.labels[s] = app.label
                    }
                    self.insert([s], at: index ?? self.pkgs.count)
                }
            }
        }
        return true
    }

    static func isPackageName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil
    }
}

// MARK: - Sidebar

/// Rows are not selectable: a click opens the app in a window and keeps the selected section.
struct PinnedAppsSection: View {
    @ObservedObject private var pins = PinnedApps.shared
    @ObservedObject private var model = AppsModel.shared
    @AppStorage("pinnedAppsExpanded") private var expanded = true

    var body: some View {
        Section("Pinned Apps", isExpanded: $expanded) {
            if pins.pkgs.isEmpty {
                // With no pinned apps, this row is the drop target.
                DropHereRow()
            }
            ForEach(pins.pkgs, id: \.self) { pkg in
                PinnedAppRow(pkg: pkg)
            }
            .onMove { pins.move(from: $0, to: $1) }
            .onInsert(of: [.plainText]) { index, providers in pins.accept(providers, at: index) }
        }
    }
}

private struct DropHereRow: View {
    @State private var targeted = false

    var body: some View {
        Label {
            Text("Drag Apps Here").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "plus.app").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2).opacity(targeted ? 1 : 0))
        .onDrop(of: [.plainText], isTargeted: $targeted) { PinnedApps.shared.accept($0) }
        .help("Drag an app from Apps to open it from the sidebar")
    }
}

private struct PinnedAppRow: View {
    let pkg: String
    @ObservedObject private var pins = PinnedApps.shared

    var body: some View {
        let ok = pins.isAvailable(pkg)
        let name = pins.label(pkg)
        // A tap gesture, not a Button: the row has no tag, so a click does not change the selected section.
        Label {
            Text(name).lineLimit(1)
        } icon: {
            // The row can show before the helper is ready. Rebuild the icon after the check so it loads.
            PhoneAppIcon(pkg: pkg, size: 16).id(pins.available == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if ok { Router.shared.openApp(pkg) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if ok { Router.shared.openApp(pkg) } }
        .opacity(ok ? 1 : 0.45)
        .help(ok ? "Open \(name) in a window" : "\(name) is not on the phone.")
        .accessibilityHint(ok ? "Opens the app in a window" : "The app is not on the phone")
        .contextMenu {
            Button("Open in Window") { Router.shared.openApp(pkg) }.disabled(!ok)
            Button("Show in Apps") { showInApps() }.disabled(!ok)
            Divider()
            Button("Remove from Sidebar") { pins.unpin(pkg) }
        }
    }

    /// Selects the app in the Apps section. System apps show only when "Show System Apps" is on.
    private func showInApps() {
        let model = AppsModel.shared
        Router.shared.show(.apps)
        if model.apps.contains(where: { $0.pkg == pkg }) {
            model.selection = pkg
        } else {
            if !model.showSystem { model.showSystem = true }
            model.reload { model.selection = pkg }
        }
    }
}
