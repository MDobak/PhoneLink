import AppIntents
import AppKit
import CoreSpotlight

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConnected, noNumber, badLink
    case unavailable(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "The phone is not connected. Open Phone Link on the phone and try again."
        case .noNumber: "Give a phone number or a contact with a phone number."
        case .badLink: "Give a link that starts with http or https."
        case .unavailable(let reason): LocalizedStringResource(stringLiteral: reason)
        }
    }
}

/// Shortcuts actions wait up to 10 s for the phone to connect.
@MainActor
private func connectedLink(for feature: PhoneFeature) async throws -> PhoneLink {
    let link = PhoneLink.shared
    for _ in 0..<40 where !link.route(feature).isAvailable { try await Task.sleep(for: .milliseconds(250)) }
    if let reason = link.route(feature).reason {
        throw link.state == .connected ? IntentError.unavailable(reason) : IntentError.notConnected
    }
    return link
}

struct PhoneContactEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Phone Contact"
    static let defaultQuery = PhoneContactQuery()
    let id: String
    let name: String
    let number: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(number)") }

    init(_ c: Contact) { id = c.number; name = c.name; number = c.number }
}

struct PhoneContactQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [PhoneContactEntity] {
        identifiers.map { id in
            PhoneLink.shared.contacts.first { $0.number == id }.map(PhoneContactEntity.init)
                ?? PhoneContactEntity(Contact(["name": id, "number": id]))
        }
    }

    @MainActor func entities(matching string: String) async throws -> [PhoneContactEntity] {
        let digits = string.filter(\.isNumber)
        return PhoneLink.shared.contacts
            .filter { $0.name.localizedCaseInsensitiveContains(string) || (!digits.isEmpty && $0.number.filter(\.isNumber).contains(digits)) }
            .prefix(30).map(PhoneContactEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [PhoneContactEntity] {
        let c = PhoneLink.shared.contacts
        let starred = c.filter(\.starred)
        return (starred.isEmpty ? Array(c.prefix(30)) : starred).map(PhoneContactEntity.init)
    }
}

private func number(_ contact: PhoneContactEntity?, _ typed: String?) throws -> String {
    if let n = contact?.number, !n.isEmpty { return n }
    if let t = typed?.trimmingCharacters(in: .whitespaces), t.filter(\.isNumber).count >= 3 { return t }
    throw IntentError.noNumber
}

struct SendTextMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text Message"
    static let description = IntentDescription("Sends an SMS from the phone.")

    @Parameter(title: "Contact") var contact: PhoneContactEntity?
    @Parameter(title: "Phone Number") var phoneNumber: String?
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$contact)") { \.$phoneNumber }
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let to = try number(contact, phoneNumber)
        let link = try await connectedLink(for: .sendMessages)
        link.sendSms(to: to, body: message, thread: nil)
        return .result(dialog: "The phone sends the message to \(contact?.name ?? to).")
    }
}

struct CallIntent: AppIntent {
    static let title: LocalizedStringResource = "Call with Phone"
    static let description = IntentDescription("Starts a call on the phone. The call audio plays on the phone.")

    @Parameter(title: "Contact") var contact: PhoneContactEntity?
    @Parameter(title: "Phone Number") var phoneNumber: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Call \(\.$contact)") { \.$phoneNumber }
    }

    @MainActor func perform() async throws -> some IntentResult {
        let n = try number(contact, phoneNumber)
        try await connectedLink(for: .makeCalls).dial(n)
        return .result()
    }
}

struct FindPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Phone"
    static let description = IntentDescription("Makes the phone ring at full volume, also when it is silent.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await connectedLink(for: .findPhone).ring()
        return .result(dialog: "The phone rings.")
    }
}

struct SendLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Link on Phone"
    static let description = IntentDescription("Opens a web page on the phone.")

    @Parameter(title: "Link") var url: URL

    @MainActor func perform() async throws -> some IntentResult {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw IntentError.badLink }
        try await connectedLink(for: .openLinks).openOnPhone(url)
        return .result()
    }
}

struct PhoneLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindPhoneIntent(), phrases: ["Find my phone with \(.applicationName)", "Ring my phone with \(.applicationName)"],
                    shortTitle: "Find Phone", systemImageName: "iphone.radiowaves.left.and.right")
        AppShortcut(intent: SendTextMessageIntent(), phrases: ["Send a text with \(.applicationName)", "Send an SMS with \(.applicationName)"],
                    shortTitle: "Send Text Message", systemImageName: "message")
        AppShortcut(intent: CallIntent(), phrases: ["Call with \(.applicationName)", "Make a call with \(.applicationName)"],
                    shortTitle: "Call", systemImageName: "phone")
    }
}

