import AppKit
import SwiftUI

/// Sets the corner radii: large on outer corners, small between cards.
enum CardPlace {
    case alone, top, middle, bottom

    var shape: UnevenRoundedRectangle {
        let big: CGFloat = 14, small: CGFloat = 4
        let top = self == .alone || self == .top ? big : small
        let bottom = self == .alone || self == .bottom ? big : small
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                      topTrailingRadius: top, style: .continuous)
    }
}

extension Color {
    /// Opaque, so the stack edges below do not show through.
    static let notificationCard = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor.blended(withFraction: 0.07, of: .white) ?? .windowBackgroundColor
            : .white
    })
}

/// A short age as in the Android notification shade: "now", "5m", "3h", "2d", then a date.
func shortAge(_ d: Date, now: Date = Date()) -> String {
    let s = max(0, now.timeIntervalSince(d))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86_400: return "\(Int(s / 3600))h"
    case ..<(7 * 86_400): return "\(Int(s / 86_400))d"
    default: return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct AgeText: View {
    let date: Date
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(shortAge(date, now: ctx.date))
                .accessibilityLabel(date.formatted(.relative(presentation: .named)))
        }
    }
}

struct NotificationAppIcon: View {
    let pkg: String
    var size: CGFloat = 16
    var body: some View {
        if PhoneLink.isDemo { DemoAppIcon(pkg: pkg, size: size) } else { AppIconView(pkg: pkg, size: size) }
    }
}

struct NotificationCard: View {
    let n: PhoneNotification
    let appName: String
    var place: CardPlace = .alone
    var stack: Int?
    let expanded: Bool
    let replying: Bool
    let focused: Bool
    let actions: [NotifAction]
    var onToggle: () -> Void
    var onDismiss: () -> Void
    var onAction: (NotifAction) -> Void
    var onReply: () -> Void
    var onSend: (String) -> Void
    var onCancelReply: () -> Void

    @State private var hover = false
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inGroup: Bool { place != .alone }
    private var open: Bool { expanded && stack == nil }
    private var shape: UnevenRoundedRectangle { place.shape }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .gesture(swipe)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(stack.map { "\($0) notifications. Shows all." } ?? (open ? "Collapses the notification." : "Shows the full notification."))
            if open, !actions.isEmpty {
                HStack(spacing: 2) {
                    ForEach(actions, id: \.index) { a in
                        CardActionButton(title: a.title) { a.reply ? onReply() : onAction(a) }
                    }
                }
                .padding(.leading, -8)
            }
            if open, replying {
                InlineReplyField(onSend: onSend, onCancel: onCancelReply)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, inGroup ? 10 : 11)
        .padding(.bottom, open && !actions.isEmpty ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.notificationCard))
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .overlay { if focused { shape.stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5) } }
        .background(alignment: .bottom) { if let stack, stack > 1 { StackEdges(count: stack) } }
        .overlay(alignment: .topLeading) {
            if hover, drag == 0 {
                CloseButton(help: stack == nil ? "Dismiss" : "Dismiss All from \(appName)", action: onDismiss)
                    .offset(x: -7, y: -7)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, stack.map { $0 > 2 ? 14 : 7 } ?? 0)
        .offset(x: drag)
        .opacity(1 - min(Double(abs(drag)) / 400, 0.7))
        .onHover { h in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hover = h } }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: stack == nil ? "Dismiss" : "Dismiss All", onDismiss)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !inGroup {
                HStack(spacing: 6) {
                    NotificationAppIcon(pkg: n.pkg, size: 16)
                    HStack(spacing: 4) {
                        Text(appName).fontWeight(.medium)
                        Text("·").accessibilityHidden(true)
                        AgeText(date: n.date)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    trailingControl
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if inGroup {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n.title ?? appName).font(.headline).lineLimit(open ? 3 : 1)
                        Spacer(minLength: 8)
                        AgeText(date: n.date).font(.subheadline).foregroundStyle(.secondary)
                        trailingControl.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    }
                } else if let t = n.title {
                    Text(t).font(.headline).lineLimit(open ? 3 : 1)
                }
                if let t = n.text {
                    Text(t)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(open ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var trailingControl: some View {
        if let stack {
            Button(action: onToggle) {
                HStack(spacing: 3) {
                    Text("\(stack)").monospacedDigit()
                    Image(systemName: "chevron.down")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show All")
            .accessibilityLabel("Show all \(stack) notifications")
        } else {
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(open ? "Collapse" : "Expand")
            .accessibilityLabel(open ? "Collapse" : "Expand")
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if abs(v.translation.width) > abs(v.translation.height) { drag = v.translation.width }
            }
            .onEnded { v in
                let far = abs(drag) > 120 || abs(v.predictedEndTranslation.width) > 300
                if far, drag != 0 {
                    let d = reduceMotion ? 0 : 0.16
                    withAnimation(reduceMotion ? nil : .easeOut(duration: d)) { drag = drag > 0 ? 640 : -640 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                        onDismiss()
                        // If the card stays (the dismiss failed), bring it back.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drag = 0 }
                    }
                } else {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { drag = 0 }
                }
            }
    }
}

struct NotificationGroupHeader: View {
    let pkg: String
    let appName: String
    let count: Int
    var onCollapse: () -> Void
    var onDismissAll: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            NotificationAppIcon(pkg: pkg, size: 16)
            Text(appName).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onCollapse) {
                HStack(spacing: 3) {
                    Text("\(count)").monospacedDigit()
                    Image(systemName: "chevron.up")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show Less")
            .accessibilityLabel("Show less")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(CardPlace.top.shape.fill(Color.notificationCard))
        .overlay(CardPlace.top.shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCollapse)
        .overlay(alignment: .topLeading) {
            if hover {
                CloseButton(help: "Dismiss All from \(appName)", action: onDismissAll).offset(x: -7, y: -7)
            }
        }
        .onHover { hover = $0 }
        .contextMenu { Button("Show Less", action: onCollapse); Divider(); Button("Dismiss All from \(appName)", action: onDismissAll) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(appName), \(count) notifications")
        .accessibilityAction(named: "Show Less", onCollapse)
        .accessibilityAction(named: "Dismiss All", onDismissAll)
    }
}

private struct StackEdges: View {
    let count: Int
    var body: some View {
        ZStack(alignment: .bottom) {
            if count > 2 { edge(0.1).padding(.horizontal, 24).offset(y: 14) }
            edge(0.05).padding(.horizontal, 12).offset(y: 7)
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }

    private func edge(_ shade: Double) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.notificationCard)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(shade)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

private struct CloseButton: View {
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CardActionButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(hover ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .onHover { hover = $0 }
    }
}

private struct InlineReplyField: View {
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Reply", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 5)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .help("Send")
            .accessibilityLabel("Send")
        }
        .padding(.leading, 12)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .padding(.bottom, 4)
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSend(t)
        text = ""
    }
}
