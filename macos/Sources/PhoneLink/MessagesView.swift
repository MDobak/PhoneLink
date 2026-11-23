import SwiftUI

struct ThreadList: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @State private var search = ""
    @State private var deletion: MessageDeletion?

    private var filtered: [SmsThread] {
        guard !search.isEmpty else { return link.threads }
        return link.threads.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.snippet.localizedCaseInsensitiveContains(search) || $0.address.contains(search) }
    }

    var body: some View {
        Group {
            if link.threads.isEmpty && link.state != .connected {
                NotConnectedView()
            } else if link.threads.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "message")
            } else {
                List(filtered, selection: Binding(get: { router.thread }, set: { router.thread = $0; if $0 != nil { router.composing = false } })) { t in
                    ThreadRow(thread: t).tag(t.id)
                        .contextMenu {
                            Button("Delete Conversation…") { deletion = MessageDeletion(thread: t.id, ids: nil) }
                        }
                }
                .overlay { if filtered.isEmpty { ContentUnavailableView.search(text: search) } }
                .onDeleteCommand { if let id = router.thread { deletion = MessageDeletion(thread: id, ids: nil) } }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .navigationTitle("Messages")
        .toolbar {
            ToolbarItem {
                // Only Phone Link on the phone can send messages.
                if link.shows(.sendMessages) {
                    Button { router.composing = true; router.thread = nil } label: { Label("New Message", systemImage: "square.and.pencil") }
                        .help("New Message")
                        .disabled(link.state != .connected)
                }
            }
        }
        .onChange(of: link.focusThread) { _, t in
            if let t { router.thread = t; router.composing = false; link.focusThread = nil }
        }
        .modifier(ConfirmMessageDeletion(request: $deletion))
        .onAppear {
            // Demo only: show the confirmation for a screenshot.
            if PhoneLink.isDemo, ProcessInfo.processInfo.environment["PHONELINK_DEMO"] == "deletethread" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { deletion = MessageDeletion(thread: 1, ids: nil) }
            }
        }
    }
}

/// Messages to delete. Nil ids means the whole conversation.
struct MessageDeletion: Identifiable {
    let id = UUID()
    let thread: Int64
    let ids: Set<Int64>?
}