/// Indexes contacts and conversations in Spotlight. Main thread only.
final class SpotlightIndex {
    static let shared = SpotlightIndex()
    private var lastHash = 0
    private var work: DispatchWorkItem?

    func update() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reindex() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func reindex() {
        let link = PhoneLink.shared
        // Setting off or no data (for example after unpair): remove the old items.
        guard UserDefaults.standard.bool(forKey: "spotlight"), !link.contacts.isEmpty || !link.threads.isEmpty else {
            if lastHash != 0 { CSSearchableIndex.default().deleteAllSearchableItems(); lastHash = 0 }
            return
        }
        var h = Hasher()
        link.contacts.forEach { h.combine($0.id) }
        link.threads.forEach { h.combine($0.id); h.combine($0.title) }
        let hash = h.finalize()
        guard hash != lastHash else { return }
        lastHash = hash
        var items: [CSSearchableItem] = []
        for c in link.contacts where !c.number.isEmpty {
            let a = CSSearchableItemAttributeSet(contentType: .contact)
            a.title = c.name
            a.contentDescription = [c.label, c.number].filter { !$0.isEmpty }.joined(separator: " · ") + " · Call or send a message with the phone"
            a.phoneNumbers = [c.number]
            a.supportsPhoneCall = true
            a.keywords = ["phone", "call", "message", "sms", c.number]
            items.append(CSSearchableItem(uniqueIdentifier: "contact:" + c.number, domainIdentifier: "contacts", attributeSet: a))
        }
        for t in link.threads.prefix(200) {
            let a = CSSearchableItemAttributeSet(contentType: .message)
            a.title = t.title
            a.contentDescription = t.snippet
            a.keywords = ["messages", "sms"] + t.addresses
            a.contentModificationDate = t.date
            items.append(CSSearchableItem(uniqueIdentifier: "thread:\(t.id)", domainIdentifier: "threads", attributeSet: a))
        }
        let idx = CSSearchableIndex.default()
        idx.deleteAllSearchableItems { _ in idx.indexSearchableItems(items) }
    }

    static func open(_ id: String) {
        if id.hasPrefix("contact:") {
            Router.shared.compose(to: String(id.dropFirst(8)))
        } else if id.hasPrefix("thread:"), let t = Int64(id.dropFirst(7)) {
            Router.shared.show(.messages, thread: t)
        }
    }
}

/// phonelink:// URLs. They fill in a message or the keypad; they never send or call.
///   phonelink://message?to=+15551234&body=Hello
///   phonelink://call?number=+15551234
///   phonelink://find                          (the phone rings)
///   phonelink://settings/debugging            (a Settings tab)
///   phonelink://app?pkg=com.example           (a phone app in a window; without pkg, the list of apps)
///   phonelink://desktop, phonelink://drive
///   phonelink://apps?pkg=com.example, phonelink://messages?thread=12
///   phonelink://<sidebar section>, phonelink://phone?view=recents
enum URLRouter {
    @MainActor static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "phonelink" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        switch url.host?.lowercased() {
        case "message", "sms":
            Router.shared.composeBody = v("body")
            if let to = v("to") { Router.shared.compose(to: to) } else { Router.shared.show(.messages, compose: true) }
        case "call":
            Router.shared.keypadNumber = v("number") ?? ""
            Router.shared.show(.phone)
        case "settings":
            Router.shared.showSettings(url.pathComponents.dropFirst().first)
        case "app":
            guard PhoneLink.shared.route(.appWindows).isAvailable else { Router.shared.show(nil); return }
            if let p = v("pkg") { Router.shared.openApp(p) } else { Router.shared.chooseApp() }
        case "desktop":
            if PhoneLink.shared.route(.appWindows).isAvailable { Router.shared.openDesktop() }
        case "apps" where v("pkg") != nil:
            AppsModel.shared.selection = v("pkg")
            Router.shared.show(.apps)
        case "drive":
            PhoneDrive.shared.showInFinder()
        case "find":
            if PhoneLink.shared.state == .connected { PhoneLink.shared.ring() }
        case "messages" where v("thread") != nil:
            Router.shared.show(.messages, thread: v("thread").flatMap { Int64($0) })
        case let h? where SidebarSection(rawValue: h) != nil:
            if h == "phone", v("view") == "recents" { Router.shared.phoneRecents = true }
            Router.shared.show(SidebarSection(rawValue: h))
        default:
            Router.shared.show(nil)
        }
    }
}

enum LinkSender {
    @MainActor static func prompt() {
        let a = NSAlert()
        a.messageText = "Send Link to Phone"
        a.informativeText = "The page opens on the phone."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") { field.stringValue = s }
        a.accessoryView = field
        a.addButton(withTitle: "Send")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else {
            if !s.isEmpty { PhoneLink.shared.banner = "This is not a web link." }
            return
        }
        PhoneLink.shared.openOnPhone(u)
    }
}
