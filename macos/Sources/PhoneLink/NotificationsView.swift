import AppKit
import SwiftUI

/// Cards of one app form a group. A closed group shows its newest card on a stack.
struct NotificationFeed: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @ObservedObject private var notifier = Notifier.shared
    @AppStorage("mirrorNotifications") private var mirror = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var openGroups: Set<String> = []
    @State private var openCards: Set<String> = []
    @State private var replyKey: String?
    @FocusState private var focus: String?

    private var groups: [NotificationGroup] { NotificationGroup.make(link.notifications) }

    var body: some View {
        content
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { clearAll() } label: { Label("Clear All", systemImage: "xmark.circle") }
                        .help("Clear All")
                        .disabled(link.notifications.isEmpty)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if link.notifications.isEmpty && link.state != .connected {
            NotConnectedView()
        } else if link.notifications.isEmpty {
            ContentUnavailableView("No Notifications", systemImage: "bell")
        } else {
            feed
        }
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    if mirror, !notifier.allowed, !PhoneLink.isDemo { NotificationsOffNotice() }
                    ForEach(groups) { g in
                        groupView(g)
                            .transition(cardTransition)
                    }
                    HStack {
                        Spacer()
                        Button("Clear All") { clearAll() }
                            .help("Dismiss all notifications on the phone")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .space, .delete, .deleteForward]) { press in
                    handleKey(press.key)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                if openCards.isEmpty, let first = groups.first?.items.first { openCards.insert(first.key) }
                reveal(router.notification, proxy)
            }
            .onChange(of: router.notification) { _, key in reveal(key, proxy) }
            .onChange(of: link.notifications.map(\.key)) { _, keys in
                let live = Set(keys)
                openCards.formIntersection(live)
                if let r = replyKey, !live.contains(r) { replyKey = nil }
                openGroups = openGroups.filter { pkg in groups.first { $0.pkg == pkg }.map { $0.items.count > 1 } ?? false }
            }
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .scale(scale: 0.96)))
    }

    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    // MARK: Groups and cards

    @ViewBuilder private func groupView(_ g: NotificationGroup) -> some View {
        if g.items.count == 1 {
            card(g.items[0], in: g, place: .alone)
        } else if openGroups.contains(g.pkg) {
            VStack(spacing: 2) {
                NotificationGroupHeader(pkg: g.pkg, appName: g.name, count: g.items.count,
                                        onCollapse: { withAnimation(animation) { _ = openGroups.remove(g.pkg) } },
                                        onDismissAll: { dismiss(g.items) })
                ForEach(Array(g.items.enumerated()), id: \.element.key) { i, n in
                    card(n, in: g, place: i == g.items.count - 1 ? .bottom : .middle)
                        .transition(cardTransition)
                }
            }
        } else {
            card(g.items[0], in: g, place: .alone, stack: g.items.count)
        }
    }

    private func card(_ n: PhoneNotification, in g: NotificationGroup, place: CardPlace, stack: Int? = nil) -> some View {
        let canAct = link.shows(.notificationActions)
        return NotificationCard(
            n: n, appName: g.name, place: place, stack: stack,
            expanded: openCards.contains(n.key), replying: replyKey == n.key && stack == nil, focused: focus == n.key,
            actions: canAct ? n.actions : [],
            onToggle: { toggle(n, in: g, stack: stack) },
            onDismiss: { dismiss(stack == nil ? [n] : g.items) },
            onAction: { a in link.runAction(n.key, index: a.index) },
            onReply: { withAnimation(animation) { replyKey = n.key } },
            onSend: { text in
                if let r = n.replyAction { link.runAction(n.key, index: r.index, text: text) }
                replyKey = nil
            },
            onCancelReply: { replyKey = nil; focus = n.key }
        )
        .focusable()
        .focused($focus, equals: n.key)
        .focusEffectDisabled()
        .id(n.key)
        .contextMenu { menu(n, in: g, stack: stack, canAct: canAct) }
    }

    @ViewBuilder private func menu(_ n: PhoneNotification, in g: NotificationGroup, stack: Int?, canAct: Bool) -> some View {
        if let stack {
            Button("Show All \(stack)") { toggle(n, in: g, stack: stack) }
        } else {
            Button(openCards.contains(n.key) ? "Collapse" : "Expand") { toggle(n, in: g, stack: nil) }
        }
        if canAct, !n.actions.isEmpty {
            Divider()
            if let r = n.replyAction {
                Button(r.title) {
                    withAnimation(animation) {
                        if stack != nil { openGroups.insert(g.pkg) }
                        openCards.insert(n.key)
                        replyKey = n.key
                    }
                }
            }
            ForEach(n.actions.filter { !$0.reply }, id: \.index) { a in
                Button(a.title) { link.runAction(n.key, index: a.index) }
            }
        }
        if link.shows(.appWindows), !n.pkg.isEmpty {
            Divider()
            Button("Open in Window") {
                AppStream.openNotification(pkg: n.pkg, key: n.key)
                Router.shared.openApp(n.pkg)
            }
        }
        Divider()
        Button("Copy") { copy(n) }
        Divider()
        Button("Dismiss") { dismiss([n]) }
        if g.items.count > 1 {
            Button("Dismiss All from \(g.name)") { dismiss(g.items) }
        }
    }

    // MARK: Commands

    private func toggle(_ n: PhoneNotification, in g: NotificationGroup, stack: Int?) {
        withAnimation(animation) {
            if stack != nil {
                openGroups.insert(g.pkg)
            } else if openCards.contains(n.key) {
                openCards.remove(n.key)
                if replyKey == n.key { replyKey = nil }
            } else {
                openCards.insert(n.key)
            }
        }
    }

    private func dismiss(_ items: [PhoneNotification]) {
        let keys = Set(items.map(\.key))
        if let f = focus, keys.contains(f) {
            let order = focusOrder
            let next = order.drop(while: { $0 != f }).first { !keys.contains($0) } ?? order.last { !keys.contains($0) }
            focus = next
        }
        withAnimation(animation) {
            items.forEach { link.dismiss($0.key) }
        }
    }

    private func clearAll() {
        withAnimation(animation) { link.dismissAll() }
        openGroups = []; openCards = []; replyKey = nil
    }

    private func copy(_ n: PhoneNotification) {
        let s = [n.title, n.text].compactMap { $0 }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func reveal(_ key: String?, _ proxy: ScrollViewProxy) {
        guard let key, let n = link.notifications.first(where: { $0.key == key }) else { return }
        if let g = groups.first(where: { $0.pkg == n.pkg }), g.items.count > 1 { openGroups.insert(g.pkg) }
        openCards.insert(key)
        router.notification = nil
        DispatchQueue.main.async {
            withAnimation(animation) { proxy.scrollTo(key, anchor: .center) }
            focus = key
        }
    }

    // MARK: Keyboard

    private var focusOrder: [String] {
        groups.flatMap { g in
            g.items.count == 1 || openGroups.contains(g.pkg) ? g.items.map(\.key) : [g.items[0].key]
        }
    }

    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        // The reply field needs these keys for its text.
        guard let f = focus, f != replyKey, let n = link.notifications.first(where: { $0.key == f }),
              let g = groups.first(where: { $0.pkg == n.pkg }) else { return .ignored }
        let order = focusOrder
        guard let i = order.firstIndex(of: f) else { return .ignored }
        let stacked = g.items.count > 1 && !openGroups.contains(g.pkg)
        switch key {
        case .upArrow:
            if i > 0 { focus = order[i - 1] }
        case .downArrow:
            if i < order.count - 1 { focus = order[i + 1] }
        case .return, .space:
            toggle(n, in: g, stack: stacked ? g.items.count : nil)
        case .delete, .deleteForward:
            dismiss(stacked ? g.items : [n])
        default:
            return .ignored
        }
        return .handled
    }
}

struct NotificationGroup: Identifiable {
    let pkg: String
    let name: String
    let items: [PhoneNotification]
    var id: String { pkg }

    /// The group with the newest notification comes first.
    static func make(_ list: [PhoneNotification]) -> [NotificationGroup] {
        var order: [String] = []
        var map: [String: [PhoneNotification]] = [:]
        for n in list {
            if map[n.pkg] == nil { order.append(n.pkg) }
            map[n.pkg, default: []].append(n)
        }
        return order.compactMap { pkg in
            guard let items = map[pkg]?.sorted(by: { $0.date > $1.date }), let first = items.first else { return nil }
            return NotificationGroup(pkg: pkg, name: appDisplayName(first.app, pkg: pkg), items: items)
        }
        .sorted { $0.items[0].date > $1.items[0].date }
    }
}

private struct NotificationsOffNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notifications Are Off", systemImage: "bell.slash")
                .font(.callout.weight(.semibold))
            Text("To see banners, allow notifications for Phone Link in System Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Notification Settings…") { Notifier.shared.openSystemSettings() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CardPlace.alone.shape.fill(Color.notificationCard))
        .overlay(CardPlace.alone.shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
