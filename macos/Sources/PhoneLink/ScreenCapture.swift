import AVFoundation
import AppKit
import CoreMedia
import SwiftUI

// MARK: - Save location

enum ScreenCaptureFiles {
    /// The com.apple.screencapture location, or the Desktop.
    private static var folder: URL {
        let fm = FileManager.default
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var dir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue, fm.isWritableFile(atPath: url.path) { return url }
        }
        return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
    }

    static func newURL(_ prefix: String, ext: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(prefix) \(f.string(from: Date()))"
        let dir = folder
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

// MARK: - Feedback

final class ScreenCapture: ObservableObject {
    static let shared = ScreenCapture()

    struct Banner: Equatable {
        let id = UUID()
        let title: String
        let url: URL?
        let thumbnail: NSImage?
        let failed: Bool
    }

    @Published private(set) var flash = 0
    @Published private(set) var busy = false
    @Published var banner: Banner?
    private var hideBanner: DispatchWorkItem?

    /// Full-resolution PNG. Needs USB or Wireless debugging.
    func takeScreenshot() {
        guard !busy else { return }
        guard PhoneLink.shared.route(.screenshots).isAvailable, let serial = PhoneLink.shared.adbSerial, let adb = AdbManager.path else {
            show(Banner(title: "Screenshots need USB or Wireless debugging.", url: nil, thumbnail: nil, failed: true))
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.screencap(adb: adb, serial: serial)
            DispatchQueue.main.async {
                self.busy = false
                guard let data else {
                    self.show(Banner(title: "The phone did not send a screenshot.", url: nil, thumbnail: nil, failed: true))
                    return
                }
                let url = ScreenCaptureFiles.newURL("Phone Screenshot", ext: "png")
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self.show(Banner(title: "The screenshot could not be saved.", url: nil, thumbnail: nil, failed: true))
                    return
                }
                self.flash += 1
                Self.playShutter()
                self.show(Banner(title: "Screenshot Saved", url: url, thumbnail: NSImage(data: data), failed: false))
            }
        }
    }

    /// Kills adb after 20 s.
    private static func screencap(adb: String, serial: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard p.terminationStatus == 0, data.count > 1000, Array(data.prefix(8)) == png else { return nil }
        return data
    }

    private static func playShutter() {
        let effects = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int ?? 1
        guard effects != 0 else { return }
        let paths = ["/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
                     "/System/Library/Sounds/Tink.aiff"]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let sound = NSSound(contentsOfFile: path, byReference: true) else { return }
        sound.volume = 0.5
        sound.play()
    }

    func show(_ b: Banner) {
        hideBanner?.cancel()
        banner = b
        let w = DispatchWorkItem { [weak self] in self?.banner = nil }
        hideBanner = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (b.failed ? 4 : 6), execute: w)
    }

    func holdBanner(_ hold: Bool) {
        hideBanner?.cancel()
        guard !hold, banner != nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.banner = nil }
        hideBanner = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }
}

// MARK: - Recording

