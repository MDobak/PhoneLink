import AppKit
import SwiftUI

struct Monogram: View {
    let name: String
    var size: CGFloat = 36

    private var initials: String? {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        guard !words.isEmpty else { return nil }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.joined()
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.65, green: 0.67, blue: 0.72), Color(red: 0.52, green: 0.54, blue: 0.58)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                if let initials {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.white)
                        .offset(y: size * 0.04)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AppIconView: View {
    let pkg: String
    var size: CGFloat = 20

    var body: some View {
        if let img = Notifier.shared.icon(for: pkg) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.quaternary)
                .overlay(Image(systemName: "app.badge").font(.system(size: size * 0.5)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
        }
    }
}

struct BatteryLabel: View {
    let level: Int?
    let charging: Bool

    var body: some View {
        if let level {
            HStack(spacing: 4) {
                Text("\(level)%").monospacedDigit()
                Image(systemName: batterySymbol(level: level, charging: charging)).symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(level <= 15 && !charging ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
        }
    }
}

func batterySymbol(level: Int, charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    switch level {
    case 88...: return "battery.100percent"
    case 63...: return "battery.75percent"
    case 38...: return "battery.50percent"
    case 13...: return "battery.25percent"
    default: return "battery.0percent"
    }
}

/// Some phones send the package name as the app name. Then use the apps list name or the last package part.
func appDisplayName(_ app: String, pkg: String) -> String {
    let looksLikePackage = !app.contains(" ") && app.contains(".") && app == app.lowercased()
    guard app.isEmpty || looksLikePackage else { return app }
    if let label = AppsModel.shared.apps.first(where: { $0.pkg == pkg })?.label, !label.isEmpty { return label }
    let last = pkg.split(separator: ".").last.map(String.init) ?? pkg
    return last.prefix(1).uppercased() + last.dropFirst()
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func listDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}

struct CallButton: View {
    enum Kind { case accept, decline }
    let kind: Kind
    var size: CGFloat = 36
    var label: String? = nil
    let action: () -> Void

    private var title: String { label ?? (kind == .accept ? "Answer" : "Decline") }

    var body: some View {
        Button(action: action) {
            Image(systemName: kind == .accept ? "phone.fill" : "phone.down.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(kind == .accept ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct LocalNetworkNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            Text("Phone Link needs local network access to find your phone.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Settings…") { PhoneLink.openLocalNetworkSettings() }
        }
    }
}

extension LinkState {
    var summary: String {
        switch self {
        case .idle: "Not connected"
        case .searching: "Looking for the phone…"
        case .connecting: "Connecting…"
        case .pairing: "Pairing"
        case .connected: "Connected"
        case .failed(let m): m
        }
    }
}
