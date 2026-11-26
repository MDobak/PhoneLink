import AVFoundation
import AppKit
import CoreMedia
import SwiftUI

// MARK: - H.264 decoding

/// Turns the Annex B stream from the phone into sample buffers for AVSampleBufferDisplayLayer.
final class H264Renderer {
    let layer = AVSampleBufferDisplayLayer()
    private(set) var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    var onNeedKeyFrame: (() -> Void)?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    static func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var units: [Data] = []
        var start = -1
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, b[end - 1] == 0 { end -= 1 }
                    units.append(Data(b[start..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < b.count { units.append(Data(b[start...])) }
        return units
    }

    func handle(flags: UInt8, data: Data) {
        var frame: [Data] = []
        for nal in Self.nalUnits(data) where !nal.isEmpty {
            switch nal[nal.startIndex] & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            case 9: break // access unit delimiter
            default: frame.append(nal)
            }
        }
        if flags & 1 != 0 || format == nil { makeFormat() }
        guard let format, !frame.isEmpty, let sample = Self.sample(nals: frame, format: format) else { return }
        Self.setFlag(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
        let r = layer.sampleBufferRenderer
        if r.status == .failed {
            r.flush()
            onNeedKeyFrame?()
            return
        }
        r.enqueue(sample)
    }

    /// One sample with length-prefixed NAL units. Without `pts` the sample has no timing.
    static func sample(nals: [Data], format: CMVideoFormatDescription, pts: CMTime? = nil) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts ?? .invalid, decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: pts == nil ? 0 : 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// Sets a boolean sample attachment, such as kCMSampleAttachmentKey_NotSync, to true.
    static func setFlag(_ key: CFString, on sample: CMSampleBuffer) {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(atts) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    private func makeFormat() {
        guard let sps, let pps else { return }
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        if status == noErr, let fmt, fmt != format {
            format = fmt
            layer.sampleBufferRenderer.flush()
        }
    }
}

// MARK: - Input view

/// Shows the video and turns mouse and keyboard input into phone gestures and keys.
final class PhoneScreenNSView: NSView {
    let renderer: H264Renderer
    var send: (JSON) -> Void = { _ in }
    let tracksLockEntry: Bool
    /// The phone has a finger down while true.
    private var touching = false
    private var lastTouch: (Double, Double) = (0, 0)
    private var pendingMove: (Double, Double)?
    private var lastMoveTime: TimeInterval = 0
    private var moveScheduled = false
    private var scrollDelta = CGSize.zero
    private var scrollPoint: (Double, Double) = (0, 0)
    private var scrollLines = false
    private var lastScrollTime: TimeInterval = 0
    private var scrollScheduled = false
    /// A shorter interval only adds traffic.
    private static let sendInterval: TimeInterval = 0.008

    init(renderer: H264Renderer) {
        self.renderer = renderer
        tracksLockEntry = renderer === ScreenSession.shared.renderer
        super.init(frame: .zero)
        wantsLayer = true
        claimVideo()
    }

    convenience init() {
        self.init(renderer: ScreenSession.shared.renderer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Views of one renderer share its single layer. The newest view in a window takes it, so it shows the stream at once.
    private func claimVideo() {
        guard let l = layer, renderer.layer.superlayer !== l else { return }
        l.addSublayer(renderer.layer)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { claimVideo() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if renderer.layer.superlayer === layer { renderer.layer.frame = bounds }
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    private func norm(_ e: NSEvent) -> (Double, Double) {
        let p = convert(e.locationInWindow, from: nil)
        return (min(max(p.x / bounds.width, 0), 1), min(max(p.y / bounds.height, 0), 1))
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func sendTouch(_ action: String, _ p: (Double, Double)) {
        lastTouch = p
        send(["t": "input.touch", "action": action, "x": p.0, "y": p.1])
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if touching { cancelTouch() }
        touching = true
        pendingMove = nil
        lastMoveTime = now
        sendTouch("down", norm(e))
    }

    override func mouseDragged(with e: NSEvent) {
        guard touching else { return }
        let p = norm(e)
        if abs(p.0 - lastTouch.0) + abs(p.1 - lastTouch.1) < 0.0005 { pendingMove = nil; return }
        pendingMove = p
        let wait = Self.sendInterval - (now - lastMoveTime)
        if wait <= 0 {
            flushMove()
        } else if !moveScheduled {
            // Send the newest position when the interval ends, even if the mouse stops.
            moveScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.moveScheduled = false
                self?.flushMove()
            }
        }
    }

    private func flushMove() {
        guard touching, let p = pendingMove else { return }
        pendingMove = nil
        lastMoveTime = now
        sendTouch("move", p)
    }

    override func mouseUp(with e: NSEvent) {
        guard touching else { return }
        let p = norm(e)
        if abs(p.0 - lastTouch.0) + abs(p.1 - lastTouch.1) >= 0.0005 { pendingMove = p }
        flushMove()
        touching = false
        sendTouch("up", p)
    }

    /// Lifts the finger without a tap, e.g. when the view closes mid-drag.
    private func cancelTouch() {
        guard touching else { return }
        touching = false
        pendingMove = nil
        sendTouch("cancel", lastTouch)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelTouch() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func rightMouseDown(with e: NSEvent) { send(["t": "input.global", "action": "back"]) }

    /// Precise deltas (trackpad, Magic Mouse) are fractions of the screen size. Wheel deltas are lines.
    override func scrollWheel(with e: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let lines = !e.hasPreciseScrollingDeltas
        if lines != scrollLines, scrollDelta != .zero { flushScroll() }
        scrollLines = lines
        scrollPoint = norm(e)
        if lines {
            scrollDelta.width += e.scrollingDeltaX
            scrollDelta.height += e.scrollingDeltaY
        } else {
            scrollDelta.width += e.scrollingDeltaX / bounds.width
            scrollDelta.height += e.scrollingDeltaY / bounds.height
        }
        let wait = Self.sendInterval - (now - lastScrollTime)
        if wait <= 0 {
            flushScroll()
        } else if !scrollScheduled {
            scrollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.scrollScheduled = false
                self?.flushScroll()
            }
        }
    }

    private func flushScroll() {
        guard scrollDelta != .zero else { return }
        lastScrollTime = now
        var m: JSON = ["t": "input.scroll", "x": scrollPoint.0, "y": scrollPoint.1,
                       "dx": Double(scrollDelta.width), "dy": Double(scrollDelta.height)]
        if scrollLines { m["lines"] = true }
        scrollDelta = .zero
        send(m)
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        let lock: LockEntry? = tracksLockEntry && PhoneLink.shared.phoneLocked ? LockEntry.shared : nil
        if cmd {
            switch e.charactersIgnoringModifiers {
            case "v":
                if let s = NSPasteboard.general.string(forType: .string) {
                    send(["t": "input.text", "text": s])
                    lock?.add(s.count)
                }
            case "a": send(["t": "input.key", "key": "select_all"])
            case "c": send(["t": "input.key", "key": "copy"])
            case "x": send(["t": "input.key", "key": "cut"])
            case "[": send(["t": "input.global", "action": "back"])
            default: super.keyDown(with: e)
            }
            return
        }
        switch e.keyCode {
        case 51:
            send(["t": "input.key", "key": "backspace"])
            lock?.add(-1)
        case 117:
            send(["t": "input.key", "key": "delete"])
            lock?.add(-1)
        case 36, 76:
            send(["t": "input.key", "key": "enter"])
            lock?.reset(after: 0.3) // the phone checks the PIN
        case 53:
            send(["t": "input.global", "action": "back"])
            lock?.reset()
        case 123: send(["t": "input.key", "key": "left"])
        case 124: send(["t": "input.key", "key": "right"])
        default:
            if let s = e.characters, !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) {
                send(["t": "input.text", "text": s])
                lock?.add(s.count)
            }
        }
    }
}

/// Android hides the PIN pad from screen sharing, so the Mac shows estimated dots instead.
final class LockEntry: ObservableObject {
    static let shared = LockEntry()
    @Published var count = 0
    private var pendingReset: DispatchWorkItem?

    func add(_ n: Int) {
        pendingReset?.cancel()
        pendingReset = nil
        count = max(0, count + n)
    }

    func reset(after delay: TimeInterval = 0) {
        pendingReset?.cancel()
        pendingReset = nil
        guard delay > 0 else {
            if count != 0 { count = 0 }
            return
        }
        let w = DispatchWorkItem { [weak self] in self?.count = 0 }
        pendingReset = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

private struct PhoneScreenRepresentable: NSViewRepresentable {
    let link: PhoneLink

    func makeNSView(context: Context) -> PhoneScreenNSView {
        let v = PhoneScreenNSView()
        v.send = { [weak link] in link?.input($0) }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: PhoneScreenNSView, context: Context) {}
}

/// Stops screen sharing shortly after the last view closes, so moving the screen between windows does not restart it.
final class ScreenSession {
    static let shared = ScreenSession()
    let renderer = H264Renderer()
    private var viewers = 0
    private var pendingStop: DispatchWorkItem?

    private init() {
        renderer.onNeedKeyFrame = { DispatchQueue.main.async { PhoneLink.shared.requestKeyFrame() } }
    }

    func acquire() {
        let link = PhoneLink.shared
        viewers += 1
        pendingStop?.cancel()
        pendingStop = nil
        let r = renderer
        link.videoSink = { flags, data in
            r.handle(flags: flags, data: data)
            ScreenRecorder.shared.video(data, format: r.format)
        }
        guard viewers == 1 else { return }
        switch link.screen {
        case .streaming: link.requestKeyFrame()
        case .waiting: break
        case .stopped: link.startScreen()
        }
    }

    func release() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        let w = DispatchWorkItem {
            ScreenRecorder.shared.stop()
            PhoneLink.shared.stopScreen()
            PhoneLink.shared.videoSink = nil
            LockEntry.shared.reset()
        }
        pendingStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

// MARK: - Screen views

extension PhoneLink {
    var screenAspect: CGFloat {
        if case let .streaming(w, h) = screen, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 1440.0 / 3120.0
    }

    var isStreaming: Bool {
        if case .streaming = screen { return true }
        return false
    }
}

struct PhoneScreenSurface: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var features = PhoneFeatures.shared
    @ObservedObject private var lock = LockEntry.shared
    @State private var apkTargeted = false
    @State private var installError: String?

    var body: some View {
        PhoneScreenRepresentable(link: link)
            .overlay { overlay }
            .background(Color.black)
            // Installing dropped APKs needs the debugging link.
            .dropDestination(for: URL.self) { urls, _ in
                guard features.available(.installApps), urls.contains(where: AppsModel.isApk) else { return false }
                AppsModel.shared.install(urls: urls) { installError = $0 }
                return true
            } isTargeted: { apkTargeted = $0 && features.available(.installApps) }
            .overlay {
                if apkTargeted {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) { InstallProgressOverlay().allowsHitTesting(false) }
            .overlay { ScreenCaptureOverlay() }
            .alert("The App Could Not Be Installed",
                   isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
                Button("OK") { installError = nil }
            } message: {
                Text(installError ?? "")
            }
            .onAppear { ScreenSession.shared.acquire() }
            .onDisappear { ScreenSession.shared.release() }
            .onChange(of: link.phoneLocked) { _, locked in if !locked { lock.reset() } }
            .onChange(of: link.isStreaming) { _, on in
                if !on {
                    lock.reset()
                    ScreenRecorder.shared.stop()
                }
            }
    }

    @ViewBuilder private var overlay: some View {
        switch link.screen {
        case .streaming:
            if link.phoneLocked {
                ZStack {
                    PinDots(count: lock.count)
                    LockHint(typing: lock.count > 0)
                }
            }
        case .waiting(let msg):
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular).tint(.white)
                Text(msg).font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        case .stopped(let msg):
            VStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.slash").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.6))
                Text(msg ?? "Screen sharing stopped").font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                Button("Share Screen Again") { link.startScreen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.state != .connected)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }
}

/// Android hides the PIN pad from screen sharing, but key presses still reach it.
private struct LockHint: View {
    var typing = false

    var body: some View {
        VStack {
            Spacer()
            Label {
                Text(typing ? "Press Return to unlock."
                     : "The phone hides its keypad. Type your PIN or password, then press Return.")
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(14)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct PinDots: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let maxDots = 16

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                Text("PIN")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 10) {
                    ForEach(0..<min(count, maxDots), id: \.self) { _ in
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                    if count > maxDots {
                        Text("+\(count - maxDots)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 16)
            }
            .opacity(count > 0 ? 1 : 0)
            .frame(maxWidth: .infinity)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.3), value: count)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(count) characters typed")
        .accessibilityHidden(count == 0)
    }
}

/// Shown only while the screen is shared, but always keeps its space.
private struct PhoneNavBar: View {
    static let height: CGFloat = 36
    @EnvironmentObject private var link: PhoneLink

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.backward", "Back", "back")
            button("circle", "Home", "home")
            button("square.on.square", "Recent Apps", "recents")
        }
        .frame(height: Self.height)
        .opacity(link.isStreaming ? 1 : 0)
        .allowsHitTesting(link.isStreaming)
        .accessibilityHidden(!link.isStreaming)
        .animation(.easeInOut(duration: 0.2), value: link.isStreaming)
    }

    private func button(_ symbol: String, _ label: String, _ action: String) -> some View {
        Button { link.input(["t": "input.global", "action": action]) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
        .frame(maxWidth: .infinity)
    }
}

struct ScreenPane: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if router.screenDetached {
                ContentUnavailableView {
                    Label("Shown in a Separate Window", systemImage: "macwindow")
                } actions: {
                    Button("Show in This Window") { dismissWindow(id: "screen") }
                }
                .onAppear { router.closeScreenWindow = { dismissWindow(id: "screen") } }
            } else if link.state != .connected && !link.isStreaming {
                NotConnectedView()
            } else {
                // The bar has the same width as the screen.
                GeometryReader { geo in
                    let aspect = link.screenAspect
                    let h = max(0, min(geo.size.height - PhoneNavBar.height, geo.size.width / aspect))
                    VStack(spacing: 0) {
                        PhoneScreenSurface()
                            .frame(width: h * aspect, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        PhoneNavBar()
                            .frame(width: h * aspect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(24)
            }
        }
        .navigationTitle(link.phoneName.isEmpty ? "Phone Screen" : link.phoneName)
        .toolbar {
            if !router.screenDetached {
                ToolbarItemGroup { ScreenCaptureButtons() }
                ToolbarItem {
                    Button { router.detachScreen() } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
                        .help("Open the phone screen in a new window")
                        .disabled(link.state != .connected)
                }
            }
        }
    }
}

struct ScreenControls: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var features = PhoneFeatures.shared
    @EnvironmentObject private var router: Router
    @AppStorage("screenQuality") private var quality = ScreenQuality.high.rawValue
    @AppStorage("screenSound") private var sound = true
    @AppStorage("screenOff") private var screenOff = false

    var body: some View {
        List {
            Section("Phone") {
                row("Notification Shade", "bell") { global("notifications") }
                row("Wake Phone", "sun.max") { link.input(["t": "input.wake"]) }
                row("Lock Phone", "lock") { global("lock") }
            }
            .disabled(link.state != .connected)
            Section("Window") {
                if router.screenDetached {
                    row("Show in This Window", "macwindow") { router.closeScreenWindow?() }
                } else {
                    row("Open in New Window", "macwindow.badge.plus") { router.detachScreen() }
                        .disabled(link.state != .connected)
                }
                // Need USB or Wireless debugging.
                if features.available(.appWindows) {
                    row("Open App in Window…", "app.badge") { router.appPicker = true }
                        .help("Show one phone app in its own window")
                    row("Open Phone Desktop", "rectangle.on.rectangle") { router.openDesktop() }
                        .help("Show a phone home screen in its own window. It also works while the phone is locked.")
                }
            }
            Section {
                Toggle("Play Sound on Mac", isOn: $sound)
                    .toggleStyle(.checkbox)
                    .onChange(of: sound) { _, on in link.setScreenSound(on) }
                    .help("Sound from apps and games plays on the Mac.")
                // The phone can keep its screen dark only when sharing through Android debugging.
                if features.path(.screen) == .shell {
                    Toggle("Keep Phone Screen Off", isOn: Binding(get: { screenOff }, set: { link.setScreenOff($0) }))
                        .toggleStyle(.checkbox)
                        .help("The phone stays dark while you use it from the Mac.")
                }
            } header: {
                Text("Options")
            }
            Section("Quality") {
                Picker("Quality", selection: $quality) {
                    ForEach(ScreenQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Phone Screen")
    }

    private func global(_ a: String) { link.input(["t": "input.global", "action": a]) }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = AppsModel.shared
    @ObservedObject private var agent = AdbAgent.shared
    @State private var query = ""
    @State private var selection: String?

    private var apps: [PhoneApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = model.apps.filter(\.launchable)
        guard !q.isEmpty else { return list }
        return list.filter { $0.label.localizedCaseInsensitiveContains(q) || $0.pkg.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open App in Window").font(.headline)
                Text("The app runs on its own display, apart from the phone screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SearchField(text: $query, prompt: "Search Apps")
            }
            .padding(20)

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(20)
        }
        .frame(width: 420, height: 520)
        .onAppear { model.loadIfNeeded() }
        .onChange(of: query) { _, _ in
            if let s = selection, !apps.contains(where: { $0.pkg == s }) { selection = nil }
        }
    }

    @ViewBuilder private var content: some View {
        if model.apps.isEmpty && (!agent.ready || model.loading || !model.loaded) {
            ProgressView()
        } else if model.apps.isEmpty {
            ContentUnavailableView {
                Label("Apps Not Available", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The phone did not send the list of apps.")
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else if apps.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(apps, selection: $selection) { app in
                HStack(spacing: 10) {
                    PhoneAppIcon(pkg: app.pkg, size: 28)
                    Text(app.label).lineLimit(1)
                }
                .padding(.vertical, 1)
                .tag(app.pkg)
                .help(app.pkg)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let app = apps.first(where: { $0.pkg == id }) {
                    Button("Open in Window") { selection = id; open() }
                    Button(PinnedApps.shared.isPinned(id) ? "Remove from Sidebar" : "Add to Sidebar") { PinnedApps.shared.toggle(app) }
                }
            } primaryAction: { ids in
                if let id = ids.first { selection = id; open() }
            }
        }
    }

    private func open() {
        guard let pkg = selection else { return }
        dismiss()
        Router.shared.openApp(pkg)
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

struct ScreenWindowView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var router: Router
    @State private var window: NSWindow?
    @State private var contentWidth: CGFloat = 0

    /// The scale now: the window width in points for each dp of the phone screen.
    private var scale: CGFloat? {
        link.screenDpWidth > 0 && contentWidth > 0 ? contentWidth / link.screenDpWidth : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PhoneScreenSurface()
            PhoneNavBar()
        }
        .frame(minWidth: WindowConfigurator.minWidth,
               minHeight: WindowConfigurator.minWidth / link.screenAspect + PhoneNavBar.height)
        .background(WindowConfigurator(aspect: link.screenAspect, extraHeight: PhoneNavBar.height))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { contentWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in contentWidth = w }
        })
        .background(WindowAccessor { window = $0 })
        .onAppear { router.screenDetached = true }
        .onDisappear { router.screenDetached = false }
        .navigationTitle(link.phoneName.isEmpty ? "Phone Screen" : link.phoneName)
        .toolbar {
            ToolbarItemGroup { ScreenCaptureButtons() }
            ToolbarItem {
                ScaleMenu(scale: scale, help: "Window size. At 100%, the phone screen shows at its real size.") { s in
                    guard let window, link.screenDpWidth > 0 else { return }
                    WindowConfigurator.fit(window, aspect: link.screenAspect, extraHeight: PhoneNavBar.height, width: link.screenDpWidth * s)
                }
                .disabled(link.screenDpWidth == 0 || !link.isStreaming)
            }
        }
    }
}

/// The scale steps of the phone screen window and the app windows.
enum ScreenScale {
    static let steps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static func title(_ s: CGFloat) -> String { "\(Int((s * 100).rounded()))%" }
    static func larger(than s: CGFloat) -> CGFloat? { steps.first { $0 > s + 0.01 } }
    static func smaller(than s: CGFloat) -> CGFloat? { steps.last { $0 < s - 0.01 } }
}

/// A title bar menu that shows the scale now and sets a new one. Command-plus, Command-minus and Command-0 also work.
struct ScaleMenu: View {
    let scale: CGFloat?
    let help: String
    let set: (CGFloat) -> Void

    var body: some View {
        Menu {
            Button("Actual Size") { set(1) }
                .keyboardShortcut("0")
            Button("Zoom In") { if let s = ScreenScale.larger(than: scale ?? 1) { set(s) } }
                .keyboardShortcut("+")
                .disabled(ScreenScale.larger(than: scale ?? 1) == nil)
            Button("Zoom Out") { if let s = ScreenScale.smaller(than: scale ?? 1) { set(s) } }
                .keyboardShortcut("-")
                .disabled(ScreenScale.smaller(than: scale ?? 1) == nil)
            Divider()
            ForEach(ScreenScale.steps, id: \.self) { s in
                Toggle(ScreenScale.title(s), isOn: Binding(get: { scale.map { abs($0 - s) < 0.01 } ?? false }, set: { _ in set(s) }))
            }
        } label: {
            Text(scale.map(ScreenScale.title) ?? "Scale").monospacedDigit()
        }
        .help(help)
        .accessibilityLabel("Scale")
    }
}

/// The content is the screen plus a fixed-height bar, so contentAspectRatio does not work.
/// Fit the height to the width after a live resize, on first layout, and when the aspect changes.
private struct WindowConfigurator: NSViewRepresentable {
    static let minWidth: CGFloat = 260
    let aspect: CGFloat
    let extraHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        c.aspect = aspect
        c.extraHeight = extraHeight
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.toolbarStyle = .unifiedCompact
            c.attach(to: w)
            c.fit()
        }
    }

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var aspect: CGFloat = 1
        var extraHeight: CGFloat = 0
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        func attach(to w: NSWindow) {
            guard window !== w else { return }
            detach()
            window = w
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: w,
                                                              queue: .main) { [weak self] _ in self?.fit() }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            window = nil
        }

        func fit() {
            guard let w = window else { return }
            WindowConfigurator.fit(w, aspect: aspect, extraHeight: extraHeight)
        }
    }

    /// Fits the height to the width (or to a new width), and keeps the window on the screen. Keeps the top-left corner.
    static func fit(_ w: NSWindow, aspect: CGFloat, extraHeight: CGFloat, width wanted: CGFloat? = nil) {
        guard aspect > 0, !w.styleMask.contains(.fullScreen), !w.inLiveResize else { return }
        w.contentMinSize = NSSize(width: minWidth, height: minWidth / aspect + extraHeight)
        let content = w.contentLayoutRect.size
        guard content.width > 0 else { return }
        var width = max((wanted ?? content.width).rounded(), minWidth)
        if let visible = w.screen?.visibleFrame {
            width = min(width, visible.width - (w.frame.width - content.width))
            // If too tall for the screen, make it narrower.
            let maxHeight = visible.height - (w.frame.height - content.height)
            if width / aspect + extraHeight > maxHeight, maxHeight > extraHeight {
                width = max(minWidth, (maxHeight - extraHeight) * aspect)
            }
        }
        let height = width / aspect + extraHeight
        let dw = width - content.width
        let dh = height - content.height
        guard abs(dw) > 0.5 || abs(dh) > 0.5 else { return }
        var f = w.frame
        f.size.width += dw
        f.size.height += dh
        f.origin.y -= dh // keep the top edge
        w.setFrame(f, display: true, animate: false)
    }
}
