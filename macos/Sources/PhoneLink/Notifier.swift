import AppKit
import os
import UserNotifications

/// Mirrors phone notifications and incoming calls into macOS notifications.
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.mdobak.phonelink", category: "notifications")

    /// False when notifications for Phone Link are off in System Settings.
    @Published private(set) var allowed = true
    private var icons: [String: NSImage] = [:]
    private var categories: [String: UNNotificationCategory] = [:]
    private let replyAction = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                            textInputButtonTitle: "Send", textInputPlaceholder: "Message")

    private let iconDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneLink/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func setup() {
        center.delegate = self
        requestAccess()
        // Check again when the user comes back from System Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAccess()
        }
        let answer = UNNotificationAction(identifier: "answer", title: "Answer", options: [])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        let callBack = UNNotificationAction(identifier: "callback", title: "Call Back", options: [])
        let message = UNNotificationAction(identifier: "message", title: "Message", options: [.foreground])
        for c in [
            UNNotificationCategory(identifier: "notif.reply", actions: [replyAction], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "notif", actions: [], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "call", actions: [answer, decline], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "missed", actions: [callBack, message], intentIdentifiers: [], options: []),
        ] { categories[c.identifier] = c }
        center.setNotificationCategories(Set(categories.values))
    }

    private func category(for n: PhoneNotification) -> String {
        // Notification actions need the phone app.
        guard PhoneLink.shared.shows(.notificationActions) else { return "notif" }
        let others = n.actions.filter { !$0.reply }.prefix(3)
        if others.isEmpty { return n.replyAction != nil ? "notif.reply" : "notif" }
        let id = "notif." + (n.replyAction != nil ? "r." : "") + others.map { "\($0.index):\($0.title)" }.joined(separator: "|")
        if categories[id] == nil {
            var actions: [UNNotificationAction] = n.replyAction != nil ? [replyAction] : []
            actions += others.map { UNNotificationAction(identifier: "act.\($0.index)", title: $0.title, options: []) }
            categories[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
            center.setNotificationCategories(Set(categories.values))
        }
        return id
    }

    // MARK: Access

    /// macOS shows the prompt only once.
    private func requestAccess() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, error in
            if !ok { self?.log.error("Notification access refused: \(error?.localizedDescription ?? "no error", privacy: .public)") }
            self?.refreshAccess()
        }
    }

    private func refreshAccess() {
        center.getNotificationSettings { [weak self] s in
            guard let self else { return }
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            self.log.info("Notification access: status \(s.authorizationStatus.rawValue, privacy: .public), alerts \(s.alertSetting.rawValue, privacy: .public), style \(s.alertStyle.rawValue, privacy: .public)")
            DispatchQueue.main.async { if self.allowed != ok { self.allowed = ok } }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.mdobak.phonelink"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func add(_ r: UNNotificationRequest) {
        center.add(r) { [weak self] error in
            guard let self, let error else { return }
            self.log.error("Notification not shown: \(error.localizedDescription, privacy: .public)")
            if (error as? UNError)?.code == .notificationsNotAllowed {
                DispatchQueue.main.async { self.allowed = false }
            }
        }
    }

    // MARK: Icons

    func cacheIcon(_ j: JSON) {
        guard let pkg = j.str("pkg"), let b64 = j.str("icon"), let data = Data(base64Encoded: b64) else { return }
        try? data.write(to: iconURL(pkg))
        icons[pkg] = NSImage(data: data)
    }

    /// The package name comes from the phone, so sanitize it to keep the file inside iconDir.
    private func iconURL(_ pkg: String) -> URL {
        let safe = String(pkg.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "." })
            .replacingOccurrences(of: "..", with: "_")
        return iconDir.appendingPathComponent(safe + ".png")
    }

    func icon(for pkg: String) -> NSImage? {
        if let i = icons[pkg] { return i }
        let i = NSImage(contentsOf: iconURL(pkg))
        icons[pkg] = i
        return i
    }

    // MARK: Posting

    func post(_ n: PhoneNotification, update: Bool) {
        guard UserDefaults.standard.bool(forKey: "mirrorNotifications") else { return }
        let c = UNMutableNotificationContent()
        c.title = n.title ?? n.app
        if n.title != nil { c.subtitle = n.app }
        c.body = n.text ?? ""
        c.threadIdentifier = n.pkg
        c.categoryIdentifier = category(for: n)
        c.userInfo = ["key": n.key, "pkg": n.pkg, "reply": n.replyAction?.index ?? -1]
        if !update, UserDefaults.standard.bool(forKey: "notificationSounds") { c.sound = .default }
        let url = iconURL(n.pkg)
        if FileManager.default.fileExists(atPath: url.path) {
            // UN moves the attachment file, so give it a copy.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            if (try? FileManager.default.copyItem(at: url, to: tmp)) != nil,
               let a = try? UNNotificationAttachment(identifier: "icon", url: tmp) {
                c.attachments = [a]
            }
        }
        add(UNNotificationRequest(identifier: n.key, content: c, trigger: nil))
    }

    func remove(key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    func removeAll() { center.removeAllDeliveredNotifications() }

    func postCall(_ call: CallInfo) {
        let c = UNMutableNotificationContent()
        c.title = call.title
        c.body = Self.detail("Incoming call", name: call.name, number: call.number)
        c.categoryIdentifier = "call"
        c.sound = .default
        add(UNNotificationRequest(identifier: "call", content: c, trigger: nil))
    }

    func postFile(name: String, url: URL, from phone: String) {
        let c = UNMutableNotificationContent()
        c.title = name
        c.body = "From \(phone.isEmpty ? "your phone" : phone) · Saved in \(url.deletingLastPathComponent().lastPathComponent)"
        c.userInfo = ["file": url.path]
        if UserDefaults.standard.bool(forKey: "notificationSounds") { c.sound = .default }
        add(UNNotificationRequest(identifier: "file." + UUID().uuidString, content: c, trigger: nil))
    }

    func postRecording(url: URL) {
        let c = UNMutableNotificationContent()
        c.title = "Call Recording Saved"
        c.body = url.deletingPathExtension().lastPathComponent
        c.userInfo = ["file": url.path]
        add(UNNotificationRequest(identifier: "recording." + UUID().uuidString, content: c, trigger: nil))
    }

    func postMissedCall(number: String?, name: String?) {
        let c = UNMutableNotificationContent()
        c.title = name ?? number ?? "Unknown number"
        c.body = Self.detail("Missed call", name: name, number: number)
        c.categoryIdentifier = number != nil ? "missed" : ""
        c.userInfo = ["number": number ?? "", "missed": true]
        if UserDefaults.standard.bool(forKey: "notificationSounds") { c.sound = .default }
        add(UNNotificationRequest(identifier: "missed." + UUID().uuidString, content: c, trigger: nil))
    }

    func postLowBattery(level: Int, phone: String) {
        let c = UNMutableNotificationContent()
        c.title = "\(phone.isEmpty ? "Phone" : phone) Battery Low"
        c.body = "\(level)% remaining. Connect the phone to a charger."
        c.sound = .default
        add(UNNotificationRequest(identifier: "battery", content: c, trigger: nil))
    }

    func postRemoteAccess(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        add(UNNotificationRequest(identifier: "remote." + UUID().uuidString, content: c, trigger: nil))
    }

    private static func detail(_ text: String, name: String?, number: String?) -> String {
        if name != nil, let number { return text + " · " + number }
        return text
    }

    func removeCall() { center.removeDeliveredNotifications(withIdentifiers: ["call"]) }

    // MARK: Opening

    /// Nil until the phone helper sends the list.
    private var launchable: Set<String>?

    private func open(key: String?, pkg: String) {
        let fallback = { Router.shared.show(.notifications, notification: key) }
        guard PhoneLink.shared.route(.appWindows).isAvailable, !pkg.isEmpty, AdbAgent.shared.ready else { fallback(); return }
        let go = { (apps: Set<String>?) in
            guard let apps, apps.contains(pkg) else { fallback(); return }
            if let key { AppStream.openNotification(pkg: pkg, key: key) }
            Router.shared.openApp(pkg)
        }
        if let l = launchable, l.contains(pkg) {
            go(l)
            loadLaunchable { _ in }
        } else {
            // The app may be new. Get the list again, but do not wait long.
            loadLaunchable(go)
        }
    }

    /// Calls done on the main thread, with nil on failure.
    private func loadLaunchable(_ done: @escaping (Set<String>?) -> Void) {
        AdbAgent.shared.request(["t": "apps", "system": true], timeout: 4) { [weak self] r in
            let set = (r?["apps"] as? [JSON]).map { Set($0.compactMap(PhoneApp.init).filter(\.launchable).map(\.pkg)) }
            if let set { self?.launchable = set }
            done(set)
        }
    }

    // MARK: Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The call panel already shows incoming calls when the app is in front.
        done(notification.request.identifier == "call" ? [.list] : [.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["key"] as? String
        DispatchQueue.main.async {
            let link = PhoneLink.shared
            switch response.actionIdentifier {
            case "answer": link.answer()
            case "decline": link.hangUp()
            case "reply":
                if let key, let idx = info["reply"] as? Int, idx >= 0, let text = (response as? UNTextInputNotificationResponse)?.userText {
                    link.runAction(key, index: idx, text: text)
                }
            case "callback":
                if let n = info["number"] as? String, !n.isEmpty { link.dial(n) }
            case "message":
                if let n = info["number"] as? String, !n.isEmpty { Router.shared.compose(to: n) }
            case let a where a.hasPrefix("act."):
                if let key, let idx = Int(a.dropFirst(4)) { link.runAction(key, index: idx) }
            case UNNotificationDismissActionIdentifier:
                if let key { link.dismiss(key) }
            default:
                let id = response.notification.request.identifier
                if let path = info["file"] as? String {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else if id == "call" || info["missed"] != nil {
                    Router.shared.show(.phone, recents: true)
                } else if id == "battery" {
                    Router.shared.show(nil)
                } else {
                    self.open(key: key, pkg: info["pkg"] as? String ?? response.notification.request.content.threadIdentifier)
                }
            }
            done()
        }
    }
}
