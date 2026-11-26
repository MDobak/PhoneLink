import Foundation

/// A permission for agents on this Mac. Each group shows some MCP tools (AgentTools).
enum AgentGroup: String, CaseIterable {
    case status
    case messagesRead, messagesSend
    case notificationsRead, notificationsAct
    case personalRead, personalWrite
    case calls
    case filesRead, filesWrite
    case screenRead, screenControl
    case appsRead, intents
    case clipboardRead, clipboardWrite
    case location
    case media
    case settingsRead, settingsWrite
    case alerts
    case shell
    case events
    case contentRead, contentWrite

    var key: String { "agents." + rawValue }

    /// Groups that send data out of the phone or change things. An agent that also reads private data can leak it with them.
    var sendsOrChanges: Bool {
        switch self {
        case .messagesSend, .notificationsAct, .personalWrite, .calls, .filesWrite, .screenControl, .intents,
             .clipboardWrite, .shell, .contentWrite: return true
        default: return false
        }
    }

    /// Groups that read private data.
    var readsPrivate: Bool {
        switch self {
        case .messagesRead, .notificationsRead, .personalRead, .filesRead, .screenRead, .clipboardRead, .location, .contentRead, .shell: return true
        default: return false
        }
    }
}

/// One row in the Agents tab: a group that reads, a group that changes, or both.
struct AgentRow: Identifiable {
    let title: String
    let detail: String
    let read: AgentGroup?
    let change: AgentGroup?
    var id: String { title }

    static let all: [AgentRow] = [
        AgentRow(title: "Phone status", detail: "Battery, network, signal, screen, the app in front, storage and media.", read: .status, change: nil),
        AgentRow(title: "Messages", detail: "Read conversations and attachments. Send SMS and MMS.", read: .messagesRead, change: .messagesSend),
        AgentRow(title: "Notifications", detail: "Read notifications. Dismiss, open, reply and use their actions.", read: .notificationsRead, change: .notificationsAct),
        AgentRow(title: "Contacts, calls and calendar", detail: "Read and change contacts and events. Read the call history.", read: .personalRead, change: .personalWrite),
        AgentRow(title: "Phone calls", detail: "Make, answer and end calls. Move the call audio.", read: nil, change: .calls),
        AgentRow(title: "Files and photos", detail: "List, read and find files. Write, move, copy and delete files.", read: .filesRead, change: .filesWrite),
        AgentRow(title: "Screen", detail: "See the screen, its controls and the app windows on this Mac. Tap, swipe, type, press keys, and open and close app windows.", read: .screenRead, change: .screenControl),
        AgentRow(title: "Apps and intents", detail: "List apps and their intent filters. Open apps and activities.", read: .appsRead, change: .intents),
        AgentRow(title: "Clipboard", detail: "Read and set the clipboard of the phone.", read: .clipboardRead, change: .clipboardWrite),
        AgentRow(title: "Location", detail: "The location of the phone.", read: .location, change: nil),
        AgentRow(title: "Media playback", detail: "Play, pause, skip, seek and set the media volume.", read: nil, change: .media),
        AgentRow(title: "Device settings", detail: "Wi-Fi, Bluetooth, airplane mode, mobile data, location, Do Not Disturb, brightness, flashlight, rotation, screen timeout, hotspot, ringer and volume.", read: .settingsRead, change: .settingsWrite),
        AgentRow(title: "Alerts on the phone", detail: "Show a notification on the phone or ring the phone.", read: nil, change: .alerts),
        AgentRow(title: "Shell commands", detail: "Run commands with adb. This can do all that the other tools can do.", read: nil, change: .shell),
        AgentRow(title: "Wait for events", detail: "Wait for new messages, notifications, calls and status changes. Only for the groups that are on.", read: .events, change: nil),
        AgentRow(title: "Content providers (advanced)", detail: "Query and change the data of apps through content:// URIs.", read: .contentRead, change: .contentWrite),
    ]
}

/// The Agents settings. All groups are off by default.
/// Main thread, except allows(_:) and anyOn, which are safe on any thread.
final class AgentSettings: ObservableObject {
    static let shared = AgentSettings()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "agents.enabled"); changed() }
    }
    @Published private(set) var groups: Set<AgentGroup>
    /// The phone keeps a notification history for agents (NotifHistory on Android).
    @Published var notificationHistory: Bool {
        didSet { UserDefaults.standard.set(notificationHistory, forKey: "agents.notificationHistory"); changed() }
    }

    private let lock = NSLock()
    private var snapshot: (Bool, Set<AgentGroup>)

    private init() {
        let d = UserDefaults.standard
        let on = d.bool(forKey: "agents.enabled")
        let g = Set(AgentGroup.allCases.filter { d.bool(forKey: $0.key) })
        enabled = on
        groups = g
        notificationHistory = d.bool(forKey: "agents.notificationHistory")
        snapshot = (on, g)
    }

    func isOn(_ g: AgentGroup) -> Bool { groups.contains(g) }

    func set(_ g: AgentGroup, _ on: Bool) {
        if on { groups.insert(g) } else { groups.remove(g) }
        UserDefaults.standard.set(on, forKey: g.key)
        changed()
    }

    /// True when the agents can use the group. Any thread.
    func allows(_ g: AgentGroup) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.0 && snapshot.1.contains(g)
    }

    /// Any thread.
    var anyOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.0 && !snapshot.1.isEmpty
    }

    /// The phone keeps the history only while agents can read it. Turning it off deletes the history on the phone.
    var historyOn: Bool { enabled && groups.contains(.notificationsRead) && notificationHistory }

    /// An agent with these groups can read private data and send it out of the phone.
    var riskyMix: Bool { Self.riskyMix(groups) }

    static func riskyMix(_ groups: Set<AgentGroup>) -> Bool {
        groups.contains(.shell) || (groups.contains { $0.readsPrivate } && groups.contains { $0.sendsOrChanges })
    }

    private func changed() {
        lock.lock(); snapshot = (enabled, groups); lock.unlock()
        AgentServer.shared.toolsChanged()
        AgentServer.shared.sendConfig()
    }
}
