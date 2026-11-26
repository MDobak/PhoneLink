import Combine
import Foundation

// MARK: - Feature routing
//
// Each feature can reach the phone over two paths:
//   app:   the encrypted session with the Phone Link app. Limited to the Android permissions the user granted.
//   shell: helpers that adb runs as the shell user. They need no app permissions, but need USB or Wireless debugging.
//
// PhoneFeature.spec is the routing table. If a request fails on the first path, it is retried on the other
// one (PhoneRouter.canRetry).

enum PhoneFeature: String, CaseIterable, Identifiable {
    case messages, sendMessages, deleteMessages, contacts, callHistory, makeCalls, answerCalls,
         notifications, notificationActions, photos, deletePhotos, clipboard, openLinks, findPhone, media,
         doNotDisturb, battery, screen, screenshots, apps, appWindows, installApps, files, hotspot, callAudio,
         deviceInfo, remoteDesktop, terminal, quickControls, volume
    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Read messages"
        case .sendMessages: "Send messages"
        case .deleteMessages: "Delete messages"
        case .contacts: "Contacts"
        case .callHistory: "Call history"
        case .makeCalls: "Make calls"
        case .answerCalls: "Answer and end calls"
        case .notifications: "Notifications"
        case .notificationActions: "Notification actions and replies"
        case .photos: "Photos"
        case .deletePhotos: "Delete photos"
        case .clipboard: "Clipboard (Mac to phone)"
        case .openLinks: "Open links on the phone"
        case .findPhone: "Find the phone"
        case .media: "Media controls"
        case .doNotDisturb: "Do Not Disturb"
        case .battery: "Battery"
        case .screen: "Screen sharing and control"
        case .screenshots: "Screenshots"
        case .apps: "Apps"
        case .appWindows: "App windows and phone desktop"
        case .installApps: "Install apps"
        case .files: "Files"
        case .hotspot: "Hotspot"
        case .callAudio: "Call audio on this Mac"
        case .deviceInfo: "Device information"
        case .remoteDesktop: "Remote Desktop"
        case .terminal: "Terminal"
        case .quickControls: "Controls"
        case .volume: "Volume"
        }
    }

    /// Completes the reason text "Connect the phone ... to <purpose>."
    var purpose: String {
        switch self {
        case .messages: "see messages"
        case .sendMessages: "send messages"
        case .deleteMessages: "delete messages"
        case .contacts: "see contacts"
        case .callHistory: "see the call history"
        case .makeCalls: "make calls"
        case .answerCalls: "answer and end calls"
        case .notifications: "see notifications"
        case .notificationActions: "use notification actions"
        case .photos: "see photos"
        case .deletePhotos: "delete photos from this Mac"
        case .clipboard: "share the clipboard"
        case .openLinks: "open links on the phone"
        case .findPhone: "find the phone"
        case .media: "control media"
        case .doNotDisturb: "change Do Not Disturb"
        case .battery: "see the battery"
        case .screen: "share the phone screen"
        case .screenshots: "take screenshots"
        case .apps: "manage apps"
        case .appWindows: "open phone apps in windows"
        case .installApps: "install apps"
        case .files: "use files"
        case .hotspot: "use the hotspot"
        case .callAudio: "hear calls and talk on this Mac"
        case .deviceInfo: "see information about the phone"
        case .remoteDesktop: "use Remote Desktop"
        case .terminal: "use Terminal"
        case .quickControls: "use the controls"
        case .volume: "change the volume"
        }
    }

    var requestType: String? { spec.requests.first }

    /// Nil means only the app can handle the type.
    static func forRequest(_ type: String) -> PhoneFeature? { byRequest[type] }
    private static let byRequest: [String: PhoneFeature] = {
        var d: [String: PhoneFeature] = [:]
        for f in allCases { for t in f.spec.requests { d[t] = f } }
        return d
    }()
}

enum AppNeed: Equatable {
    case session
    /// A key that the app does not report counts as allowed.
    case perm(String)
    /// A missing key counts as not allowed.
    case reported(String)
}

