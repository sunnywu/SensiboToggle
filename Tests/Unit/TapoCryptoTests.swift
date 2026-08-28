import XCTest
@testable import SensiboToggle

final class TapoCryptoTests: XCTestCase {
    func testHashVectors() {
        XCTAssertEqual(hex(TapoHash.sha1(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(TapoHash.sha256(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testBigEndianBytes() {
        XCTAssertEqual(Array(bigEndian: 0x01020304), [1, 2, 3, 4])
    }

    func testAesRoundTrip() {
        let key = Array(UInt8(0)..<UInt8(16))
        let iv = Array(UInt8(16)..<UInt8(32))
        let plaintext = Array("{\"method\":\"get_device_info\"}".utf8)

        let ciphertext = TapoAes.encrypt(key: key, iv: iv, plaintext: plaintext)
        let decoded = TapoAes.decrypt(key: key, iv: iv, ciphertext: ciphertext)

        XCTAssertEqual(decoded, plaintext)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
