import SwiftUI

struct ActiveCallView: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var audio = CallAudio.shared
    @ObservedObject private var recorder = CallRecorder.shared
    /// Show the recording law notice only once.
    @AppStorage(CallRecorder.disclosureKey) private var recordingDisclosureShown = false
    @State private var showRecordingDisclosure = false
    let call: CallInfo
    @State private var showKeypad = false
    @State private var sentKeys = ""

    private var ringing: Bool { call.state == "ringing" }
    /// The number shows under the name only when the phone knows the name.
    private var subtitle: String? {
        guard call.name != nil, let n = call.number, !n.isEmpty else { return nil }
        return n
    }
    private var canControlAudio: Bool { audio.offered && audio.callActive }
    /// Phone keys work only while the call audio plays on this Mac.
    private var canSendKeys: Bool { audio.audioOnMac && !ringing }

    private func toggleRecording() {
        if recorder.recording { recorder.stop(); return }
        guard audio.audioOnMac else { return }
        if recordingDisclosureShown { recorder.start(title: call.title) } else { showRecordingDisclosure = true }
    }

    private func press(_ key: String) {
        guard canSendKeys else { return }
        sentKeys.append(key)
        audio.sendKeys(key)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Monogram(name: call.name ?? "", size: showKeypad ? 56 : 88)
            Text(call.title)
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
                .padding(.top, 16)
                .padding(.horizontal, 24)
            if let subtitle {
                Text(subtitle).font(.title3).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled).padding(.top, 2)
            }
            status
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            audioStatus
                .font(.callout)
                .foregroundStyle(audio.error != nil && !ringing ? .secondary : .tertiary)
                .padding(.top, 10)
                .padding(.horizontal, 24)
                .multilineTextAlignment(.center)

            controls.padding(.top, 32)

            if !recorder.recording, recorder.lastFile != nil {
                Button("Show Recording in Finder") { recorder.showInFinder() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 12)
            }

            if showKeypad && canSendKeys {
                CallKeypad(sent: sentKeys, press: press).padding(.top, 24)
            } else if canControlAudio, audio.route == .mac {
                Form {
                    AudioDevicePicker("Microphone", input: true)
                    AudioDevicePicker("Speaker", input: false)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(width: 340, height: 110)
                .padding(.top, 20)
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(ringing ? "Incoming Call" : "Call")
        .animation(.default, value: audio.route)
        .animation(.default, value: showKeypad)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { k in
            let c = k.characters
            guard canSendKeys, c.count == 1, "0123456789*#".contains(c) else { return .ignored }
            showKeypad = true
            press(c)
            return .handled
        }
        .onChange(of: canSendKeys) { _, can in if !can { showKeypad = false } }
        .alert("Tell the Other Person", isPresented: $showRecordingDisclosure) {
            Button("Record") {
                recordingDisclosureShown = true
                recorder.start(title: call.title)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In some places, the law requires you to tell the other person, or to get their consent, before you record a call.")
        }
        .alert("Can’t Record the Call", isPresented: Binding(get: { recorder.error != nil }, set: { if !$0 { recorder.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.error ?? "")
        }
    }

    @ViewBuilder private var recordControl: some View {
        if recorder.recording, let start = recorder.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                RoundControl(symbol: "record.circle.fill", on: true,
                             label: Duration.seconds(max(0, ctx.date.timeIntervalSince(start)).rounded())
                                .formatted(.time(pattern: .minuteSecond)),
                             help: "Stop Recording", tint: .red) { toggleRecording() }
            }
        } else {
            RoundControl(symbol: "record.circle", on: false, label: "Record",
                         help: audio.audioOnMac ? "Record the Call" : "Switch the call to this Mac to record it.",
                         disabled: !audio.audioOnMac) { toggleRecording() }
        }
    }

    @ViewBuilder private var status: some View {
        if ringing {
            Text("Incoming Call")
        } else if let start = link.callStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(start)).rounded()), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
            }
        } else {
            Text("On Call")
        }
    }

    @ViewBuilder private var audioStatus: some View {
        if !ringing, let e = audio.error {
            Label(e, systemImage: "exclamationmark.triangle")
        } else if audio.audioOnMac {
            Label("Audio on This Mac", systemImage: "laptopcomputer")
        } else if canControlAudio && audio.route == .mac {
            Label("Connecting Audio…", systemImage: "laptopcomputer")
        } else if !ringing {
            Label("Audio on Phone", systemImage: "iphone")
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(alignment: .top, spacing: 28) {
            if ringing {
                LabeledCallButton(label: "Decline") { CallButton(kind: .decline, size: 60) { link.hangUp() } }
                if link.path(for: .answerCalls) != nil {
                    LabeledCallButton(label: "Accept") { CallButton(kind: .accept, size: 60) { link.answer() } }
                }
            } else {
                if canControlAudio {
                    RoundControl(symbol: audio.micMuted ? "mic.slash.fill" : "mic.fill", on: audio.micMuted,
                                 label: "Mute", disabled: audio.route != .mac) { audio.toggleMute() }
                    RoundControl(symbol: "circle.grid.3x3.fill", on: showKeypad, label: "Keypad",
                                 help: canSendKeys ? "Keypad" : "To use the keypad, play the call audio on this Mac.",
                                 disabled: !canSendKeys) { showKeypad.toggle() }
                    recordControl
                    RoundControl(symbol: audio.route == .mac ? "laptopcomputer" : "iphone", on: audio.route == .mac,
                                 label: audio.route == .mac ? "This Mac" : "Phone",
                                 help: audio.route == .mac ? "Use Phone for Audio" : "Use This Mac for Audio") {
                        audio.setRoute(audio.route == .mac ? .phone : .mac)
                    }
                }
                if link.call?.internet != true, link.path(forType: "call.end") != nil {
                    LabeledCallButton(label: "End") { CallButton(kind: .decline, size: 60, label: "End Call") { link.hangUp() } }
                }
            }
        }
    }
}

private struct LabeledCallButton<B: View>: View {
    let label: String
    @ViewBuilder let button: () -> B

    var body: some View {
        VStack(spacing: 8) {
            button()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

private struct RoundControl: View {
    let symbol: String
    let on: Bool
    let label: String
    var help: String? = nil
    var disabled = false
    /// Nil uses the primary color.
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(on ? (tint != nil ? Color.white : Color(nsColor: .windowBackgroundColor)) : Color.primary)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(on ? (tint ?? Color.primary) : Color.primary.opacity(hover ? 0.16 : 0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(help ?? label)
            Text(label).font(.callout).foregroundStyle((on ? tint : nil).map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)).monospacedDigit()
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help ?? label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct CallKeypad: View {
    let sent: String
    let press: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(sent.isEmpty ? " " : String(sent.suffix(18)))
                .font(.system(size: 24))
                .monospacedDigit()
                .lineLimit(1)
                .frame(height: 30)
                .accessibilityLabel(sent.isEmpty ? "No keys sent" : "Sent keys: \(sent)")
            Grid(horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(0..<4) { r in
                    GridRow {
                        ForEach(0..<3) { c in
                            let k = PhoneKeypad.keys[r * 3 + c]
                            PhoneKeyButton(digit: k.digit, letters: k.letters, size: 56, digitSize: 24, letterSize: 8) { press(k.digit) }
                        }
                    }
                }
            }
        }
    }
}