enum ShellNeed: Equatable {
    case helper([String])
    /// adb sees the phone.
    case link
    /// The next screen share can go through adb (PhoneLink.usesAdbScreen).
    case screenServer
    /// The call audio helper runs and the phone gives the call audio to the shell user.
    case callAudio
}

struct FeatureSpec {
    /// The first path that can do the feature now is used.
    let order: [PhonePath]
    let app: AppNeed?
    let shell: ShellNeed?
    var requests: [String] = []
    var retry = true
    /// The path that demo mode shows as in use; nil uses the live state.
    var demo: PhonePath? = nil
}

extension PhoneFeature {
    /// The routing table.
    var spec: FeatureSpec {
        switch self {
        case .messages:
            FeatureSpec(order: [.app, .shell], app: .perm("sms"), shell: .helper(["sms.threads"]),
                        requests: ["sms.threads", "sms.messages", "mms.part"])
        case .sendMessages:
            FeatureSpec(order: [.app], app: .perm("sms"), shell: nil, requests: ["sms.send", "mms.send"])
        case .deleteMessages:
            FeatureSpec(order: [.app], app: .reported("smsDelete"), shell: nil, requests: ["sms.delete"],
                        demo: ProcessInfo.processInfo.environment["PHONELINK_DEMO_SMSDELETE"] != nil ? .app : nil)
        case .contacts:
            FeatureSpec(order: [.app, .shell], app: .perm("contacts"), shell: .helper(["contacts"]), requests: ["contacts"])
        case .callHistory:
            FeatureSpec(order: [.app, .shell], app: .perm("callLog"), shell: .helper(["calls.log"]), requests: ["calls.log"])
        case .makeCalls:
            FeatureSpec(order: [.app, .shell], app: .perm("phone"), shell: .helper(["call.dial"]), requests: ["call.dial"])
        case .answerCalls:
            FeatureSpec(order: [.app], app: .session, shell: nil, requests: ["call.answer", "call.end"])
        case .notifications:
            FeatureSpec(order: [.app, .shell], app: .perm("notifications"), shell: .helper(["notif.list"]),
                        requests: ["notif.list", "notif.dismiss"])
        case .notificationActions:
            FeatureSpec(order: [.app], app: .perm("notifications"), shell: nil, requests: ["notif.action", "notif.open"])
        case .photos:
            FeatureSpec(order: [.shell, .app], app: .perm("photos"), shell: .helper(["photos.list"]),
                        requests: ["photos.list", "photos.thumb"])
        case .deletePhotos:
            FeatureSpec(order: [.shell], app: nil, shell: .helper(["photos.delete"]), requests: ["photos.delete"], demo: .shell)
        case .clipboard:
            FeatureSpec(order: [.shell, .app], app: .session, shell: .helper(["clip", "clip.set"]), requests: ["clip"])
        case .openLinks:
            FeatureSpec(order: [.app, .shell], app: .session, shell: .helper(["url.open"]), requests: ["url.open"])
        case .findPhone:
            FeatureSpec(order: [.app, .shell], app: .session, shell: .helper(["ring"]), requests: ["ring", "ring.stop"])
        case .media:
            FeatureSpec(order: [.app, .shell], app: .perm("notifications"), shell: .helper(["media.cmd"]),
                        requests: ["media.cmd", "media.get"])
        case .doNotDisturb:
            FeatureSpec(order: [.app], app: .perm("notifications"), shell: nil, requests: ["dnd"])
        case .battery:
            FeatureSpec(order: [.app, .shell], app: .session, shell: .helper(["status"]), requests: ["status"])
        case .screen:
            FeatureSpec(order: [.shell, .app], app: .session, shell: .screenServer)
        case .screenshots:
            FeatureSpec(order: [.shell], app: nil, shell: .link)
        case .apps:
            FeatureSpec(order: [.shell], app: nil, shell: .link)
        case .appWindows:
            FeatureSpec(order: [.shell], app: nil, shell: .link)
        case .installApps:
            FeatureSpec(order: [.shell], app: nil, shell: .link)
        case .files:
            FeatureSpec(order: [.app], app: .session, shell: nil)
        case .hotspot:
            FeatureSpec(order: [.shell], app: nil, shell: .helper(["hotspot"]))
        case .callAudio:
            FeatureSpec(order: [.shell], app: nil, shell: .callAudio)
        case .deviceInfo:
            FeatureSpec(order: [.shell], app: nil, shell: .link, demo: .shell)
        case .remoteDesktop:
            FeatureSpec(order: [.app], app: .session, shell: nil)
        case .terminal:
            FeatureSpec(order: [.app], app: .session, shell: nil)
        // Quick controls and volume pick a side per id and stream (QuickControls), not through PhoneLink.send.
        case .quickControls:
            FeatureSpec(order: [.app, .shell], app: .session, shell: .helper(["controls"]), retry: false)
        case .volume:
            FeatureSpec(order: [.app, .shell], app: .session, shell: .helper(["controls"]), retry: false)
        }
    }
}

