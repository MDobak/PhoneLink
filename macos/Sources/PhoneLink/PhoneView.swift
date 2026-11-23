import SwiftUI

struct PhoneList: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if router.phoneRecents { RecentsList() } else { ContactsList() }
            }
            .frame(maxHeight: .infinity)
            Divider()
            CallAudioFooter()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $router.phoneRecents) {
                    Text("Recents").tag(true)
                    Text("Contacts").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

struct RecentsList: View {
    @EnvironmentObject private var link: PhoneLink
    @State private var missedOnly = false
    @State private var selection: Int64?

    private var items: [CallLogEntry] { missedOnly ? link.callLog.filter(\.missed) : link.callLog }

    var body: some View {
        Group {
            if link.callLog.isEmpty && link.state != .connected {
                NotConnectedView()
            } else if link.callLog.isEmpty {
                ContentUnavailableView("No Recent Calls", systemImage: "clock")
            } else {
                List(selection: $selection) {
                    Section {
                        ForEach(items) { c in RecentRow(entry: c).tag(c.id) }
                    }
                }
                .overlay { if items.isEmpty { ContentUnavailableView("No Missed Calls", systemImage: "phone.arrow.down.left") } }
            }
        }
        .navigationTitle("Recents")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $missedOnly) { Label("Missed", systemImage: "phone.arrow.down.left") }
                    .help(missedOnly ? "Show All Calls" : "Show Missed Calls Only")
            }
        }
        .onAppear { if link.state == .connected { link.loadCallLog() } }
    }
}

private struct RecentRow: View {
    @EnvironmentObject private var link: PhoneLink
    let entry: CallLogEntry
    @State private var hover = false

    private var symbol: String {
        switch entry.type {
        case 2: "phone.arrow.up.right"
        case 3, 5: "phone.arrow.down.left"
        case 6: "nosign"
        case 4: "recordingtape"
        default: "phone.arrow.down.left"
        }
    }

