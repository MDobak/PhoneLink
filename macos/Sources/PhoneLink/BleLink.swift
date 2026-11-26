import CoreBluetooth
import CryptoKit
import Foundation

/// Bluetooth LE: the last choice, when Wi-Fi and the USB cable are not available. The phone advertises the service,
/// with the L2CAP channel number (PSM) in its scan response (Bluetooth.kt on the phone). The session encrypts the
/// data, so the Mac and the phone need no Bluetooth pairing.
enum Ble {
    static let service = CBUUID(string: "7a6c0001-5c3e-4f8b-9d6a-50484c4e4b31")
    static let settingKey = "bluetoothLink"
    /// Too slow on Bluetooth. Through the shell helper (adb) these features still work.
    static let slowFeatures: Set<PhoneFeature> = [.screen, .screenshots, .files, .photos, .deletePhotos, .remoteDesktop]
    static var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
    /// The length of one time slot of the advertisement tag (Bluetooth.kt on the phone).
    static let slotMs: Int64 = 15 * 60_000

    /// HMAC-SHA256(key, "phonelink ble" + slot as 8 bytes, big-endian), first 8 bytes.
    static func tag(key: Data, slot: Int64) -> Data {
        var msg = Data("phonelink ble".utf8)
        withUnsafeBytes(of: slot.bigEndian) { msg.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(mac).prefix(8)
    }
}

/// A phone that advertises open pairing.
struct BlePhone: Equatable {
    let id: UUID
    let name: String
}

/// Finds the phone and opens L2CAP channels. All calls and callbacks are on the link queue.
final class BleCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let queue: DispatchQueue
    private var central: CBCentralManager?
    private var found: (peripheral: CBPeripheral, psm: CBL2CAPPSM, seen: Date)?
    /// Phones with open pairing.
    private var pairable: [UUID: (peripheral: CBPeripheral, psm: CBL2CAPPSM, name: String, seen: Date)] = [:]
    /// Peripherals that answered as a different phone.
    private var others: Set<UUID> = []
    private weak var active: BleTransport?
    private var peekUntil = Date.distantPast
    /// The beacon key of the paired phone (from "links"). With a key, the Mac accepts only advertisements with a
    /// correct tag. Without a key (before the first "links" message), it accepts all of them.
    var beaconKey: Data?
    var wantScan = false { didSet { if wantScan != oldValue { update() } } }
    /// Scans for phones with open pairing (the setup window is open).
    var wantPairable = false { didSet { if wantPairable != oldValue { pairable = [:]; update() } } }
    /// Called on the queue when the list of phones with open pairing changes.
    var onPairable: (([BlePhone]) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Creates the manager. The first time, macOS asks the user to allow Bluetooth.
    func enable() {
        if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
    }

    private var scanning: Bool { wantScan || wantPairable || Date() < peekUntil }

    private func update() {
        guard let c = central, c.state == .poweredOn else { return }
        if scanning, !c.isScanning {
            c.scanForPeripherals(withServices: [Ble.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if !scanning, c.isScanning {
            c.stopScan()
        }
    }

    /// A short scan, so that Settings can show if the phone is near. Does nothing before enable().
    func peek() {
        guard central?.state == .poweredOn, !scanning else { return }
        peekUntil = Date().addingTimeInterval(4)
        update()
        queue.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.update() }
    }

    /// The phone advertised in the last 30 seconds.
    var phoneNear: Bool {
        guard let f = found, central?.state == .poweredOn else { return false }
        return Date().timeIntervalSince(f.seen) < 30
    }

    /// A transport to the paired phone, if it advertised in the last 30 seconds.
    func transport() -> BleTransport? {
        guard phoneNear, let f = found else { return nil }
        return BleTransport(central: self, peripheral: f.peripheral, psm: f.psm)
    }

    /// A transport to a phone with open pairing.
    func transport(pairing id: UUID) -> BleTransport? {
        guard let p = pairable[id], central?.state == .poweredOn else { return nil }
        return BleTransport(central: self, peripheral: p.peripheral, psm: p.psm)
    }

    func reject(_ p: CBPeripheral) {
        others.insert(p.identifier)
        if found?.peripheral.identifier == p.identifier { found = nil }
    }

    func connect(_ t: BleTransport) {
        guard let c = central else { t.end("Bluetooth is not available."); return }
        active = t
        t.peripheral.delegate = self
        c.connect(t.peripheral)
    }

    func cancel(_ t: BleTransport) {
        if active === t { active = nil }
        central?.cancelPeripheralConnection(t.peripheral)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state != .poweredOn {
            found = nil
            if !pairable.isEmpty { pairable = [:]; onPairable?([]) }
            active?.end("Bluetooth is off.")
        }
        update()
    }

    /// The tag of the paired phone for this time slot or a slot next to it (the clocks can be different).
    private func tagIsCorrect(_ tag: Data) -> Bool {
        guard let key = beaconKey else { return true }
        let slot = Int64(Date().timeIntervalSince1970 * 1000) / Ble.slotMs
        return (slot - 1...slot + 1).contains { Ble.tag(key: key, slot: $0) == tag }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let d = sd[Ble.service] else { return }
        let b = [UInt8](d)
        guard b.count >= 3 else { return }
        let flags = b[0]
        let psm = CBL2CAPPSM(b[1]) | CBL2CAPPSM(b[2]) << 8
        let more = Data(b.dropFirst(3))
        let now = Date()
        if flags & 1 != 0 {
            if wantPairable {
                let name = String(decoding: more, as: UTF8.self)
                let isNew = pairable[p.identifier]?.name != name
                pairable[p.identifier] = (p, psm, name, now)
                // Phones that stopped advertising leave the list.
                let old = pairable.filter { now.timeIntervalSince($0.value.seen) > 10 }.map(\.key)
                old.forEach { pairable.removeValue(forKey: $0) }
                if isNew || !old.isEmpty { onPairable?(pairable.map { BlePhone(id: $0.key, name: $0.value.name) }) }
            }
            // During pairing the phone sends no tag. The handshake rejects a different phone.
            guard !others.contains(p.identifier), found == nil || found?.peripheral.identifier == p.identifier else { return }
        } else {
            if pairable.removeValue(forKey: p.identifier) != nil { onPairable?(pairable.map { BlePhone(id: $0.key, name: $0.value.name) }) }
            if beaconKey == nil {
                guard !others.contains(p.identifier) else { return }
            } else {
                guard tagIsCorrect(more) else { return }
                others.remove(p.identifier)
            }
        }
        found = (p, psm, now)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard let t = active, t.peripheral === p else { return }
        p.openL2CAPChannel(t.psm)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if let t = active, t.peripheral === p { t.end("Bluetooth connection failed.") }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if let t = active, t.peripheral === p { t.end("The Bluetooth connection was interrupted.") }
    }

    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let t = active, t.peripheral === p else { return }
        if let channel, error == nil { t.opened(channel) } else { t.end("The phone did not accept the Bluetooth connection.") }
    }
}

/// A byte stream on an L2CAP channel.
final class BleTransport: NSObject, LinkTransport, StreamDelegate {
    let kind = LinkKind.bluetooth
    let peripheral: CBPeripheral
    let psm: CBL2CAPPSM
    private weak var central: BleCentral?
    private var events: ((TransportEvent) -> Void)?
    private var queue: DispatchQueue!
    private var channel: CBL2CAPChannel?
    private var ready = false
    private var ended = false
    private var buffer = Data()
    private var waiting: (n: Int, done: (Data?, Bool) -> Void)?
    private var pending: [(data: Data, sent: (() -> Void)?)] = []
    private var pendingOffset = 0

    init(central: BleCentral, peripheral: CBPeripheral, psm: CBL2CAPPSM) {
        self.central = central
        self.peripheral = peripheral
        self.psm = psm
    }

    func start(on queue: DispatchQueue, events: @escaping (TransportEvent) -> Void) {
        self.queue = queue
        self.events = events
        central?.connect(self)
    }

    /// From BleCentral.
    func opened(_ ch: CBL2CAPChannel) {
        guard !ended else { return }
        channel = ch
        guard let input = ch.inputStream, let output = ch.outputStream else { end("The Bluetooth channel has no streams."); return }
        input.delegate = self
        output.delegate = self
        CFReadStreamSetDispatchQueue(input as CFReadStream, queue)
        CFWriteStreamSetDispatchQueue(output as CFWriteStream, queue)
        input.open()
        output.open()
    }

    /// From BleCentral or the streams.
    func end(_ why: String) {
        guard !ended else { return }
        ended = true
        if ready {
            if let w = waiting { waiting = nil; w.done(nil, true) }
        } else {
            events?(.failed(why))
        }
    }

    func stream(_ s: Stream, handle e: Stream.Event) {
        guard !ended else { return }
        switch e {
        case .openCompleted:
            if s === channel?.outputStream, !ready {
                ready = true
                events?(.ready)
            }
        case .hasBytesAvailable:
            guard let input = s as? InputStream else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                buffer.append(buf, count: n)
            }
            serve()
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            end("The Bluetooth connection was interrupted.")
        case .endEncountered:
            end("The phone closed the Bluetooth connection.")
        default:
            break
        }
    }

    private func serve() {
        guard let w = waiting, buffer.count >= w.n else { return }
        let d = Data(buffer.prefix(w.n))
        buffer = Data(buffer.dropFirst(w.n))
        waiting = nil
        w.done(d, false)
    }

    private func flush() {
        guard let output = channel?.outputStream else { return }
        while let first = pending.first, output.hasSpaceAvailable {
            let n = first.data.withUnsafeBytes { p -> Int in
                let base = p.bindMemory(to: UInt8.self).baseAddress! + pendingOffset
                return output.write(base, maxLength: first.data.count - pendingOffset)
            }
            if n <= 0 { break }
            pendingOffset += n
            if pendingOffset == first.data.count {
                pending.removeFirst()
                pendingOffset = 0
                first.sent?()
            }
        }
    }

    func receive(_ n: Int, done: @escaping (Data?, Bool) -> Void) {
        if ended && buffer.count < n { done(nil, true); return }
        waiting = (n, done)
        serve()
    }

    func send(_ data: Data, sent: (() -> Void)?) {
        guard !ended, !data.isEmpty else { sent?(); return }
        pending.append((data, sent))
        flush()
    }

    func cancel() {
        ended = true
        let dropped = pending
        pending = []
        dropped.forEach { $0.sent?() }
        if let ch = channel {
            for s in [ch.inputStream as Stream?, ch.outputStream as Stream?] {
                s?.delegate = nil
                s?.close()
            }
        }
        channel = nil
        central?.cancel(self)
    }
}