extension PhoneFeature {
    /// Why the first path is preferred. Shown in Settings.
    var note: String {
        switch self {
        case .messages: "The app gets new messages at once. USB or Wireless debugging reads them with no app permission."
        case .sendMessages: "Only the app can send messages."
        case .deleteMessages: "Only the default messaging app can delete messages."
        case .contacts: "The two connections give the same contacts. USB or Wireless debugging needs no app permission."
        case .callHistory: "The two connections give the same calls. USB or Wireless debugging needs no app permission."
        case .makeCalls: "The two connections make the call. USB or Wireless debugging needs no app permission."
        case .answerCalls: "Only the app can answer and end calls."
        case .notifications: "The app gives icons, actions and replies. USB or Wireless debugging gives only the list."
        case .notificationActions: "Only the app can use notification actions and replies."
        case .photos: "USB or Wireless debugging reads all photos with no app permission, and it is faster."
        case .deletePhotos: "Only USB or Wireless debugging can delete photos. They go to the trash on the phone."
        case .clipboard: "USB or Wireless debugging also works when the app is in the background."
        case .openLinks: "The two connections open the link."
        case .findPhone: "The two connections make the phone ring."
        case .media: "The app shows what plays and can seek. USB or Wireless debugging sends only media keys."
        case .doNotDisturb: "Only the app can change Do Not Disturb now."
        case .battery: "The app also tells its permissions."
        case .screen: "USB or Wireless debugging needs no prompt on the phone and works on the lock screen."
        case .screenshots: "Only USB or Wireless debugging gives full-resolution screenshots."
        case .apps: "Only USB or Wireless debugging can list and manage apps."
        case .appWindows: "Only USB or Wireless debugging can open apps in windows."
        case .installApps: "Only USB or Wireless debugging can install apps."
        case .files: "Only the app can browse files now."
        case .hotspot: "Only USB or Wireless debugging can control the hotspot."
        case .callAudio: "Only USB or Wireless debugging can get the call audio."
        case .deviceInfo: "Only USB or Wireless debugging can read the device information."
        case .remoteDesktop: "Remote Desktop uses the app connection."
        case .terminal: "Terminal uses the app connection."
        case .quickControls: "The app changes Do Not Disturb, sound and the flashlight. USB or Wireless debugging changes the other controls."
        case .volume: "The two connections can change the volume."
        }
    }

    var supportedPaths: [PhonePath] { spec.order.filter { $0 == .app ? spec.app != nil : spec.shell != nil } }

    /// UserDefaults key "featureRoute.<rawValue>".
    var choice: FeatureChoice {
        get {
            let c = UserDefaults.standard.string(forKey: FeatureChoice.keyPrefix + rawValue).flatMap(FeatureChoice.init) ?? .auto
            // A choice that the feature does not support counts as automatic.
            switch c {
            case .auto: return .auto
            case .none: return .none
            case .app: return supportedPaths.contains(.app) && supportedPaths.count > 1 ? .app : .auto
            case .shell: return supportedPaths.contains(.shell) && supportedPaths.count > 1 ? .shell : .auto
            }
        }
        nonmutating set {
            if newValue == .auto { UserDefaults.standard.removeObject(forKey: FeatureChoice.keyPrefix + rawValue) }
            else { UserDefaults.standard.set(newValue.rawValue, forKey: FeatureChoice.keyPrefix + rawValue) }
        }
    }
}

