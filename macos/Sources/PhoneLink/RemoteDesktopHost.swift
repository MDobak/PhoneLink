import AppKit
import Combine
import CoreMedia
import IOKit.pwr_mgt
import ScreenCaptureKit

/// Remote Desktop: the phone views and controls this Mac.
/// Threads: messages on the host queue, capture and encoding on the capture queue, video on the send queue.
final class RemoteDesktopHost: NSObject, ObservableObject {
    static let shared = RemoteDesktopHost()
    static let enabledKey = "remoteDesktopEnabled"
    static let accessChanged = Notification.Name("RemoteAccessChanged")

    @Published private(set) var active = false
    /// "screenRecording", "accessibility". Main thread.
    @Published private(set) var missing: [String] = []

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private let queue = DispatchQueue(label: "remote.desktop", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "remote.desktop.capture", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "remote.desktop.send", qos: .userInteractive)

    // MARK: State (host queue)

    private struct Options { var maxWidth = 1920; var maxHeight = 1200; var fps = 60; var quality = "auto" }
    private var options = Options()
    private var stream: SCStream?
    private var streaming = false
    /// Bumped at each start and stop so stale callbacks do nothing.
    private var generation = 0
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var bounds = CGRect.zero
    private var videoSize = CGSize.zero
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor = CGPoint(x: -1, y: -1)
    private var sleepAssertion: IOPMAssertionID = 0
    private var notifiedThisLink = false
    /// True from "rd.start" until stop, including capture startup. The sleep assertion lives this long.
    private var sessionActive: Bool { streaming || stream != nil || sleepAssertion != 0 }

    // Input state (host queue).
    private var buttonsDown: Set<CGMouseButton> = []
    private var clickState: Int64 = 1
    private var keysDown: Set<CGKeyCode> = []
    private var modifierKeysDown: Set<CGKeyCode> = []
    /// Modifiers a key pressed itself (from "mods"); its key up releases them.
    private var impliedModifiers: [CGKeyCode: [CGKeyCode]] = [:]
    private var scrollRemainder = CGPoint.zero
    private var inMomentum = false
    private var lastMomentum = Date.distantPast

    // MARK: Encoder state (capture queue)

    private var encoder: RemoteVideoEncoder?
    private var encGeneration = 0
    private var encFps = 60
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime = Date.distantPast
    private var lastKeyTime = Date.distantPast
    private var keyWanted = true
    private var keepAlive: DispatchSourceTimer?
    // Bit rate control (capture queue).
    private var baseRate = 8_000_000
    private var rate = 8_000_000
    private var goodStats = 0
    private var autoQuality = true

    // Send state (lock).
    private let sendLock = NSLock()
    private var pendingSends = 0
    /// After a dropped frame, send nothing until the next key frame.
    private var waitForKey = false