private struct ConfirmMessageDeletion: ViewModifier {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var features = PhoneFeatures.shared
    @Binding var request: MessageDeletion?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }), presenting: request) { r in
            if features.available(.deleteMessages) {
                Button("Delete", role: .destructive) { link.deleteMessages(thread: r.thread, ids: r.ids) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { r in
            Text(message(r))
        }
    }

    private var isConversation: Bool { request?.ids == nil }

    private var title: String {
        if !features.available(.deleteMessages) { return isConversation ? "This Conversation Can’t Be Deleted from This Mac" : "This Message Can’t Be Deleted from This Mac" }
        if isConversation { return "Delete this conversation?" }
        return (request?.ids?.count ?? 1) == 1 ? "Delete this message?" : "Delete \(request?.ids?.count ?? 0) messages?"
    }

    private func message(_ r: MessageDeletion) -> String {
        if !features.available(.deleteMessages) {
            return "Only the default messaging app on the phone can delete messages. Delete \(r.ids == nil ? "it" : "the message") in that app."
        }
        return (r.ids == nil ? "This deletes the conversation" : "This deletes it") + " on the phone too. You can’t undo this action."
    }
}

private struct ThreadRow: View {
    let thread: SmsThread

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(thread.unread > 0 ? Color.accentColor : .clear).frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
                .accessibilityHidden(thread.unread == 0)
            if thread.isGroup {
                Image(systemName: "person.2.circle.fill").font(.system(size: 40)).foregroundStyle(.secondary).frame(width: 40, height: 40)
            } else {
                Monogram(name: thread.name ?? "", size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(listDate(thread.date)).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(thread.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(.vertical, 5)
    }
}

struct MessagesDetail: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router

    var body: some View {
        if router.composing {
            NewMessageView()
        } else if let id = router.thread, let thread = link.threads.first(where: { $0.id == id }) {
            ConversationView(thread: thread).id(id)
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "message")
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var link: PhoneLink
    let thread: SmsThread
    @State private var deletion: MessageDeletion?

    var body: some View {
        let msgs = link.messages[thread.id]
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if thread.isGroup {
                    Image(systemName: "person.2.circle.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                } else {
                    Monogram(name: thread.name ?? "", size: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.title).font(.headline).lineLimit(1)
                    if thread.isGroup {
                        Text("\(thread.recipients.count) people").font(.caption).foregroundStyle(.secondary)
                    } else if thread.name != nil {
                        Text(thread.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .help(thread.isGroup ? thread.recipients.map(\.title).joined(separator: ", ") : "")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            Divider()
            if let msgs {
                Transcript(messages: msgs, group: thread.isGroup) { m in deletion = MessageDeletion(thread: thread.id, ids: [m.id]) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if link.shows(.sendMessages) {
                ComposeBar(placeholder: thread.isGroup ? "Group Message · MMS" : "Text Message · SMS") { text, image in
                    if image != nil || thread.isGroup {
                        link.sendMms(to: thread.addresses, body: text, image: image, thread: thread.id)
                    } else {
                        link.sendSms(to: thread.address, body: text, thread: thread.id)
                    }
                }
            } else {
                SendNeedsAppNote()
            }
        }
        .navigationTitle(thread.title)
        .navigationSubtitle(thread.name != nil ? thread.address : "")
        .toolbar {
            // Only Phone Link on the phone can place calls.
            if !thread.isGroup, link.shows(.makeCalls) {
                ToolbarItem {
                    Button { link.dial(thread.address) } label: { Label("Call", systemImage: "phone") }
                        .help("Call \(thread.title)")
                }
            }
        }
        .modifier(ConfirmMessageDeletion(request: $deletion))
        .onAppear {
            link.loadMessages(thread: thread.id)
            link.markRead(thread: thread.id)
            // Demo only: show the confirmation for a screenshot.
            if PhoneLink.isDemo, ProcessInfo.processInfo.environment["PHONELINK_DEMO"] == "deletemessage", let m = link.messages[thread.id]?.last {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { deletion = MessageDeletion(thread: thread.id, ids: [m.id]) }
            }
        }
    }
}

private struct Transcript: View {
    let messages: [SmsMessage]
    var group = false
    var onDelete: (SmsMessage) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? messages[i - 1] : nil
                        if prev.map({ m.date.timeIntervalSince($0.date) > 3600 }) ?? true {
                            Text(timestamp(m.date))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                        let groupBreak = prev.map { $0.outgoing != m.outgoing || (group && $0.address != m.address) } ?? true
                        if group, !m.outgoing, groupBreak {
                            Text(m.name ?? m.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 12)
                                .padding(.top, 8)
                        }
                        Bubble(message: m, onDelete: { onDelete(m) }).padding(.top, groupBreak && !(group && !m.outgoing) ? 8 : 0).id(m.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private func timestamp(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today " + time }
        if cal.isDateInYesterday(d) { return "Yesterday " + time }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " at " + time
    }
}

private struct Bubble: View {
    let message: SmsMessage
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
            ForEach(message.attachments, id: \.id) { a in
                HStack {
                    if message.outgoing { Spacer(minLength: 80) }
                    MmsImage(id: a.id, onDelete: onDelete)
                    if !message.outgoing { Spacer(minLength: 80) }
                }
            }
            if !message.body.isEmpty { HStack {
                if message.outgoing { Spacer(minLength: 80) }
                Text(message.body)
                    .foregroundStyle(message.outgoing ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(message.outgoing ? Color(nsColor: .systemGreen) : Color(nsColor: .incomingBubble))
                    )
                    .opacity(message.pending ? 0.6 : 1)
                    .help(message.date.formatted(date: .abbreviated, time: .shortened))
                    // As in Messages: the bubble has a menu with Copy and Delete…, not text selection.
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.body, forType: .string)
                        }
                        Divider()
                        Button("Delete…", action: onDelete)
                    }
                if !message.outgoing { Spacer(minLength: 80) }
            } }
            if message.failed {
                Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if message.pending {
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MmsImage: View {
    @EnvironmentObject private var link: PhoneLink
    let id: Int64
    var onDelete: () -> Void = {}

    var body: some View {
        Group {
            if let img = link.mmsImages[id] {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .onTapGesture(count: 2) { open(img) }
                    .draggable(Image(nsImage: img))
                    .contextMenu {
                        Button("Open in Preview") { open(img) }
                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([img])
                        }
                        Divider()
                        Button("Delete…", action: onDelete)
                    }
                    .accessibilityLabel("Picture")
            } else {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color(nsColor: .incomingBubble))
                    .frame(width: 180, height: 140)
                    .overlay { ProgressView().controlSize(.small) }
                    .accessibilityLabel("Picture, loading")
            }
        }
        .onAppear { link.loadPart(id) }
    }

    private func open(_ img: NSImage) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MMS \(id).jpg")
        if (try? jpg.write(to: url)) != nil { NSWorkspace.shared.open(url) }
    }
}

/// Makes a picture small enough for MMS: JPEG, at most 1600 pixels on the long side.
enum MmsPicture {
    static func jpeg(from url: URL) -> Data? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return jpeg(from: img)
    }

    static func jpeg(from img: NSImage) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1600 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

extension NSColor {
    static let incomingBubble = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    }
}

private struct SendNeedsAppNote: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Text("To send messages from this Mac, install Phone Link on the phone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(12)
        }
        .background(.bar)
    }
}

struct ComposeBar: View {
    var placeholder = "Text Message · SMS"
    var initialText: String?
    let onSend: (String, Data?) -> Void
    @State private var text = ""
    @State private var picture: Data?
    @State private var preview: NSImage?
    @FocusState private var focused: Bool

    private var canSend: Bool { picture != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button { picture = nil; self.preview = nil } label: {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove Picture")
                    .accessibilityLabel("Remove Picture")
                }
                .padding(.leading, 40)
            }
            bar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            attach(u)
            return picture != nil
        }
        .onAppear {
            if text.isEmpty, let t = initialText { text = t }
            focused = true
        }
        // The text can come after the first appearance, for example from a phonelink:// link.
        .onChange(of: initialText) { _, t in if text.isEmpty, let t { text = t } }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: choose) {
                Image(systemName: "photo.badge.plus").font(.system(size: 17)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(height: 28)
            .help("Add Picture (MMS)")
            .accessibilityLabel("Add Picture")
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, canSend ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send")
            .accessibilityLabel("Send")
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose a picture to send"
        if p.runModal() == .OK, let u = p.url { attach(u) }
    }

    private func attach(_ u: URL) {
        guard let d = MmsPicture.jpeg(from: u) else { return }
        picture = d
        preview = NSImage(data: d)
        focused = true
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        onSend(t, picture)
        text = ""
        picture = nil
        preview = nil
    }
}

struct NewMessageView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @State private var recipients: [Recipient] = []
    @State private var to = ""
    @State private var body0: String?
    @FocusState private var toFocused: Bool

    private var suggestions: [Contact] {
        guard !to.isEmpty else { return [] }
        let digits = to.filter(\.isNumber)
        return Array(link.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(to) || (!digits.isEmpty && $0.number.filter(\.isNumber).contains(digits))
        }.prefix(8))
    }

    /// The people that get the message: the chosen ones, and a number that is still in the field.
    private var all: [String] {
        var a = recipients.map(\.address)
        if to.filter(\.isNumber).count >= 3 { a.append(to.trimmingCharacters(in: .whitespaces)) }
        return a
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("To:").foregroundStyle(.secondary)
                ForEach(recipients, id: \.address) { r in
                    HStack(spacing: 3) {
                        Text(r.title).lineLimit(1)
                        Button { recipients.removeAll { $0.address == r.address } } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(r.title)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(.tint)
                }
                TextField(recipients.isEmpty ? "Name or phone number" : "", text: $to)
                    .textFieldStyle(.plain)
                    .focused($toFocused)
                    .onSubmit(addTyped)
                    .onKeyPress(.delete) {
                        if to.isEmpty, !recipients.isEmpty { recipients.removeLast(); return .handled }
                        return .ignored
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if !suggestions.isEmpty {
                List(suggestions) { c in
                    Button { add(Recipient(address: c.number, name: c.name)) } label: {
                        HStack(spacing: 10) {
                            Monogram(name: c.name, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name)
                                Text([c.label, c.number].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            } else {
                Spacer()
            }
            if link.shows(.sendMessages) {
                ComposeBar(placeholder: all.count > 1 ? "Group Message · MMS" : "Text Message · SMS", initialText: body0) { text, image in
                    let a = all
                    if a.count > 1 || image != nil {
                        link.sendMms(to: a, body: text, image: image, thread: nil)
                    } else if let one = a.first {
                        link.sendSms(to: one, body: text, thread: nil)
                    }
                }
                .disabled(all.isEmpty)
            } else {
                SendNeedsAppNote()
            }
        }
        .navigationTitle("New Message")
        .onAppear {
            takeRouterInput()
            toFocused = true
        }
        // A new request (a "Message" button, a phonelink:// link) can come while this view shows.
        .onChange(of: router.composeTo) { takeRouterInput() }
        .onChange(of: router.composeBody) { takeRouterInput() }
    }

    private func takeRouterInput() {
        if let b = router.composeBody {
            body0 = b
            router.composeBody = nil
        }
        if let n = router.composeTo {
            let c = link.contacts.first { PhoneLink.sameNumber($0.number, n) }
            recipients = [Recipient(address: n, name: c?.name)]
            router.composeTo = nil
        }
    }

    private func add(_ r: Recipient) {
        if !recipients.contains(where: { PhoneLink.sameNumber($0.address, r.address) }) { recipients.append(r) }
        to = ""
        toFocused = true
    }

    private func addTyped() {
        if let c = suggestions.first, suggestions.count == 1 { add(Recipient(address: c.number, name: c.name)); return }
        let t = to.trimmingCharacters(in: .whitespaces)
        if t.filter(\.isNumber).count >= 3 { add(Recipient(address: t, name: nil)) }
    }
}
