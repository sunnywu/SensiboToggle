import Foundation
import CommonCrypto
import Security

// MARK: - Hashing / symmetric primitives (tapo `crypto.rs`)
//
// A faithful Swift port of the crypto the reference `tapo` crate uses for the
// KLAP (key-exchange) device protocol. SHA-1 / SHA-256 come from CommonCrypto;
// AES-128-CBC + PKCS#7 mirrors `aes128_cbc_encrypt/decrypt`.

enum TapoHash {
    static func sha1(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 20)
        bytes.withUnsafeBufferPointer { _ = CC_SHA1($0.baseAddress, CC_LONG($0.count), &out) }
        return out
     }
    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &out) }
        return out
     }
}

/// AES-128-CBC with PKCS#7 padding - the cipher the KLAP device channel uses.
enum TapoAes {
    static func encrypt(key: [UInt8], iv: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        cbc(key, iv, plaintext, encrypt: true)
     }
    static func decrypt(key: [UInt8], iv: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        cbc(key, iv, ciphertext, encrypt: false)
     }
    private static func cbc(_ key: [UInt8], _ iv: [UInt8], _ data: [UInt8], encrypt: Bool) -> [UInt8] {
        var outLen = 0
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var status: CCCryptorStatus = CCCryptorStatus(kCCParamError)
        key.withUnsafeBufferPointer { kp in
            iv.withUnsafeBufferPointer { ivp in
                data.withUnsafeBufferPointer { dp in
                    status = CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCPadding(1),           // kCCPKCS7Padding == 1
                        kp.baseAddress, key.count,
                        ivp.baseAddress, dp.baseAddress, data.count,
                         &out, out.count, &outLen)
                 }
             }
         }
        guard status == kCCSuccess else { return [] }
        return Array(out[0..<outLen])
     }
}

/// 16 random bytes for the KLAP handshake `local_seed` (matches `rand::rng()` in the ref).
func tapoRandomBytes(_ count: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: count)
    let status = data.withUnsafeMutableBufferPointer {
        SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
     }
    guard status == errSecSuccess else {
        for i in 0..<data.count { data[i] = .random(in: 0...255) }
        return data
     }
    return data
}

extension Array where Element == UInt8 {
    init(bigEndian value: UInt32) {
        self = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }
}

// MARK: - KLAP cipher
//
// Mirrors `klap_cipher.rs`. From the device handshake outputs (`localSeed`,
// `remoteSeed`) and the auth hash `SHA256(SHA1(user) || SHA1(pass))` the session
// derives a 16-byte AES key, a 12-byte base IV, a 28-byte signature salt, and a
// starting sequence number. Each request/reply then carries a
// `SHA256(sig || seq || ciphertext)` (32-byte) prefix before the AES-CBC
// ciphertext, where the per-message IV is `baseIV || seq(be)`.

final class KlapCipher: @unchecked Sendable {
    static func authHash(username: String, password: String) -> [UInt8] {
         // SHA256( SHA1(username) || SHA1(password) )
        let concat = TapoHash.sha1(Array(username.utf8)) + TapoHash.sha1(Array(password.utf8))
        return TapoHash.sha256(concat)
     }

    private let key: [UInt8]
    private let baseIV: [UInt8]
    private let sig: [UInt8]
    private var seq: Int32
    private let lock = NSLock()

    init?(localSeed: [UInt8], remoteSeed: [UInt8], authHash: [UInt8]) {
        let localHash = localSeed + remoteSeed + authHash
        let keyHash = TapoHash.sha256([0x6c, 0x73, 0x6b] + localHash)    // "lsk"
        let ivHash    = TapoHash.sha256([0x69, 0x76] + localHash)       // "iv"
        let sigHash = TapoHash.sha256([0x6c, 0x64, 0x6b] + localHash)    // "ldk"
        guard keyHash.count >= 16, ivHash.count >= 32, sigHash.count >= 28 else { return nil }
        self.key = Array(keyHash[0..<16])
        self.baseIV = Array(ivHash[0..<12])
          // Starting sequence = last 4 bytes of the "iv" hash, big-endian Int32
          // (the same value the device expects on the first request).
        let raw = Array(ivHash[28..<32])
        let bigEndian = (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
        self.seq = Int32(bitPattern: bigEndian)
        self.sig = Array(sigHash[0..<28])
     }

     /// Encrypt a UTF-8 payload, returning `(signature || ciphertext, seq)`.
     ///
     /// The sequence counter is mutated exactly like the reference `fetch_add(1)+1`,
     /// so the first message uses `startSeq + 1`.
     @discardableResult
    func encrypt(_ plaintext: String) -> (payload: [UInt8], seq: Int32) {
        lock.lock(); defer { lock.unlock() }
        seq &+= 1
        let seqBytes = Array(bigEndian: UInt32(bitPattern: seq))
        let ivSeq = baseIV + seqBytes
        let cipher = TapoAes.encrypt(key: key, iv: ivSeq, plaintext: Array(plaintext.utf8))
        let signature = TapoHash.sha256(sig + seqBytes + cipher)
        return (signature + cipher, seq)
     }

     /// Strip the 32-byte signature prefix and AES-decrypt the remainder at `seq`.
    func decrypt(seq: Int32, ciphertext: [UInt8]) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard ciphertext.count > 32 else { return nil }
        let seqBytes = Array(bigEndian: UInt32(bitPattern: seq))
        let ivSeq = baseIV + seqBytes
        let plain = TapoAes.decrypt(key: key, iv: ivSeq, ciphertext: Array(ciphertext[32...]))
        guard let str = String(bytes: plain, encoding: .utf8) else {
             // Some firmware variants pad with NULs; recover the prefix up to the first NUL.
            if let nulIndex = plain.firstIndex(of: 0) {
                return String(bytes: Array(plain[plain.startIndex..<nulIndex]), encoding: .utf8)
             }
            return nil
         }
        return str
     }
}

/// A live KLAP session bound to one device IP. The owned `cipher` guards its own
/// `seq`, so this value can be handed out of its lock.
struct KlapSession: Sendable {
    let cookie: String
    let cipher: KlapCipher
}