    private override init() {
        super.init()
        // The defaults observer also catches changes that do not come from Settings.
        let check: (Notification) -> Void = { [weak self] _ in
            guard let self, !Self.isEnabled else { return }
            self.queue.async { if self.sessionActive { self.stop(state: "disabled", message: "Remote Desktop is off on this Mac.") } }
        }
        NotificationCenter.default.addObserver(forName: Self.accessChanged, object: nil, queue: nil, using: check)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: check)
    }

    // MARK: - Entry points

    /// Called on the link queue. Do not block.
    func handle(_ j: JSON) {
        queue.async { self.process(j) }
    }

    func linkClosed() {
        queue.async {
            self.notifiedThisLink = false
            if self.sessionActive { self.stop(state: nil, message: nil) }
        }
    }

    func showDemo() { DispatchQueue.main.async { self.active = true } }

    func stopFromMac() {
        queue.async { if self.sessionActive { self.stop(state: "stopped", message: "Stopped on the Mac.") } }
    }

    func requestPermissions() {
        DispatchQueue.main.async {
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
            self.refreshPermissions()
        }
    }

    func refreshPermissions() {
        let m = Self.missingPermissions()
        if m != missing { missing = m }
    }

    static func missingPermissions() -> [String] {
        var m: [String] = []
        if !CGPreflightScreenCaptureAccess() { m.append("screenRecording") }
        if !(CGPreflightPostEventAccess() || AXIsProcessTrusted()) { m.append("accessibility") }
        return m
    }

    static func openPrivacySettings(_ pane: String) {
        let anchor = pane == "accessibility" ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    // MARK: - Messages (host queue)

    private func process(_ j: JSON) {
        let t = j.str("t") ?? ""
        switch t {
        case "rd.start":
            start(j)
        case "rd.stop":
            if sessionActive { stop(state: "stopped", message: nil) } else { sendState("stopped") }
        case "rd.keyframe":
            captureQueue.async { self.keyWanted = true }
        case "rd.quality":
            guard streaming else { return }
            readOptions(j)
            reconfigure()
        case "rd.stats":
            let rtt = j.int("rttMs") ?? 0, dropped = j.int("dropped") ?? 0
            captureQueue.async { self.adapt(rtt: rtt, dropped: dropped) }
        default:
            guard streaming, Self.isEnabled else { return }
            handleInput(t, j)
        }
    }

    private func readOptions(_ j: JSON) {
        if let w = j.int("maxWidth"), w >= 160 { options.maxWidth = min(w, 7680) }
        if let h = j.int("maxHeight"), h >= 160 { options.maxHeight = min(h, 4320) }
        if let f = j.int("fps"), f > 0 { options.fps = min(max(f, 5), 60) }
        if let q = j.str("quality"), ["auto", "fast", "balanced", "sharp"].contains(q) { options.quality = q }
    }

    private func start(_ j: JSON) {
        guard Self.isEnabled else {
            sendState("disabled", message: "To use Remote Desktop, turn on \u{201C}Allow your phone to control this Mac\u{201D} in Phone Link Settings on the Mac.")
            return
        }
        let m = Self.missingPermissions()
        DispatchQueue.main.async { self.missing = m }
        guard m.isEmpty else {
            sendState("needsPermission", extra: ["missing": m],
                      message: "Phone Link on the Mac needs permission. On the Mac, open Phone Link Settings > Remote Access.")
            DispatchQueue.main.async { self.showPermissionPrompt() }
            return
        }
        if stream != nil { stopCapture() }
        options = Options()
        readOptions(j)
        if let d = j.int("display"), d > 0, CGDisplayBounds(CGDirectDisplayID(d)).width > 0 { displayID = CGDirectDisplayID(d) }
        else { displayID = CGMainDisplayID() }
        generation += 1
        let gen = generation
        wakeDisplay()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                guard gen == self.generation else { return }
                guard let content, let display = content.displays.first(where: { $0.displayID == self.displayID }) ?? content.displays.first else {
                    self.releaseAssertions()
                    let denied = !CGPreflightScreenCaptureAccess()
                    self.sendState(denied ? "needsPermission" : "stopped", extra: denied ? ["missing": Self.missingPermissions()] : [:],
                                   message: "Phone Link cannot record the screen of this Mac. \(error?.localizedDescription ?? "")")
                    return
                }
                self.begin(display: display, gen: gen)
            }
        }
    }

    /// Display pixels scaled to fit the limits, with even sides.
    private func fitSize(_ display: CGDirectDisplayID) -> CGSize {
        let b = CGDisplayBounds(display)
        var pw = Double(b.width), ph = Double(b.height)
        if let mode = CGDisplayCopyDisplayMode(display) { pw = Double(mode.pixelWidth); ph = Double(mode.pixelHeight) }
        let s = min(1, Double(options.maxWidth) / pw, Double(options.maxHeight) / ph)
        let w = max(2, Int(pw * s) & ~1), h = max(2, Int(ph * s) & ~1)
        return CGSize(width: w, height: h)
    }

    private func streamConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        videoSize = fitSize(displayID)
        c.width = Int(videoSize.width)
        c.height = Int(videoSize.height)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.showsCursor = true
        c.queueDepth = 5
        c.scalesToFit = true
        return c
    }

    private func begin(display: SCDisplay, gen: Int) {
        displayID = display.displayID
        bounds = CGDisplayBounds(displayID)
        let config = streamConfig()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue) } catch {
            sendState("stopped", message: "Phone Link cannot record the screen: \(error.localizedDescription)")
            releaseAssertions()
            return
        }
        stream = s
        let quality = options.quality, fps = options.fps, size = videoSize
        captureQueue.sync { self.resetEncoder(gen: gen, quality: quality, fps: fps, size: size) }
        s.startCapture { error in
            self.queue.async {
                guard gen == self.generation else { return }
                if let error {
                    self.stream = nil
                    self.releaseAssertions()
                    let denied = !CGPreflightScreenCaptureAccess()
                    self.sendState(denied ? "needsPermission" : "stopped", extra: denied ? ["missing": ["screenRecording"]] : [:],
                                   message: "Phone Link cannot record the screen: \(error.localizedDescription)")
                    return
                }
                self.streaming = true
                self.sendState("streaming", message: Self.isLocked ? "This Mac is locked. Type your password to unlock it." : nil)
                self.startCursorTimer()
                DispatchQueue.main.async { self.active = true }
                if !self.notifiedThisLink {
                    self.notifiedThisLink = true
                    DispatchQueue.main.async {
                        Notifier.shared.postRemoteAccess(title: "Your Phone Is Controlling This Mac",
                                                         body: "To stop, click Stop in the Phone Link menu.")
                    }
                }
            }
        }
    }

    private func reconfigure() {
        guard let s = stream else { return }
        let config = streamConfig()
        let quality = options.quality, fps = options.fps, size = videoSize, gen = generation
        captureQueue.async { self.resetEncoder(gen: gen, quality: quality, fps: fps, size: size) }
        s.updateConfiguration(config) { _ in }
        sendState("streaming")
    }

    private func stop(state: String?, message: String?) {
        stopCapture()
        releaseInput()
        if let state { sendState(state, message: message) }
    }

    private func stopCapture() {
        generation += 1
        streaming = false
        if let s = stream { s.stopCapture { _ in } }
        stream = nil
        cursorTimer?.cancel()
        cursorTimer = nil
        lastCursor = CGPoint(x: -1, y: -1)
        captureQueue.async {
            self.keepAlive?.cancel()
            self.keepAlive = nil
            self.encoder?.invalidate()
            self.encoder = nil
            self.lastBuffer = nil
        }
        releaseAssertions()
        DispatchQueue.main.async { self.active = false }
    }

    private func sendState(_ state: String, extra: JSON = [:], message: String? = nil) {
        var j: JSON = ["t": "rd.state", "state": state, "display": Int(displayID), "displays": Self.displays()]
        if state == "streaming" { j["width"] = Int(videoSize.width); j["height"] = Int(videoSize.height) }
        if let message { j["message"] = message }
        for (k, v) in extra { j[k] = v }
        PhoneLink.shared.sendRemote(j)
    }

    private static func displays() -> [JSON] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return [] }
        let names: [CGDirectDisplayID: String] = DispatchQueue.main.sync {
            var m: [CGDirectDisplayID: String] = [:]
            for s in NSScreen.screens {
                if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { m[id.uint32Value] = s.localizedName }
            }
            return m
        }
        return ids.prefix(Int(n)).map { id in
            let b = CGDisplayBounds(id)
            return ["id": Int(id), "name": names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display"),
                    "width": Int(b.width), "height": Int(b.height), "main": CGDisplayIsMain(id) != 0]
        }
    }

    static var isLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private func showPermissionPrompt() {
        refreshPermissions()
        CGRequestScreenCaptureAccess()
        Router.shared.showSettings("remote")
    }

    // MARK: - Power

    private func wakeDisplay() {
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Phone Link Remote Desktop" as CFString, kIOPMUserActiveLocal, &activity)
        if sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Phone Link Remote Desktop" as CFString, &sleepAssertion)
        }
    }

    private func releaseAssertions() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    // MARK: - Cursor (host queue)

    private func startCursorTimer() {
        cursorTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.sendCursor() }
        t.resume()
        cursorTimer = t
    }

    private func sendCursor() {
        guard streaming, let loc = CGEvent(source: nil)?.location, loc != lastCursor else { return }
        lastCursor = loc
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let x = (loc.x - b.minX) / b.width, y = (loc.y - b.minY) / b.height
        let visible = (0...1).contains(x) && (0...1).contains(y)
        PhoneLink.shared.sendRemote(["t": "rd.cursor", "x": Double(min(max(x, 0), 1)), "y": Double(min(max(y, 0), 1)), "visible": visible])
    }
}

