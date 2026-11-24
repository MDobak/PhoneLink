import CPhoneUSB
import Foundation

/// Android Open Accessory (AOA) on the USB cable. It needs no network, no adb and no USB debugging.
///
/// Rules:
/// - Each stream starts with an AOA switch from this Mac, and ends with a USB re-enumeration. The re-enumeration
///   puts the phone back in normal mode (with MTP). An accessory that this Mac did not switch gets a re-enumeration.
/// - The phone sends readyMarker first. The Mac does not write before it reads the marker.
/// - The phone opens the accessory one time for each attach.
enum Aoa {
    static let readyMarker = Data("PLNKRDY1".utf8)
    static let strings = ["Phone Link", "Mac", "Phone Link for Mac", "1", "", "phonelink"]
    static let settingKey = "usbAccessory"
    /// The Android Open Accessory product IDs (Google vendor ID 0x18D1).
    static func isAccessory(vid: UInt16, pid: UInt16) -> Bool { vid == 0x18D1 && (0x2D00...0x2D05).contains(pid) }
    /// Vendors of Android phones. Other devices do not get the AOA requests.
    static let androidVendors: Set<UInt16> = [0x04E8, 0x18D1, 0x2717, 0x2A70, 0x22B8, 0x1004, 0x0FCE, 0x12D1, 0x22D9,
                                              0x0BB4, 0x2A45, 0x05C6, 0x1EBF, 0x29A9, 0x0E8D, 0x2AE5, 0x19D2, 0x1949]
}

/// A byte stream over the bulk endpoints of the accessory interface.
final class AoaTransport: LinkTransport {
    let kind = LinkKind.usb
    let entry: UInt64
    let serial: String
    private var queue: DispatchQueue!
    private var events: ((TransportEvent) -> Void)?
    private let writer = DispatchQueue(label: "phonelink.usb.write")
    private let lock = NSLock()
    /// Guarded by lock.
    private var stream: OpaquePointer?
    private var cancelled = false

    // On queue.
    private var buffer = Data()
    private var offset = 0
    private var ready = false
    private var ended = false
    private var waiting: (n: Int, done: (Data?, Bool) -> Void)?

    init(entry: UInt64, serial: String) {
        self.entry = entry
        self.serial = serial
    }

    func start(on queue: DispatchQueue, events: @escaping (TransportEvent) -> Void) {
        self.queue = queue
        self.events = events
        let t = Thread { [self] in run() }
        t.name = "phonelink-usb-read"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        // The interface can come a moment after the device.
        var s: OpaquePointer?
        var err: Int32 = 0
        for _ in 0..<15 {
            if isCancelled { break }
            s = pu_open(entry, &err)
            if s != nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        lock.lock()
        let stop = cancelled
        if !stop { stream = s }
        lock.unlock()
        guard let s, !stop else {
            if let s { pu_close(s) }
            if !isCancelled { queue.async { self.end("The Mac cannot open the USB connection (\(String(format: "0x%x", err))).") } }
            finish()
            return
        }
        let cap = 16384
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        while true {
            var got: UInt32 = 0
            let r = pu_read(s, buf, UInt32(cap), &got)
            if r != 0 {
                if !isCancelled { queue.async { self.end("The USB connection was interrupted.") } }
                break
            }
            // The phone sends a zero-length packet after a write that fills its last packet.
            if got == 0 { continue }
            let d = Data(bytes: buf, count: Int(got))
            queue.async { self.received(d) }
        }
        buf.deallocate()
        writer.sync {}
        lock.lock()
        stream = nil
        lock.unlock()
        pu_close(s)
        finish()
    }

    /// Puts the phone back in normal mode.
    private func finish() {
        let r = pu_reenumerate(entry)
        if r != 0 { NSLog("Phone Link: USB re-enumeration: 0x%x", r) }
    }

    /// Puts the phone back in normal mode at once. For the end of the app, when the reader thread cannot finish.
    func releasePhone() { _ = pu_reenumerate(entry) }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// On queue.
    private func received(_ d: Data) {
        guard !ended else { return }
        buffer.append(d)
        if !ready {
            guard let r = buffer.range(of: Aoa.readyMarker, in: (buffer.startIndex + offset)..<buffer.endIndex) else {
                // Keep only what can be the start of the marker.
                let keep = Aoa.readyMarker.count - 1
                if buffer.count > keep { buffer = Data(buffer.suffix(keep)); offset = 0 }
                return
            }
            buffer = Data(buffer[r.upperBound...])
            offset = 0
            ready = true
            events?(.ready)
        }
        serve()
    }

    /// On queue.
    private func serve() {
        guard let w = waiting else { return }
        if buffer.count - offset >= w.n {
            let d = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + w.n)])
            offset += w.n
            if offset == buffer.count { buffer = Data(); offset = 0 }
            else if offset > 1 << 20 { buffer = Data(buffer[(buffer.startIndex + offset)...]); offset = 0 }
            waiting = nil
            w.done(d, false)
        } else if ended {
            waiting = nil
            w.done(nil, false)
        }
    }

    /// On queue.
    private func end(_ why: String) {
        guard !ended else { return }
        ended = true
        if ready { serve() } else { events?(.failed(why)) }
    }

    func receive(_ n: Int, done: @escaping (Data?, Bool) -> Void) {
        waiting = (n, done)
        serve()
    }

    func send(_ data: Data, sent: (() -> Void)?) {
        writer.async { [self] in
            lock.lock()
            let s = cancelled ? nil : stream
            lock.unlock()
            guard let s else { return }
            let r = data.withUnsafeBytes { pu_write(s, $0.baseAddress, UInt32($0.count)) }
            if r != 0 {
                queue.async { self.end("The USB connection was interrupted.") }
                return
            }
            if let sent { queue.async { sent() } }
        }
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        let s = stream
        lock.unlock()
        // The reader thread closes the stream and re-enumerates the phone.
        if !wasCancelled, let s { pu_abort(s) }
    }
}