enum FeatureChoice: String, CaseIterable, Identifiable {
    case auto
    case app
    case shell
    /// No path, no data requests, and its pushes are dropped.
    case none

    static let keyPrefix = "featureRoute."
    var id: String { rawValue }
    var path: PhonePath? { self == .app ? .app : self == .shell ? .shell : nil }
}

extension PhoneFeature {
    /// The feature that owns a message type, for the "none" choice. Also covers pushes and prefixes not in the table.
    static func owner(of type: String) -> PhoneFeature? {
        if let f = forRequest(type) { return f }
        switch type {
        case "sms.new": return .messages
        case "sms.sent": return .sendMessages
        case "notif.posted", "notif.removed": return .notifications
        case "call.missed": return .callHistory
        case "media": return .media
        case "ring.state": return .findPhone
        case "photos.changed": return .photos
        default: break
        }
        if type.hasPrefix("fs.") { return .files }
        if type.hasPrefix("screen.") { return .screen }
        return nil
    }

    var isOff: Bool { choice == .none }
}

enum FeatureRoute: Equatable {
    case app
    case shell
    case unavailable(String)

    var path: PhonePath? {
        switch self {
        case .app: .app
        case .shell: .shell
        case .unavailable: nil
        }
    }
    var isAvailable: Bool { path != nil }
    var reason: String? { if case .unavailable(let r) = self { return r }; return nil }
}

/// Built on the main thread, and on the PhoneLink queue for requests.
struct LinkSnapshot {
    var session: Bool
    var perms: [String: Bool]
    var debugging: Bool
    var adbLinked: Bool
    var helperCan: (String) -> Bool
    var adbScreen = false
    var callAudio = false
    var demo = false
}

/// The routing rules. Pure functions of the table and a snapshot.
enum FeatureRouting {
    static func appCan(_ need: AppNeed?, _ s: LinkSnapshot) -> Bool {
        guard let need, s.session else { return false }
        switch need {
        case .session: return true
        case .perm(let k): return s.perms[k] != false
        case .reported(let k): return s.perms[k] == true
        }
    }

    static func shellCan(_ need: ShellNeed?, _ s: LinkSnapshot) -> Bool {
        guard let need, s.debugging else { return false }
        switch need {
        case .helper(let types): return types.contains(where: s.helperCan)
        case .link: return s.adbLinked
        case .screenServer: return s.adbScreen
        case .callAudio: return s.callAudio
        }
    }

    /// A forced choice uses only that path, with no fallback. lastResort: when nothing can do it but the session is
    /// open, use the app anyway so that it replies with what is missing.
    static func route(_ f: PhoneFeature, _ s: LinkSnapshot, lastResort: Bool = false, choice: FeatureChoice? = nil) -> FeatureRoute {
        let spec = f.spec
        var choice = choice ?? f.choice
        if choice == .none { return .unavailable(FeatureRouting.turnedOff) }
        if s.demo, let d = spec.demo { return d == .app ? .app : .shell }
        // With debugging off for all features, "shell" falls back to the table, which then has the app only.
        if choice == .shell && !s.debugging { choice = .auto }
        switch choice {
        case .app:
            if appCan(spec.app, s) || (lastResort && s.session) { return .app }
            return .unavailable("Set to the Phone Link app. " + reason(f, FeatureSpec(order: [.app], app: spec.app, shell: nil), s))
        case .shell:
            if shellCan(spec.shell, s) { return .shell }
            if !s.adbLinked { return .unavailable("Set to USB or Wireless debugging, which is not connected.") }
            return .unavailable("Set to USB or Wireless debugging. " + shellWait(f, spec))
        case .auto, .none:
            break
        }
        for p in spec.order {
            switch p {
            case .app: if appCan(spec.app, s) { return .app }
            case .shell: if shellCan(spec.shell, s) { return .shell }
            }
        }
        if lastResort, s.session, spec.app != nil { return .app }
        return .unavailable(reason(f, spec, s))
    }

