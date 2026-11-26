import AppKit
import SwiftUI

// MARK: - Tiles

/// SF Symbols has no Bluetooth symbol.
struct BluetoothRune: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0, 0.27))
        path.addLine(to: p(1, 0.73))
        path.addLine(to: p(0.5, 1))
        path.addLine(to: p(0.5, 0))
        path.addLine(to: p(1, 0.27))
        path.addLine(to: p(0, 0.73))
        return path
    }
}

struct ControlGlyph: View {
    let control: QuickControl
    let symbol: String
    var size: CGFloat = 15

    var body: some View {
        if control.id == "bluetooth" {
            BluetoothRune()
                .stroke(style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.5, height: size * 1.0)
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
        }
    }
}

/// Neutral gray like Control Center buttons.
private struct OffFill: ShapeStyle {
    func resolve(in env: EnvironmentValues) -> Color {
        Color.primary.opacity(env.colorScheme == .dark ? 0.16 : 0.09)
    }
}

struct ControlTile: View {
    let control: QuickControl
    /// False for the Settings preview.
    var interactive = true
    @ObservedObject private var model = QuickControls.shared
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var agent = AdbAgent.shared
    @ObservedObject private var pins = ControlPins.shared

    var body: some View {
        let t = model.tile(control)
        Button { model.perform(control) } label: {
            ControlGlyph(control: control, symbol: t.symbol)
        }
        .buttonStyle(ControlTileStyle(title: t.title, on: t.on, available: t.unavailable == nil, interactive: interactive))
        .allowsHitTesting(interactive)
        .help(interactive ? t.help : "")
        .contextMenu { if interactive { menu(t) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(control.title)
        .accessibilityValue(t.value ?? "")
        .accessibilityHint(t.unavailable ?? "")
        .accessibilityAddTraits(control.kind == .toggle ? .isToggle : .isButton)
    }

    @ViewBuilder private func menu(_ t: QuickControls.Tile) -> some View {
        if control.kind == .ringer, t.unavailable == nil {
            Picker("Sound Mode", selection: Binding(get: { model.value("ringer")?.mode ?? .normal }, set: { model.setRinger($0) })) {
                ForEach(RingerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
        }
        Button("Remove from Menu") { pins.remove(control.id) }
        Button("Edit Controls…") { Router.shared.showSettings("controls") }
    }
}

private struct ControlTileStyle: ButtonStyle {
    let title: String
    let on: Bool
    let available: Bool
    let interactive: Bool

    func makeBody(configuration: Configuration) -> some View {
        ControlTileBody(label: configuration.label, title: title, on: on, available: available,
                        interactive: interactive, pressed: configuration.isPressed)
    }
}

private struct ControlTileBody<Label: View>: View {
    let label: Label
    let title: String
    let on: Bool
    let available: Bool
    let interactive: Bool
    let pressed: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            label
                .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .frame(width: 38, height: 38)
                .background(Circle().fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(OffFill())))
                .overlay(Circle().fill(Color.black.opacity(pressed && available ? 0.15 : 0)))
                .animation(.easeOut(duration: 0.15), value: on)
            Text(title)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .opacity(available ? 1 : 0.4)
        .padding(.top, 6)
        .padding(.bottom, 5)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover && interactive ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct ControlsGrid: View {
    let controls: [QuickControl]
    var interactive = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
            ForEach(controls) { ControlTile(control: $0, interactive: interactive) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phone Controls")
    }
}

struct MenuControlsSection: View {
    @ObservedObject private var model = QuickControls.shared
    @ObservedObject private var pins = ControlPins.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ControlsGrid(controls: pins.controls)
                .padding(.horizontal, 10)
            if let s = model.status {
                Label(s, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.status)
    }
}

// MARK: - Sound

struct MenuSoundSection: View {
    @ObservedObject private var model = QuickControls.shared
    @ObservedObject private var link = PhoneLink.shared
    @State private var expanded = PhoneLink.isDemo ? ProcessInfo.processInfo.environment["PHONELINK_DEMO_SOUND"] == "expanded"
        : UserDefaults.standard.bool(forKey: "menuSoundExpanded")

    private var main: VolumeStream { link.call != nil && model.volume(.call) != nil ? .call : .media }
    private var extras: [VolumeStream] {
        let list: [VolumeStream] = main == .call ? [.media, .ring, .notification, .alarm] : [.ring, .notification, .alarm]
        return list.filter { model.volume($0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(main == .call ? "Call Volume" : "Sound")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if !extras.isEmpty { chevron }
            }
            if model.volume(main) != nil {
                VolumeSlider(stream: main, label: nil)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(extras) { VolumeSlider(stream: $0, label: $0.title) }
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
    }

    private var chevron: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            if !PhoneLink.isDemo { UserDefaults.standard.set(expanded, forKey: "menuSoundExpanded") }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Show Fewer Sliders" : "Show More Sliders")
        .accessibilityLabel(expanded ? "Show fewer sliders" : "Show more sliders")
    }
}

/// Mimics the Control Center Sound slider. Phone updates do not move it while dragging.
/// Sends volume.set at most every 120 ms, plus the final value.
struct VolumeSlider: View {
    let stream: VolumeStream
    let label: String?
    @ObservedObject private var model = QuickControls.shared
    @State private var drag: Double?
    @State private var editing = false
    @State private var lastSent = Date.distantPast
    @State private var sentLevel: Int?
    @State private var trailing: DispatchWorkItem?

    var body: some View {
        if let v = model.volume(stream) {
            let value = drag ?? Double(v.level)
            VStack(alignment: .leading, spacing: 4) {
                if let label {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                CapsuleSlider(value: value, range: Double(v.min)...Double(max(v.max, v.min + 1)),
                              symbol: symbol(value, v), height: label == nil ? 22 : 18,
                              onChange: { editing = true; changed($0, v) },
                              onEnd: { editing = false; finish(v) })
                    .accessibilityRepresentation {
                        Slider(value: Binding(get: { value }, set: { changed($0.rounded(), v); finishSoon(v) }),
                               in: Double(v.min)...Double(max(v.max, v.min + 1)), step: 1)
                            .accessibilityLabel(accessibilityName)
                    }
            }
            .help(accessibilityName)
        }
    }

    private var accessibilityName: String {
        label.map { "\($0) volume" } ?? (stream == .call ? "Call volume" : "Media volume")
    }

    private func symbol(_ value: Double, _ v: QuickControls.Volume) -> String {
        let span = Double(max(v.max - v.min, 1))
        let f = (value - Double(v.min)) / span
        switch stream {
        case .media where label == nil, .call where label == nil:
            if f <= 0 { return "speaker.slash.fill" }
            return f < 0.34 ? "speaker.wave.1.fill" : f < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .call: return "phone.fill"
        case .media: return "music.note"
        case .ring: return f <= 0 ? "bell.slash.fill" : "bell.fill"
        case .notification: return "bell.badge.fill"
        case .alarm: return "alarm.fill"
        }
    }

    private func changed(_ x: Double, _ v: QuickControls.Volume) {
        drag = x
        let level = Int(x.rounded())
        guard level != sentLevel else { return }
        trailing?.cancel()
        let wait = 0.12 - Date().timeIntervalSince(lastSent)
        if wait <= 0 {
            send(level)
        } else {
            let w = DispatchWorkItem { send(level) }
            trailing = w
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
        }
    }

    /// Key or VoiceOver changes have no drag end, so end the local value soon.
    private func finishSoon(_ v: QuickControls.Volume) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !editing { finish(v) } }
    }

    private func finish(_ v: QuickControls.Volume) {
        trailing?.cancel()
        trailing = nil
        if let d = drag {
            let level = Int(d.rounded())
            if level != sentLevel { send(level) }
        }
        drag = nil
        sentLevel = nil
    }

    private func send(_ level: Int) {
        lastSent = Date()
        sentLevel = level
        model.setVolume(stream, level)
    }
}

private struct CapsuleSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let symbol: String
    let height: CGFloat
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = range.upperBound - range.lowerBound
            let f = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let x = height / 2 + f * (w - height)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.18 : 0.15))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                Capsule()
                    .fill(Color.white.opacity(enabled ? 1 : 0.6))
                    .frame(width: x + height / 2)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: height, height: height)
                    .offset(x: x - height / 2)
                Image(systemName: symbol)
                    .font(.system(size: max(10, height * 0.5), weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.5))
                    .frame(width: height + 4, height: height)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    let p = min(max((d.location.x - height / 2) / max(w - height, 1), 0), 1)
                    onChange((range.lowerBound + p * span).rounded())
                }
                .onEnded { _ in onEnd() })
        }
        .frame(height: height)
        .focusable()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    private func step(_ d: Double) {
        let n = min(max(value.rounded() + d, range.lowerBound), range.upperBound)
        guard n != value else { return }
        onChange(n)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onEnd() }
    }
}