/// Watches the USB devices and switches the paired phone to accessory mode. All state is on the link queue.
final class UsbWatcher {
    struct Device {
        let entry: UInt64
        let vid: UInt16
        let pid: UInt16
        let serial: String
        var isAccessory: Bool { Aoa.isAccessory(vid: vid, pid: pid) }
    }

    private let queue: DispatchQueue
    private(set) var devices: [UInt64: Device] = [:]
    /// Serial -> the time this Mac sent the AOA start.
    private var switching: [String: Date] = [:]
    /// AOA failed for these serials. Cleared when the phone is disconnected.
    private var failed: Set<String> = []
    /// Called on the queue for a normal-mode Android device. Returns true to switch it to accessory mode.
    var shouldSwitch: ((Device) -> Bool)?
    /// Called on the queue when a device that this Mac switched is in accessory mode.
    var accessoryReady: ((Device) -> Void)?

    /// The serial of the paired phone, learned from a USB session.
    static var knownSerial: String? {
        get { UserDefaults.standard.string(forKey: "usbPhoneSerial") }
        set { UserDefaults.standard.set(newValue, forKey: "usbPhoneSerial") }
    }
    /// Android devices that answered as a different phone.
    static var otherSerials: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "usbOtherSerials") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "usbOtherSerials") }
    }

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        let r = pu_watch(queue, { ctx, d in
            guard let ctx, let d else { return }
            Unmanaged<UsbWatcher>.fromOpaque(ctx).takeUnretainedValue().changed(d.pointee)
        }, ctx)
        if r != 0 { NSLog("Phone Link: cannot watch USB devices: 0x%x", r) }
    }

    private func changed(_ p: pu_device) {
        let serial = withUnsafeBytes(of: p.serial) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let d = Device(entry: p.entry, vid: p.vid, pid: p.pid, serial: serial)
        guard p.added != 0 else {
            devices[p.entry] = nil
            // A real disconnection, not a re-enumeration: the phone does not come back in a few seconds.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.devices.values.contains(where: { $0.serial == serial }) else { return }
                self.failed.remove(serial)
                self.switching[serial] = nil
            }
            return
        }
        guard d.isAccessory || Aoa.androidVendors.contains(d.vid) else { return }
        devices[p.entry] = d
        if d.isAccessory {
            if let t = switching[serial], Date().timeIntervalSince(t) < 20 {
                switching[serial] = nil
                accessoryReady?(d)
            } else {
                // Accessory mode from an earlier run or from a different app: return the phone to normal mode.
                DispatchQueue.global().async { _ = pu_reenumerate(d.entry) }
            }
        } else {
            check(d)
        }
    }

    /// Checks the attached phones again, for example when the session becomes idle. Call on queue.
    func recheck() {
        for d in devices.values where !d.isAccessory { check(d) }
    }

    /// The paired phone, if it is on the cable in normal mode.
    func pairedPhone() -> Device? {
        devices.values.first { !$0.isAccessory && $0.serial == Self.knownSerial }
    }

    /// AOA did not work for this phone. No new try until the phone is disconnected.
    func markFailed(_ serial: String) { failed.insert(serial) }

    private func check(_ d: Device) {
        guard !d.serial.isEmpty, !failed.contains(d.serial), switching[d.serial] == nil,
              shouldSwitch?(d) == true else { return }
        switching[d.serial] = Date()
        DispatchQueue.global().async { [weak self] in
            var r: Int32 = -1
            if pu_aoa_protocol(d.entry) >= 1 {
                r = Aoa.strings.withCStrings { pu_aoa_start(d.entry, $0) }
            }
            guard r != 0, let self else { return }
            NSLog("Phone Link: the phone did not start accessory mode: 0x%x", r)
            self.queue.async {
                self.switching[d.serial] = nil
                self.failed.insert(d.serial)
            }
        }
    }
}

private extension Array where Element == String {
    /// Gives a C array of 6 C strings for the duration of body.
    func withCStrings<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let dup = map { strdup($0) }
        defer { dup.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
