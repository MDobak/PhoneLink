import Foundation
import Network

/// The kind of connection that carries a session. Each kind carries the same frames.
enum LinkKind: String {
    /// TCP on the local network or on the phone hotspot.
    case wifi
    /// TCP through "adb forward" to 127.0.0.1.
    case adb
    /// Android Open Accessory on the USB cable.
    case usb
    /// An L2CAP channel.
    case bluetooth

    var isCable: Bool { self == .adb || self == .usb }
}

enum TransportEvent {
    case ready
    case failed(String)
    case localNetworkDenied
}

/// A reliable, ordered byte stream to the phone. Each callback runs on the queue given to start.
protocol LinkTransport: AnyObject {
    var kind: LinkKind { get }
    func start(on queue: DispatchQueue, events: @escaping (TransportEvent) -> Void)
    /// Reads exactly n bytes (n > 0). Gives nil after an error or at the end of the stream (eof true).
    func receive(_ n: Int, done: @escaping (_ data: Data?, _ eof: Bool) -> Void)
    /// sent runs when the transport took the data.
    func send(_ data: Data, sent: (() -> Void)?)
    func cancel()
}

/// Wi-Fi, the phone hotspot, or "adb forward".
final class TcpTransport: LinkTransport {
    let kind: LinkKind
    private let conn: NWConnection

    init(_ ep: NWEndpoint, kind: LinkKind) {
        self.kind = kind
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        conn = NWConnection(to: ep, using: NWParameters(tls: nil, tcp: tcp))
    }

    var remoteEndpoint: NWEndpoint? { conn.currentPath?.remoteEndpoint }

    func start(on queue: DispatchQueue, events: @escaping (TransportEvent) -> Void) {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: events(.ready)
            case .failed(let e): events(.failed("Connection failed: \(e.localizedDescription)"))
            case .waiting(let e):
                if self.conn.currentPath?.unsatisfiedReason == .localNetworkDenied { events(.localNetworkDenied) }
                else { events(.failed("Cannot reach the phone: \(e.localizedDescription)")) }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func receive(_ n: Int, done: @escaping (Data?, Bool) -> Void) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, eof, err in
            if let d, d.count == n, err == nil { done(d, false) } else { done(nil, eof) }
        }
    }

    func send(_ data: Data, sent: (() -> Void)?) {
        conn.send(content: data, completion: .contentProcessed { _ in sent?() })
    }

    func cancel() {
        conn.stateUpdateHandler = nil
        conn.cancel()
    }
}