// MARK: - Capture and encode (capture queue)

extension RemoteDesktopHost: SCStreamOutput, SCStreamDelegate {
    private func bitRate(for quality: String, size: CGSize, fps: Int) -> Int {
        let area = Double(size.width * size.height) / (2560.0 * 1600.0)
        let fpsFactor = fps >= 50 ? 1.0 : 0.7
        let base: Double
        switch quality {
        case "fast": base = 4_000_000
        case "sharp": base = 16_000_000
        case "balanced": base = 8_000_000
        default: base = 8_000_000 * max(area, 0.25) * fpsFactor
        }
        return Int(min(max(base, 1_000_000), 24_000_000))
    }

    private func resetEncoder(gen: Int, quality: String, fps: Int, size: CGSize) {
        encGeneration = gen
        encFps = fps
        let newBase = bitRate(for: quality, size: size, fps: fps)
        if newBase != baseRate || encoder == nil { baseRate = newBase; rate = newBase }
        goodStats = 0
        autoQuality = quality == "auto"
        sendLock.lock(); pendingSends = 0; sendLock.unlock()
        encoder?.invalidate()
        encoder = nil
        lastBuffer = nil
        keyWanted = true
        if keepAlive == nil {
            let t = DispatchSource.makeTimerSource(queue: captureQueue)
            t.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.keepAliveTick() }
            t.resume()
            keepAlive = t
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        // Idle and blank frames have no new picture.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream else { return }
            self.stop(state: "stopped", message: "The screen recording stopped: \(error.localizedDescription)")
        }
    }

    /// Every 250 ms: if the screen is static, resend the last picture as a key frame when the phone needs one, and at least every 10 s.
    private func keepAliveTick() {
        guard let pb = lastBuffer, Date().timeIntervalSince(lastFrameTime) > 0.2 else { return }
        if keyWanted || Date().timeIntervalSince(lastKeyTime) > 10 {
            encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    private func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        lastBuffer = pb
        lastFrameTime = Date()
        // Do not let frames queue before the network. Skipping an unencoded frame does not break the decoder.
        sendLock.lock()
        let busy = pendingSends > 3
        sendLock.unlock()
        if busy { return }
        if encoder?.width != Int32(w) || encoder?.height != Int32(h) {
            // Frames in the old encoder can be lost without a callback.
            encoder?.invalidate()
            sendLock.lock(); pendingSends = 0; sendLock.unlock()
            let gen = encGeneration
            encoder = RemoteVideoEncoder(width: w, height: h, fps: encFps, bitRate: rate) { [weak self] units in
                self?.deliver(units, gen: gen)
            }
            keyWanted = true
            if encoder == nil { return }
        }
        if keyWanted || Date().timeIntervalSince(lastKeyTime) > 10 {
            keyWanted = false
            lastKeyTime = Date()
            encoder?.requestKeyFrame()
        }
        sendLock.lock(); pendingSends += 1; sendLock.unlock()
        encoder?.encode(pb, pts: pts)
    }

    private func deliver(_ units: [RemoteVideoEncoder.Unit], gen: Int) {
        sendQueue.async {
            self.sendLock.lock(); self.pendingSends = max(0, self.pendingSends - 1); self.sendLock.unlock()
            for u in units {
                if u.flags & 2 != 0 || u.flags & 1 != 0 { self.waitForKey = false }
                if self.waitForKey { continue }
                if !PhoneLink.shared.sendRemoteVideo(flags: u.flags, ptsUs: u.ptsUs, data: u.data) {
                    self.waitForKey = true
                    self.captureQueue.async {
                        guard gen == self.encGeneration else { return }
                        self.keyWanted = true
                        self.lowerRate(0.7)
                    }
                    break
                }
            }
        }
    }

    // MARK: Bit rate (capture queue)

    private func lowerRate(_ factor: Double) {
        guard autoQuality else { return }
        rate = max(1_000_000, Int(Double(rate) * factor))
        goodStats = 0
        encoder?.setBitRate(rate)
    }

    private func adapt(rtt: Int, dropped: Int) {
        guard autoQuality, encoder != nil else { return }
        if dropped > 0 || rtt > 250 { lowerRate(0.75) }
        else if rtt > 120 { lowerRate(0.9) }
        else if rtt < 80 {
            goodStats += 1
            // Ramp up slowly: after 6 s of good stats, 10% every 2 s.
            if goodStats >= 3, rate < baseRate {
                rate = min(baseRate, Int(Double(rate) * 1.1))
                encoder?.setBitRate(rate)
            }
        }
    }
}