// MARK: - Settings > Controls

struct ControlsSettings: View {
    @ObservedObject private var pins = ControlPins.shared
    @ObservedObject private var model = QuickControls.shared
    @ObservedObject private var link = PhoneLink.shared
    @AppStorage("menuShowsSound") private var showSound = true
    @State private var dragging: String?

    var body: some View {
        Form {
            Section {
                preview
            }
            Section {
                ForEach(pins.controls) { c in
                    ControlSettingsRow(control: c, pinned: true, canAdd: false)
                        .onDrag {
                            dragging = c.id
                            return NSItemProvider(object: c.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: PinDropDelegate(target: c.id, dragging: $dragging))
                        .contextMenu {
                            Button("Move Up") { pins.move(c.id, by: -1) }.disabled(pins.ids.first == c.id)
                            Button("Move Down") { pins.move(c.id, by: 1) }.disabled(pins.ids.last == c.id)
                            Divider()
                            Button("Remove from Menu") { pins.remove(c.id) }
                        }
                }
                if pins.ids.isEmpty {
                    Text("No controls in the menu.").foregroundStyle(.secondary)
                }
            } header: {
                Text("In Menu")
            } footer: {
                Text("Up to \(QuickControl.maxPins) controls. Drag to change the order.")
                    .settingsFooter()
            }
            if !pins.others.isEmpty {
                Section {
                    ForEach(pins.others) { c in
                        ControlSettingsRow(control: c, pinned: false, canAdd: !pins.isFull)
                    }
                } header: {
                    Text("More Controls")
                }
            }
            Section {
                Toggle("Show sound in menu", isOn: $showSound)
            } header: {
                Text("Sound")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset to Default") {
                        pins.reset()
                        showSound = true
                    }
                    .disabled(pins.ids == QuickControl.defaultPins && showSound)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 640)
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var preview: some View {
        if pins.ids.isEmpty {
            Text("The menu shows no controls.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ControlsGrid(controls: pins.controls, interactive: false)
                .frame(width: 280)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityLabel("Preview of the controls in the menu")
        }
    }
}

private struct PinDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { ControlPins.shared.move(d, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct ControlSettingsRow: View {
    let control: QuickControl
    let pinned: Bool
    let canAdd: Bool
    @ObservedObject private var model = QuickControls.shared
    @ObservedObject private var pins = ControlPins.shared

    var body: some View {
        let reason = model.unavailableReason(control)
        HStack(spacing: 10) {
            if pinned {
                Button { withAnimation { pins.remove(control.id) } } label: {
                    Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Remove from Menu")
                .accessibilityLabel("Remove \(control.title) from the menu")
            } else {
                Button { withAnimation { pins.add(control.id) } } label: {
                    Image(systemName: "plus.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, canAdd ? Color.green : Color.secondary.opacity(0.5))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .help(canAdd ? "Add to Menu" : "The menu is full. Remove a control first.")
                .accessibilityLabel("Add \(control.title) to the menu")
            }
            ControlGlyph(control: control, symbol: control.symbol, size: 11)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(control.title)
                if let reason {
                    Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if pinned {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("Drag to change the order")
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if pinned {
                Button("Move Up") { pins.move(control.id, by: -1) }
                Button("Move Down") { pins.move(control.id, by: 1) }
                Button("Remove from Menu") { pins.remove(control.id) }
            } else if canAdd {
                Button("Add to Menu") { pins.add(control.id) }
            }
        }
    }
}

// MARK: - Window visibility

/// Lets the menu bar window poll the phone only while it is open.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let v = VisibilityView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: VisibilityView, context: Context) { v.onChange = onChange }

    static func dismantleNSView(_ v: VisibilityView, coordinator: ()) { v.onChange?(false) }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let w = window else { report(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] note in
                    guard let self else { return }
                    if note.name == NSWindow.willCloseNotification { self.report(false); return }
                    // The occlusion state can change a moment after the key state.
                    self.check()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.check() }
                })
            }
            check()
        }

        private func check() {
            guard let w = window else { report(false); return }
            report(w.isVisible && w.occlusionState.contains(.visible))
        }

        private func report(_ on: Bool) {
            guard on != last else { return }
            last = on
            onChange?(on)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
