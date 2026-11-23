import CryptoKit
import Foundation

/// Must stay identical to Crypto.kt on the phone. See the comment there for the scheme.
enum LinkCrypto {
    static func random(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    static func hkdf(_ ikm: Data, salt: Data, info: String, length: Int = 32) -> Data {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                       info: Data(info.utf8), outputByteCount: length)
        return k.withUnsafeBytes { Data($0) }
    }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func sas(_ shared: Data, salt: Data) -> String {
        let b = [UInt8](hkdf(shared, salt: salt, info: "phonelink sas v1", length: 4))
        let v = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return String(format: "%06d", v % 1_000_000)
    }

    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One direction of the encrypted stream: AES-256-GCM, nonce = 4 zero bytes + 8-byte counter.
final class FrameCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(_ key: Data) { self.key = SymmetricKey(data: key) }

    private func nonce() -> AES.GCM.Nonce {
        var n = Data(count: 12)
        var c = counter.bigEndian
        counter += 1
        withUnsafeBytes(of: &c) { n.replaceSubrange(4..<12, with: $0) }
        return try! AES.GCM.Nonce(data: n)
    }

    func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce())
        return box.ciphertext + box.tag
    }

    func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try AES.GCM.SealedBox(nonce: nonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key)
    }
}