/// Remuxes the phone H.264 stream into a QuickTime movie without re-encoding.
/// Phone sound (48 kHz stereo PCM) goes into an AAC track.
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var startedAt: Date?

    private let q = DispatchQueue(label: "phonelink.recorder")
    /// The video and audio calls come from network threads.
    private let lock = NSLock()
    private var active = false
    private var lastAudio: CFTimeInterval = 0

    // Only on q.
    private var url: URL?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var format: CMVideoFormatDescription?
    private var startTime = CMTime.invalid
    private var lastVideo = CMTime.invalid
    private var audioAnchor = CMTime.invalid
    private var audioFrames: Int64 = 0
    private var audioEnd = CMTime.invalid
    private var stopReason: String?
    private var wantsAudio = false

    private static let audioFormat: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 16, mReserved: 0)
        var f: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &f)
        return f
    }()

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.finishNow()
        }
    }

    private var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    private func setActive(_ on: Bool) {
        lock.lock(); active = on; lock.unlock()
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Main thread. The file starts at the next key frame.
    func start() {
        guard startedAt == nil, PhoneLink.shared.isStreaming else { return }
        let url = ScreenCaptureFiles.newURL("Phone Screen Recording", ext: "mov")
        lock.lock(); let heardAudio = CACurrentMediaTime() - lastAudio < 2; lock.unlock()
        let audio = heardAudio || UserDefaults.standard.bool(forKey: "screenSound")
        q.async {
            self.reset()
            self.url = url
            self.stopReason = nil
            self.wantsAudio = audio
            self.setActive(true)
        }
        startedAt = Date()
        PhoneLink.shared.requestKeyFrame()
    }

    /// Main thread. `reason` is shown to the user, e.g. after a disconnect.
    func stop(reason: String? = nil) {
        guard startedAt != nil else { return }
        setActive(false)
        startedAt = nil
        q.async { self.finish(reason: reason ?? self.stopReason) }
    }

    /// Any thread. H.264 Annex B.
    func video(_ data: Data, format fmt: CMVideoFormatDescription?) {
        guard isActive, let fmt else { return }
        let t = Self.now
        q.async { self.appendVideo(data, fmt, t) }
    }

    /// Any thread. 16-bit LE PCM, stereo, 48 kHz.
    func audio(_ d: Data) {
        lock.lock()
        lastAudio = CACurrentMediaTime()
        let on = active
        lock.unlock()
        guard on else { return }
        let t = Self.now
        q.async { self.appendAudio(d, t) }
    }

    private func reset() {
        writer = nil
        videoIn = nil
        audioIn = nil
        format = nil
        startTime = .invalid
        lastVideo = .invalid
        audioAnchor = .invalid
        audioFrames = 0
        audioEnd = .invalid
    }

    private func appendVideo(_ data: Data, _ fmt: CMVideoFormatDescription, _ t: CMTime) {
        guard isActive else { return }
        var nals: [Data] = []
        var key = false
        for nal in H264Renderer.nalUnits(data) where !nal.isEmpty {
            let type = nal[nal.startIndex] & 0x1F
            if type == 7 || type == 8 || type == 9 { continue }
            if type == 5 { key = true }
            nals.append(nal)
        }
        guard !nals.isEmpty else { return }
        if writer == nil {
            // The movie must start with a key frame.
            guard key, let url else { return }
            guard makeWriter(url, fmt) else { stopFromQueue("The recording could not start."); return }
            writer?.startSession(atSourceTime: t)
            startTime = t
        } else if let format, !CMFormatDescriptionEqual(format, otherFormatDescription: fmt) {
            // The phone screen changed size (e.g. rotation). The file cannot change its video size.
            stopFromQueue("The recording stopped because the phone screen changed its size.")
            return
        }
        guard let writer, writer.status == .writing, let videoIn, videoIn.isReadyForMoreMediaData else { return }
        var pts = t
        if lastVideo.isValid, pts <= lastVideo { pts = lastVideo + CMTime(value: 1, timescale: 1000) }
        guard let sample = H264Renderer.sample(nals: nals, format: fmt, pts: pts) else { return }
        if !key { H264Renderer.setFlag(kCMSampleAttachmentKey_NotSync, on: sample) }
        if videoIn.append(sample) { lastVideo = pts }
        else if writer.status == .failed { stopFromQueue("The recording stopped because of an error.") }
    }

    private func makeWriter(_ url: URL, _ fmt: CMVideoFormatDescription) -> Bool {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { return false }
        w.add(v)
        if wantsAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
            ])
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); audioIn = a }
        }
        guard w.startWriting() else { return false }
        writer = w
        videoIn = v
        format = fmt
        return true
    }

    private func appendAudio(_ d: Data, _ t: CMTime) {
        guard isActive, startTime.isValid, let writer, writer.status == .writing, let audioIn, let fmt = Self.audioFormat else { return }
        let frames = d.count / 4
        guard frames > 0 else { return }
        // Count samples from an anchor so network jitter does not leave gaps in the track.
        let begin = t - CMTime(value: CMTimeValue(frames), timescale: 48_000)
        let expected = audioAnchor.isValid ? audioAnchor + CMTime(value: audioFrames, timescale: 48_000) : .invalid
        if !expected.isValid || abs((expected - begin).seconds) > 0.25 {
            audioAnchor = begin
            audioFrames = 0
        }
        var pts = audioAnchor + CMTime(value: audioFrames, timescale: 48_000)
        // Audio samples must not overlap.
        if audioEnd.isValid, pts < audioEnd {
            audioAnchor = audioEnd
            audioFrames = 0
            pts = audioEnd
        }
        audioFrames += Int64(frames)
        guard pts >= startTime, audioIn.isReadyForMoreMediaData else { return }
        var block: CMBlockBuffer?
        let n = frames * 4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: n, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        d.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
                                                                   sampleCount: frames, presentationTimeStamp: pts,
                                                                   packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if audioIn.append(sample) { audioEnd = pts + CMTime(value: CMTimeValue(frames), timescale: 48_000) }
    }

    /// On q.
    private func stopFromQueue(_ reason: String) {
        stopReason = reason
        DispatchQueue.main.async { self.stop() }
    }

    /// On q.
    private func finish(reason: String?) {
        guard let writer, writer.status == .writing, let url else {
            if let url, writer != nil { try? FileManager.default.removeItem(at: url) }
            reset()
            let msg = reason ?? "The recording has no video. Try again."
            DispatchQueue.main.async { ScreenCapture.shared.show(.init(title: msg, url: nil, thumbnail: nil, failed: true)) }
            return
        }
        videoIn?.markAsFinished()
        audioIn?.markAsFinished()
        if lastVideo.isValid { writer.endSession(atSourceTime: lastVideo + CMTime(value: 1, timescale: 60)) }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        let ok = writer.status == .completed
        reset()
        if !ok { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.main.async {
            if ok {
                let title = reason ?? "Recording Saved"
                ScreenCapture.shared.show(.init(title: title, url: url, thumbnail: NSWorkspace.shared.icon(forFile: url.path), failed: false))
            } else {
                ScreenCapture.shared.show(.init(title: "The recording could not be saved.", url: nil, thumbnail: nil, failed: true))
            }
        }
    }

    private func finishNow() {
        guard isActive else {
            // Let a pending stop finish the file first.
            q.sync {}
            return
        }
        setActive(false)
        q.sync { finish(reason: nil) }
    }
}