// MARK: - Input (host queue)

extension RemoteDesktopHost {
    private static let source = CGEventSource(stateID: .hidSystemState)

    private func handleInput(_ t: String, _ j: JSON) {
        guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else { return }
        switch t {
        case "rd.pointer":
            let p = point(x: (j["x"] as? NSNumber)?.doubleValue ?? 0, y: (j["y"] as? NSNumber)?.doubleValue ?? 0)
            pointer(at: p, action: j.str("action") ?? "move", button: Self.button(j.str("button")), clicks: j.int("clicks"))
        case "rd.moveBy":
            let cur = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = (j["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (j["dy"] as? NSNumber)?.doubleValue ?? 0
            let p = clamp(CGPoint(x: cur.x + dx, y: cur.y + dy))
            pointer(at: p, action: "move", button: .left, clicks: nil, delta: CGPoint(x: dx, y: dy))
        case "rd.button":
            let cur = clamp(CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY))
            pointer(at: cur, action: j.str("action") ?? "down", button: Self.button(j.str("button")), clicks: j.int("clicks"))
        case "rd.scroll":
            scroll(dx: (j["dx"] as? NSNumber)?.doubleValue ?? 0, dy: (j["dy"] as? NSNumber)?.doubleValue ?? 0, phase: j.str("phase") ?? "none")
        case "rd.key":
            guard let code = j.int("code"), (0...255).contains(code) else { return }
            key(CGKeyCode(code), down: j.bool("down"), mods: j["mods"] as? [String] ?? [])
        case "rd.text":
            if let s = j["text"] as? String, !s.isEmpty { type(s) }
        case "rd.system":
            system(j.str("action") ?? "")
        default:
            break
        }
    }

    private static func button(_ s: String?) -> CGMouseButton {
        switch s { case "right": return .right; case "middle": return .center; default: return .left }
    }

    private func point(x: Double, y: Double) -> CGPoint {
        clamp(CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width, y: bounds.minY + min(max(y, 0), 1) * bounds.height))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0 else { return p }
        return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1), y: min(max(p.y, bounds.minY), bounds.maxY - 1))
    }

    private func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

    private func pointer(at p: CGPoint, action: String, button: CGMouseButton, clicks: Int?, delta: CGPoint? = nil) {
        let type: CGEventType
        var btn = button
        switch action {
        case "down":
            type = button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown
            buttonsDown.insert(button)
            clickState = Int64(min(max(clicks ?? 1, 1), 3))
        case "up":
            type = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
            buttonsDown.remove(button)
            if let clicks { clickState = Int64(min(max(clicks, 1), 3)) }
        default:
            if buttonsDown.contains(.left) { type = .leftMouseDragged; btn = .left }
            else if buttonsDown.contains(.right) { type = .rightMouseDragged; btn = .right }
            else if buttonsDown.contains(.center) { type = .otherMouseDragged; btn = .center }
            else { type = .mouseMoved }
        }
        guard let e = CGEvent(mouseEventSource: Self.source, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { return }
        if action != "move" { e.setIntegerValueField(.mouseEventClickState, value: clickState) }
        if let delta {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        }
        e.flags = currentFlags()
        post(e)
    }

    /// Pixel scrolls with trackpad phases so apps scroll smoothly with momentum.
    private func scroll(dx: Double, dy: Double, phase: String) {
        if phase != "momentum", inMomentum { endMomentum() }
        let x = dx + scrollRemainder.x, y = dy + scrollRemainder.y
        let ix = Int32(x.rounded(.towardZero)), iy = Int32(y.rounded(.towardZero))
        scrollRemainder = CGPoint(x: x - Double(ix), y: y - Double(iy))
        guard let e = CGEvent(scrollWheelEvent2Source: Self.source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
        switch phase {
        case "began": e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1); scrollRemainder = .zero
        case "changed": e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        case "ended": e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4); scrollRemainder = .zero
        case "momentum":
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: inMomentum ? 2 : 1)
            inMomentum = true
            lastMomentum = Date()
            // End momentum when the phone stops sending it.
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.inMomentum, Date().timeIntervalSince(self.lastMomentum) >= 0.14 else { return }
                self.endMomentum()
            }
        default: break
        }
        e.flags = currentFlags()
        post(e)
    }

    private func endMomentum() {
        inMomentum = false
        scrollRemainder = .zero
        guard let e = CGEvent(scrollWheelEvent2Source: Self.source, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
        post(e)
    }

    // MARK: Keys

    private static let modifierFlag: [CGKeyCode: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand, 56: .maskShift, 60: .maskShift, 58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn, 57: .maskAlphaShift,
    ]
    private static let modKey: [String: CGKeyCode] = ["cmd": 55, "shift": 56, "opt": 58, "ctrl": 59, "fn": 63]

    private func currentFlags() -> CGEventFlags {
        var f: CGEventFlags = []
        for k in modifierKeysDown { if let m = Self.modifierFlag[k] { f.insert(m) } }
        return f
    }

    private func modifierEvent(_ code: CGKeyCode, down: Bool) {
        if down { modifierKeysDown.insert(code) } else { modifierKeysDown.remove(code) }
        guard let e = CGEvent(keyboardEventSource: Self.source, virtualKey: code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = currentFlags()
        post(e)
    }

    private func key(_ code: CGKeyCode, down: Bool, mods: [String]) {
        // A lone modifier key changes the sticky modifier state.
        if Self.modifierFlag[code] != nil {
            if down != modifierKeysDown.contains(code) { modifierEvent(code, down: down) }
            return
        }
        // Press "mods" that are not down around the key, and remember them per key: at key up "mods" no longer lists them.
        let wanted = mods.compactMap { Self.modKey[$0] }
        if down {
            let held = currentFlags()
            let implied = wanted.filter { !held.contains(Self.modifierFlag[$0] ?? []) }
            for m in implied { modifierEvent(m, down: true) }
            impliedModifiers[code, default: []] += implied
        }
        guard let e = CGEvent(keyboardEventSource: Self.source, virtualKey: code, keyDown: down) else { return }
        var f = currentFlags()
        if !down { for m in wanted { if let flag = Self.modifierFlag[m] { f.insert(flag) } } }
        // A real keyboard sets these flags on arrows and some function keys.
        if (123...126).contains(code) { f.insert([.maskNumericPad, .maskSecondaryFn]) }
        else if [115, 116, 117, 119, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113].contains(Int(code)) { f.insert(.maskSecondaryFn) }
        e.flags = f
        post(e)
        if down { keysDown.insert(code) } else {
            keysDown.remove(code)
            let implied = impliedModifiers.removeValue(forKey: code) ?? []
            for m in implied.reversed() where modifierKeysDown.contains(m) { modifierEvent(m, down: false) }
        }
    }

    /// In chunks of at most 20 UTF-16 units.
    private func type(_ s: String) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: Self.source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                post(e)
            }
            chunk.removeAll()
        }
        for ch in s {
            let u = Array(String(ch).utf16)
            if chunk.count + u.count > 20 { flush() }
            chunk += u
        }
        flush()
    }

    private func releaseInput() {
        let loc = CGEvent(source: nil)?.location ?? .zero
        for b in buttonsDown {
            let t: CGEventType = b == .left ? .leftMouseUp : b == .right ? .rightMouseUp : .otherMouseUp
            post(CGEvent(mouseEventSource: Self.source, mouseType: t, mouseCursorPosition: loc, mouseButton: b))
        }
        buttonsDown.removeAll()
        for k in keysDown { post(CGEvent(keyboardEventSource: Self.source, virtualKey: k, keyDown: false)) }
        keysDown.removeAll()
        impliedModifiers.removeAll()
        for m in modifierKeysDown { modifierEvent(m, down: false) }
        modifierKeysDown.removeAll()
        if inMomentum { endMomentum() }
        scrollRemainder = .zero
    }

    // MARK: System actions

    private func tap(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: Self.source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e)
        }
    }

    /// NX_KEYTYPE_* as a system-defined event (subtype 8).
    private func mediaKey(_ key: Int) {
        DispatchQueue.main.async {
            for down in [true, false] {
                let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
                let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                                            timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
                ev?.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    private func openSystemApp(_ name: String, args: [String] = []) {
        let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = args
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    private func system(_ action: String) {
        switch action {
        case "missionControl":
            if FileManager.default.fileExists(atPath: "/System/Applications/Mission Control.app") { openSystemApp("Mission Control") }
            else { tap(126, [.maskControl, .maskNumericPad, .maskSecondaryFn]) }
        case "appExpose":
            if FileManager.default.fileExists(atPath: "/System/Applications/Mission Control.app") { openSystemApp("Mission Control", args: ["2"]) }
            else { tap(125, [.maskControl, .maskNumericPad, .maskSecondaryFn]) }
        case "launchpad":
            if FileManager.default.fileExists(atPath: "/System/Applications/Launchpad.app") { openSystemApp("Launchpad") }
            else if FileManager.default.fileExists(atPath: "/System/Applications/Apps.app") { openSystemApp("Apps") }
            else { tap(131, []) }
        case "spotlight": tap(49, .maskCommand)
        case "lock": tap(12, [.maskCommand, .maskControl])
        case "volumeUp": mediaKey(0)
        case "volumeDown": mediaKey(1)
        case "mute": mediaKey(7)
        case "playPause": mediaKey(16)
        case "displaySleep":
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        default: break
        }
    }
}
