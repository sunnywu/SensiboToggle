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

    func testDiscoveryProbePacketIsWellFormed() {
        let packet = TapoDiscoveryProbe.datagram(serial: 0x01020304)
        let payloadLength = (Int(packet[4]) << 8) | Int(packet[5])

        XCTAssertEqual(packet[0], 2)
        XCTAssertEqual(packet[1], 0)
        XCTAssertEqual(packet[2], 0)
        XCTAssertEqual(packet[3], 1)
        XCTAssertEqual(payloadLength, packet.count - 16)
        XCTAssertEqual(packet[6], 17)
        XCTAssertEqual(packet[7], 0)
        XCTAssertEqual(Array(packet[8..<12]), [1, 2, 3, 4])

        var crcInput = packet
        crcInput.replaceSubrange(12..<16, with: Array(bigEndian: UInt32(0x5A6B7C8D)))
        XCTAssertEqual(Array(packet[12..<16]), Array(bigEndian: TapoDiscoveryProbe.crc32(crcInput)))

        let payload = String(bytes: packet[16...], encoding: .utf8) ?? ""
        XCTAssertTrue(payload.contains("rsa_key"))
    }

    func testDiscoveryProbeCrcMatchesKnownVector() {
        XCTAssertEqual(hex(Array(bigEndian: TapoDiscoveryProbe.crc32(Array("123456789".utf8)))), "cbf43926")
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