// MARK: - Views

struct ScreenCaptureButtons: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var capture = ScreenCapture.shared
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        Button { capture.takeScreenshot() } label: {
            Label("Take Screenshot", systemImage: "camera")
        }
        .help(link.route(.screenshots).isAvailable ? "Save a screenshot of the phone screen" : "Screenshots need USB or Wireless debugging")
        .disabled(!link.isStreaming || !link.route(.screenshots).isAvailable || capture.busy)

        if let start = recorder.startedAt {
            Button { recorder.stop() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Self.elapsed(ctx.date.timeIntervalSince(start)))
                            .monospacedDigit()
                    }
                }
            }
            .help("Stop Recording")
            .accessibilityLabel("Stop Recording")
        } else {
            Button { recorder.start() } label: {
                Label("Record Screen", systemImage: "record.circle")
            }
            .help("Record the phone screen")
            .disabled(!link.isStreaming)
        }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct ScreenCaptureOverlay: View {
    @ObservedObject private var capture = ScreenCapture.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashOpacity = 0.0

    var body: some View {
        ZStack(alignment: .top) {
            Color.white.opacity(flashOpacity).allowsHitTesting(false)
            if let b = capture.banner {
                banner(b)
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(b.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: capture.banner)
        .onChange(of: capture.flash) { _, _ in
            guard !reduceMotion else { return }
            flashOpacity = 0.6
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
    }

    private func banner(_ b: ScreenCapture.Banner) -> some View {
        HStack(spacing: 10) {
            if let img = b.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 34, maxHeight: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if b.failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            Text(b.title)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let url = b.url {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    capture.banner = nil
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .environment(\.colorScheme, .dark)
        .onHover { capture.holdBanner($0) }
        .onTapGesture(count: 2) { if let url = b.url { NSWorkspace.shared.open(url) } }
        .accessibilityElement(children: .combine)
    }
}
