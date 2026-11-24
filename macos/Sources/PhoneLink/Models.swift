import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { (self[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func i64(_ k: String) -> Int64? { (self[k] as? NSNumber)?.int64Value }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
}

extension Date {
    init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}

struct SmsThread: Identifiable, Hashable {
    let id: Int64
    var address: String
    var name: String?
    var snippet: String
    var date: Date
    var unread: Int
    var recipients: [Recipient]
    var title: String { name ?? address }
    var isGroup: Bool { recipients.count > 1 }
    var addresses: [String] { recipients.isEmpty ? [address] : recipients.map(\.address) }

    init(_ j: JSON) {
        id = j.i64("id") ?? 0
        address = j.str("address") ?? ""
        name = j.str("name")
        snippet = j.str("snippet") ?? ""
        date = Date(ms: j.i64("date") ?? 0)
        unread = j.int("unread") ?? 0
        recipients = (j["recipients"] as? [JSON] ?? []).map { Recipient(address: $0.str("address") ?? "", name: $0.str("name")) }
    }
}

struct Recipient: Hashable {
    let address: String
    let name: String?
    var title: String { name ?? address }
}

struct SmsMessage: Identifiable, Hashable {
    let id: Int64
    let thread: Int64
    let address: String
    let name: String?
    let body: String
    let date: Date
    let type: Int
    let attachments: [Attachment]
    var outgoing: Bool { type != 1 }
    var pending: Bool { type == 4 || type == 6 }
    var failed: Bool { type == 5 }

    init(_ j: JSON) {
        id = j.i64("id") ?? 0
        thread = j.i64("thread") ?? 0
        address = j.str("address") ?? ""
        name = j.str("name")
        body = j.str("body") ?? ""
        date = Date(ms: j.i64("date") ?? 0)
        type = j.int("type") ?? 1
        attachments = (j["attachments"] as? [JSON] ?? []).compactMap { a in a.i64("id").map { Attachment(id: $0, type: a.str("ct") ?? "image/jpeg") } }
    }
}

struct Attachment: Hashable {
    let id: Int64
    let type: String
}

struct CallLogEntry: Identifiable, Hashable {
    let id: Int64
    let number: String
    let name: String?
    let type: Int // 1 incoming, 2 outgoing, 3 missed, 4 voicemail, 5 declined, 6 blocked
    let date: Date
    let duration: Int
    var title: String { name ?? (number.isEmpty ? "Unknown number" : number) }
    var missed: Bool { type == 3 || type == 5 }

    init(_ j: JSON) {
        id = j.i64("id") ?? 0
        number = j.str("number") ?? ""
        name = j.str("name")
        type = j.int("type") ?? 1
        date = Date(ms: j.i64("date") ?? 0)
        duration = j.int("duration") ?? 0
    }
}

struct MediaInfo: Equatable {
    var app: String
    var title: String
    var artist: String?
    var playing: Bool
    var position: Int64
    var duration: Int64
    var canNext: Bool
    var canPrevious: Bool
    var updated: Date
}

struct PhonePhoto: Identifiable, Hashable {
    let id: Int64
    let name: String
    let date: Date
    let size: Int64
    let width: Int
    let height: Int

    init(_ j: JSON) {
        id = j.i64("id") ?? 0
        name = j.str("name") ?? "Photo.jpg"
        date = Date(ms: j.i64("date") ?? 0)
        size = j.i64("size") ?? 0
        width = j.int("width") ?? 0
        height = j.int("height") ?? 0
    }
}

struct Contact: Identifiable, Hashable {
    var id: String { name + "|" + number }
    let name: String
    let number: String
    let label: String
    let starred: Bool

    init(_ j: JSON) {
        name = j.str("name") ?? ""
        number = j.str("number") ?? ""
        label = j.str("label") ?? ""
        starred = j.bool("starred")
    }
}

struct NotifAction: Hashable {
    let index: Int
    let title: String
    let reply: Bool
}

struct PhoneNotification: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let pkg: String
    let app: String
    let title: String?
    let text: String?
    let date: Date
    let silent: Bool
    let actions: [NotifAction]
    var replyAction: NotifAction? { actions.first { $0.reply } }

    init(_ j: JSON) {
        key = j.str("key") ?? UUID().uuidString
        pkg = j.str("pkg") ?? ""
        app = j.str("app") ?? pkg
        title = j.str("title")
        text = j.str("text")
        date = Date(ms: j.i64("time") ?? 0)
        silent = j.bool("silent")
        actions = (j["actions"] as? [JSON] ?? []).map {
            NotifAction(index: $0.int("index") ?? 0, title: $0.str("title") ?? "Action", reply: $0.bool("reply"))
        }
    }
}

struct CallInfo: Equatable {
    let state: String // ringing, active
    let number: String?
    let name: String?
    /// Reported only by the call audio helper: no number and no app controls.
    var fromHelper = false
    /// A VoIP call in another app, such as Google Meet. Phone Link cannot end it.
    var internet = false
    var title: String { name ?? number ?? (internet ? "Internet Call" : fromHelper ? "Phone Call" : "Unknown number") }
}

enum ScreenState: Equatable {
    case stopped(String?)
    case waiting(String)
    case streaming(width: Int, height: Int)
}

enum ScreenQuality: String, CaseIterable, Identifiable {
    case standard, high, maximum
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }
    var detail: String {
        switch self {
        case .standard: "Uses less Wi-Fi. Good on slow networks."
        case .high: "Sharp text at normal window sizes."
        case .maximum: "Full phone resolution. Needs a fast network or USB."
        }
    }
    var maxSize: Int { switch self { case .standard: 1280; case .high: 1920; case .maximum: 3200 } }
    var bitrate: Int { switch self { case .standard: 4_000_000; case .high: 8_000_000; case .maximum: 16_000_000 } }
}

struct Discovered: Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// True while pairing is open on the phone. Old phone apps do not send the "pair" value, so they are always true.
    var pairable = true
}