    /// Text for a permission that is off, without a full stop.
    static func permText(_ key: String) -> String {
        switch key {
        case "sms": "Allow Phone Link to read and send messages on your phone"
        case "contacts": "Allow Phone Link to read contacts on your phone"
        case "callLog": "Allow Phone Link to read the call history on your phone"
        case "phone": "Allow Phone Link to make calls on your phone"
        case "notifications": "Allow notification access for Phone Link on your phone"
        case "photos": "Allow Phone Link to read photos on your phone"
        case "files": "Allow Phone Link to manage all files on your phone"
        case "control": "Turn on the Phone Link accessibility service on your phone"
        case "smsDelete": "Only the default messaging app on your phone can delete messages"
        default: "Allow Phone Link to \(key) on your phone"
        }
    }

    static let turnedOff = "Turned off in Phone Link Settings."
    private static let debuggingOff = "Needs USB or Wireless debugging. To use it, select Automatic in Settings > Connections."

    static func reason(_ f: PhoneFeature, _ spec: FeatureSpec, _ s: LinkSnapshot) -> String {
        if !s.session && !s.adbLinked { return "The phone is not connected." }
        let shellPossible = spec.shell != nil && s.debugging
        let orDebugging = shellPossible && !s.adbLinked ? ", or connect the phone with USB or Wireless debugging." : "."
        if let app = spec.app {
            if !s.session {
                if shellPossible && s.adbLinked { return shellWait(f, spec) }
                return "To \(f.purpose), open Phone Link on your phone."
            }
            if case .perm(let k) = app, s.perms[k] == false { return permText(k) + orDebugging }
            if case .reported(let k) = app, s.perms[k] != true { return permText(k) + orDebugging }
        }
        guard spec.shell != nil else { return "Phone Link on your phone cannot \(f.purpose)." }
        if !s.debugging { return debuggingOff }
        if !s.adbLinked { return "Connect the phone with USB or Wireless debugging to \(f.purpose)." }
        return shellWait(f, spec)
    }

    /// adb sees the phone, but the helper is not running yet or cannot do this.
    static func shellWait(_ f: PhoneFeature, _ spec: FeatureSpec) -> String {
        switch spec.shell {
        case .callAudio?: "The phone does not give the call audio to this Mac."
        case .screenServer?: "Phone Link cannot share the screen through USB or Wireless debugging now."
        default: "Phone Link is starting on the phone. Try again in a moment."
        }
    }
}

// MARK: - Live state

extension PhoneLink {
    /// Main thread.
    var featureSnapshot: LinkSnapshot {
        let agent = AdbAgent.shared
        let caps = shellCaps
        return LinkSnapshot(session: sessionConnected, perms: perms, debugging: PhoneRouter.usesDebugging,
                            adbLinked: adbSerial != nil, helperCan: { agent.ready && caps.contains($0) },
                            adbScreen: usesAdbScreen, callAudio: CallAudio.shared.available, demo: Self.isDemo)
    }

    /// Main thread.
    func route(_ f: PhoneFeature) -> FeatureRoute { FeatureRouting.route(f, featureSnapshot) }
}

/// What the views ask about features. Main thread only.
final class PhoneFeatures: ObservableObject {
    static let shared = PhoneFeatures()
    private var bag = Set<AnyCancellable>()

    private init() {
        let forward: () -> Void = { [weak self] in self?.objectWillChange.send() }
        PhoneLink.shared.objectWillChange.sink { _ in forward() }.store(in: &bag)
        AdbAgent.shared.objectWillChange.sink { _ in forward() }.store(in: &bag)
        CallAudio.shared.objectWillChange.sink { _ in forward() }.store(in: &bag)
    }

    func route(_ f: PhoneFeature) -> FeatureRoute { PhoneLink.shared.route(f) }
    func available(_ f: PhoneFeature) -> Bool { route(f).isAvailable }
    func reason(_ f: PhoneFeature) -> String? { route(f).reason }
    func path(_ f: PhoneFeature) -> PhonePath? { route(f).path }

    func setChoice(_ f: PhoneFeature, _ c: FeatureChoice) {
        objectWillChange.send()
        f.choice = c
        PhoneLink.shared.featureChoicesChanged()
    }
}