    private var kind: String {
        switch entry.type {
        case 1: "Incoming"
        case 2: "Outgoing"
        case 3: "Missed"
        case 4: "Voicemail"
        case 5: "Declined"
        case 6: "Blocked"
        default: "Call"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .opacity(entry.type == 1 ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .foregroundStyle(entry.missed ? Color(nsColor: .systemRed) : .primary)
                    .lineLimit(1)
                Text(entry.name != nil ? entry.number : kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover, !entry.number.isEmpty {
                Button { link.dial(entry.number) } label: {
                    Image(systemName: "phone.fill").foregroundStyle(Color(nsColor: .systemGreen))
                }
                .buttonStyle(.borderless)
                .help("Call \(entry.title)")
                .accessibilityLabel("Call \(entry.title)")
            } else {
                Text(listDate(entry.date)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if !entry.number.isEmpty { link.dial(entry.number) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), \(kind), \(listDate(entry.date))")
        .accessibilityAction(named: "Call") { link.dial(entry.number) }
        .contextMenu {
            if !entry.number.isEmpty {
                Button("Call Back") { link.dial(entry.number) }
                Button("Send Message") { Router.shared.compose(to: entry.number) }
                Button("Copy Number") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.number, forType: .string)
                }
            }
        }
        .help(entry.date.formatted(date: .abbreviated, time: .shortened) + (entry.duration > 0 ? " · " + Duration.seconds(entry.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) : ""))
    }
}

struct ContactsList: View {
    @EnvironmentObject private var link: PhoneLink
    @State private var search = ""
    @State private var selection: String?

    private var filtered: [Contact] {
        guard !search.isEmpty else { return link.contacts }
        let digits = search.filter(\.isNumber)
        return link.contacts.filter { $0.name.localizedCaseInsensitiveContains(search) || (!digits.isEmpty && $0.number.filter(\.isNumber).contains(digits)) }
    }

    var body: some View {
        Group {
            if link.contacts.isEmpty && link.state != .connected {
                NotConnectedView()
            } else if link.contacts.isEmpty {
                ContentUnavailableView("No Contacts", systemImage: "person.crop.circle")
            } else {
                List(selection: $selection) {
                    let favorites = filtered.filter(\.starred)
                    if !favorites.isEmpty && search.isEmpty {
                        Section("Favorites") { ForEach(favorites) { ContactRow(contact: $0).tag("f" + $0.id) } }
                    }
                    Section(search.isEmpty ? "All Contacts" : "Results") {
                        ForEach(filtered) { ContactRow(contact: $0).tag($0.id) }
                    }
                }
                .overlay { if filtered.isEmpty { ContentUnavailableView.search(text: search) } }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Contacts")
        .navigationTitle("Contacts")
    }
}

private struct ContactRow: View {
    @EnvironmentObject private var link: PhoneLink
    let contact: Contact
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Monogram(name: contact.name, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).lineLimit(1)
                Text([contact.label, contact.number].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { link.dial(contact.number) } label: {
                Image(systemName: "phone.fill").foregroundStyle(Color(nsColor: .systemGreen))
            }
            .buttonStyle(.borderless)
            .opacity(hover ? 1 : 0)
            .help("Call \(contact.name)")
            .accessibilityLabel("Call \(contact.name)")
        }
        .padding(.vertical, 2)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Call") { link.dial(contact.number) }
            Button("Send Message") { Router.shared.compose(to: contact.number) }
            Button("Copy Number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(contact.number, forType: .string)
            }
        }
        .onTapGesture(count: 2) { link.dial(contact.number) }
    }
}

struct KeypadView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @AppStorage(CallAudio.settingKey) private var callAudioOnMac = true
    @State private var number = ""

    private var match: Contact? {
        let d = number.filter(\.isNumber)
        guard d.count >= 6 else { return nil }
        return link.contacts.first { PhoneLink.sameNumber($0.number, number) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 4) {
                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 34, weight: .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                Text(match?.name ?? " ").font(.callout).foregroundStyle(.tint)
            }
            .frame(height: 70)
            .padding(.horizontal, 24)

            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                ForEach(0..<4) { r in
                    GridRow {
                        ForEach(0..<3) { c in
                            let k = PhoneKeypad.keys[r * 3 + c]
                            PhoneKeyButton(digit: k.digit, letters: k.letters) { number.append(k.digit) }
                        }
                    }
                }
            }
            .padding(.top, 18)

            ZStack {
                Button { link.dial(number) } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(Circle().fill(Color(nsColor: .systemGreen)))
                }
                .buttonStyle(.plain)
                .disabled(number.isEmpty || link.path(for: .makeCalls) == nil)
                .opacity(number.isEmpty || link.path(for: .makeCalls) == nil ? 0.45 : 1)
                .keyboardShortcut(.return, modifiers: [])
                .help("Call")
                .accessibilityLabel("Call")

                HStack {
                    Spacer()
                    Button { if !number.isEmpty { number.removeLast() } } label: {
                        Image(systemName: "delete.left.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(number.isEmpty ? 0 : 1)
                    .keyboardShortcut(.delete, modifiers: [])
                    .accessibilityLabel("Delete")
                }
                .frame(width: 66 * 3 + 44)
            }
            .padding(.top, 20)

            audioCaption
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            let c = press.characters
            if c.count == 1, "0123456789*#+".contains(c) { number.append(c); return .handled }
            return .ignored
        }
        .navigationTitle("Keypad")
        .onAppear(perform: takeNumber)
        .onChange(of: router.keypadNumber) { takeNumber() }
    }

    @ViewBuilder private var audioCaption: some View {
        if link.adbSerial != nil && callAudioOnMac {
            Label("Calls that you make here play on this Mac.", systemImage: "laptopcomputer")
        } else {
            Label("Call audio plays on the phone.", systemImage: "iphone")
        }
    }

    private func takeNumber() {
        if let n = router.keypadNumber { number = n; router.keypadNumber = nil }
    }
}

enum PhoneKeypad {
    static let keys: [(digit: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", ""),
    ]
}

struct PhoneKeyButton: View {
    let digit: String
    let letters: String
    var size: CGFloat = 66
    var digitSize: CGFloat = 28
    var letterSize: CGFloat = 9
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: -2) {
                Text(digit).font(.system(size: digitSize, weight: .regular))
                Text(letters.isEmpty ? " " : letters).font(.system(size: letterSize, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(digit)
    }
}

private struct CallAudioFooter: View {
    @EnvironmentObject private var link: PhoneLink
    @AppStorage(CallAudio.settingKey) private var onMac = true

    var body: some View {
        Group {
            if link.adbSerial == nil, !PhoneLink.isDemo {
                Text("To use this Mac for call audio, connect with USB or Wireless debugging.")
            } else if onMac {
                Text("Calls that you make or answer on this Mac play on this Mac.")
            } else {
                Text("Call audio plays on the phone.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        // No fixedSize: the split view can measure this column very narrow, and the text then grows so tall
        // that all columns move up under the toolbar.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
