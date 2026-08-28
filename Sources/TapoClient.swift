import Foundation
import Darwin

// MARK: - Errors

enum TapoError: Error, LocalizedError, Equatable {
    case noCredentials
    case noDeviceIP(name: String)
    case http(status: Int, body: String)
    case handshake(message: String)
    case decoding(String)
    case transport(String)
    case sessionExpired
    case device(code: Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Tapo credentials configured."
        case let .noDeviceIP(name):
            return "No IP address configured for Tapo device '\(name)'."
        case let .http(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
        case let .handshake(message):
            return "Tapo handshake failed: \(message)"
        case let .decoding(message):
            return "Bad Tapo response: \(message)"
        case let .transport(message):
            return "Network: \(message)"
        case .sessionExpired:
            return "Tapo session expired."
        case let .device(code):
            return "Tapo device error \(code)."
          }
      }
}

// MARK: - Protocol

/// So the UI depends on an abstraction that the fake and the live KLAP client both
/// satisfy - the same pattern as `SensiboClientProtocol`.
protocol TapoClientProtocol: Sendable {
     /// One `Light` per configured device, with its current on/off state where
     /// reachable. Never hard-fails on an unreachable device (best-effort state).
    func load() async throws -> [Light]
     /// Set a device's on/off state (`set_device_info { "device_on": on }`).
    func set(on: Bool, device: String) async throws
     /// Best-effort read of a device's on/off state (`get_device_info -> device_on`).
    func status(device: String) async throws -> Bool
}

// MARK: - Mock

/// An in-memory Tapo double. Used by XCUITest and by app launch in "mock" mode so
/// the entire light UI can be exercised with zero network. `@MainActor` keeps the
/// store single-threaded and trivially `Sendable`.
@MainActor
final class MockTapoClient: TapoClientProtocol {
    private var store: [String: Light]

    init(seed: [Light]) {
        self.store = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
      }

    func load() async throws -> [Light] {
        Array(self.store.values).sorted { $0.displayName < $1.displayName }
      }

    func set(on: Bool, device: String) async throws {
        if var existing = self.store[device] {
            existing.on = on
            self.store[device] = existing
         } else {
            self.store[device] = Light(id: device, name: device, on: on)
         }
      }

    func status(device: String) async throws -> Bool {
        self.store[device]?.on ?? false
      }
}

// MARK: - Live KLAP client
//
// A straight rewrite of `tapo`'s KLAP path (`klap_protocol.rs`):
//     1. handshake1  POST http://{ip}/handshake1   body=localSeed(16)   -> remoteSeed(16)||serverHash(32)
//     2. verify       SHA256(localSeed||remoteSeed||authHash) == serverHash
//     3. handshake2  POST http://{ip}/handshake2   body=SHA256(remoteSeed||localSeed||authHash)
//     4. request     POST http://{ip}/request?seq=N body=SHA256(sig||seq||ct)||ct
// where `authHash = SHA256(SHA1(user)||SHA1(pass))` and `ct` is AES-128-CBC.

final class KLAPTapoClient: TapoClientProtocol, @unchecked Sendable {
    let email: String
    let password: String
    let devices: [TapoDeviceConfig]
    private let session: URLSession

     /// Per-device cached session (handshake output). An actor keeps the cache
     /// async-safe under Swift 6 concurrency (no `NSLock` in async context).
    private let store = KLAPTapoClient.SessionStore()

    private static let defaultSession = makeSession()
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false           // we manage TP_SESSIONID ourselves
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config)
      }

    init(email: String,
         password: String,
         devices: [TapoDeviceConfig],
         session: URLSession = KLAPTapoClient.defaultSession) {
        self.email = email
        self.password = password
        self.devices = devices
        self.session = session
      }

     // MARK: Public API

    func load() async throws -> [Light] {
        if devices.isEmpty { return [] }     // no lights configured -> nothing to show
        guard !email.isEmpty, !password.isEmpty else { throw TapoError.noCredentials }
        var lights: [Light] = []
        for device in devices {
            if device.ip.isEmpty {
                 // Configured but no IP yet - surface it as an "off" light so the
                 // button exists; a tap will fail cleanly with a clear message.
                lights.append(Light(id: device.name, name: device.name, on: false))
                continue
             }
            let on = (try? await self.status(device: device.name)) ?? false
            lights.append(Light(id: device.name, name: device.name, on: on))
         }
        return lights.sorted { $0.displayName < $1.displayName }
      }

    func set(on: Bool, device: String) async throws {
        guard !email.isEmpty, !password.isEmpty else { throw TapoError.noCredentials }
        guard let ip = self.ip(name: device) else { throw TapoError.noDeviceIP(name: device) }
        let inner: [String: Any] = [
             "method": "set_device_info",
             "params": ["device_on": on],
             "request_time_milis": Int(Date().timeIntervalSince1970 * 1000),
             "terminalUUID": "00-00-00-00-00-00-00",
         ]
        let innerJSON = try jsonToString(inner)
        _ = try await self.execute(ip: ip, inner: innerJSON)
      }

    func status(device: String) async throws -> Bool {
        guard !email.isEmpty, !password.isEmpty else { throw TapoError.noCredentials }
        guard let ip = self.ip(name: device) else { throw TapoError.noDeviceIP(name: device) }
        let inner: [String: Any] = [
             "method": "get_device_info",
             "params": [:],
         ]
        let innerJSON = try jsonToString(inner)
        let result = try await self.execute(ip: ip, inner: innerJSON)
        return Self.onState(from: result) ?? false
      }

    func deviceInfo(device: String) async throws -> [String: Any] {
        guard !email.isEmpty, !password.isEmpty else { throw TapoError.noCredentials }
        guard let ip = self.ip(name: device) else { throw TapoError.noDeviceIP(name: device) }
        let inner: [String: Any] = [
             "method": "get_device_info",
             "params": [:],
         ]
        let innerJSON = try jsonToString(inner)
        return try await self.execute(ip: ip, inner: innerJSON)
      }

     // MARK: KLAP handshake + request

    private func execute(ip: String, inner: String) async throws -> [String: Any] {
         // First attempt on any cached session; on session-expiry, re-handshake once.
        for attempt in 0..<2 {
            do {
                let session = try await self.session(for: ip)
                return try await self.send(ip: ip, session: session, inner: inner)
             } catch {
                if attempt == 0, Self.isRetryable(error) {
                     // Drop the stale session and redo the handshake.
                    await store.remove(ip)
                    continue
                 }
                throw error
             }
         }
         // Unreachable: the loop above returns or throws on every path.
        throw TapoError.transport("exhausted retry attempts")
      }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let tapo = error as? TapoError else { return false }
        switch tapo {
        case .sessionExpired, .device:
            return true              // the session may have expired between load and tap
        default:
            return false
         }
      }

    private func session(for ip: String) async throws -> KlapSession {
         // Fast path: reuse a cached session; otherwise handshake and cache it.
        if let existing = await store.get(ip) { return existing }
        let fresh = try await self.handshake(ip: ip)
        await store.put(ip, fresh)
        return fresh
      }

    private func handshake(ip: String) async throws -> KlapSession {
        let base = "http://\(ip):80/app"
        let auth = KlapCipher.authHash(username: email, password: password)
        let localSeed = tapoRandomBytes(16)
        TapoDiscoveryProbe.send(to: ip)

         // 1) handshake1: localSeed -> remoteSeed || serverHash, and the TP_SESSIONID cookie.
        let (h1Data, h1Resp) = try await self.post(base + "/handshake1", body: localSeed, cookie: nil)
        if h1Resp.statusCode == 403 {
            throw TapoError.handshake(message: "turn on Third-Party Compatibility in the Tapo app, then try again")
        }
        guard (200..<300).contains(h1Resp.statusCode) else {
            let text = String(decoding: h1Data, as: UTF8.self)
            throw TapoError.http(status: h1Resp.statusCode, body: text)
        }
        guard h1Data.count == 48 else { throw TapoError.handshake(message: "unexpected handshake1 reply") }
        let remoteSeed = Array(h1Data[0..<16])
        let serverHash = Array(h1Data[16..<48])
        let cookie = Self.extractSessionID(from: h1Resp)

         // 2) verify   SHA256(localSeed || remoteSeed || authHash) == serverHash
        let verify = KlapCipher.digest(concat: localSeed + remoteSeed + auth)
        guard verify == serverHash else {
            throw TapoError.handshake(message: "hash mismatch (wrong credentials or 3rd-party mode off)")
         }

         // 3) handshake2: SHA256(remoteSeed || localSeed || authHash). NOTE reversed operand order.
        let h2Hash = KlapCipher.digest(concat: remoteSeed + localSeed + auth)
        let (h2Data, h2Resp) = try await self.post(base + "/handshake2", body: h2Hash, cookie: cookie)
        guard (200..<300).contains(h2Resp.statusCode) else {
            let text = String(decoding: h2Data, as: UTF8.self)
            throw TapoError.http(status: h2Resp.statusCode, body: text)
        }

        let cipher = KlapCipher(localSeed: localSeed, remoteSeed: remoteSeed, authHash: auth)
        guard let cipher else { throw TapoError.handshake(message: "cipher setup failed") }
        return KlapSession(cookie: cookie ?? "", cipher: cipher)
      }

    private func send(ip: String,
                      session: KlapSession,
                      inner: String) async throws -> [String: Any] {
        let (payload, seq) = session.cipher.encrypt(inner)
        let url = "http://\(ip):80/app/request?seq=\(seq)"

        let (data, resp) = try await self.post(url, body: payload, cookie: session.cookie)

         // A 401/403 on /request means the session expired -> let the caller re-handshake.
        if resp.statusCode == 401 || resp.statusCode == 403 {
            throw TapoError.sessionExpired
         }

         // The reply is another signed AES-CBC frame: strip the 32-byte signature, decrypt at `seq`.
        guard let json = session.cipher.decrypt(seq: seq, ciphertext: Array(data)) else {
            throw TapoError.decoding("could not decrypt device reply")
         }

        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw TapoError.decoding("reply was not a JSON object: \(json)")
         }

        if let code = parsed["error_code"] as? Int, code != 0 {
            throw TapoError.device(code: code)
         }

        let result = (parsed["result"] as? [String: Any]) ?? [:]
        return result
      }

     // MARK: HTTP

    private func post(_ url: String,
                      body: [UInt8],
                      cookie: String?) async throws -> (Data, HTTPURLResponse) {
        guard let reqUrl = URL(string: url) else { throw TapoError.transport("bad url: \(url)") }
        var request = URLRequest(url: reqUrl)
        request.httpMethod = "POST"
        request.httpBody = Data(body)
         // Match tapo's `reqwest` behaviour: a raw byte body, no content-type set.
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
         }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TapoError.transport("no HTTP response")
             }
            return (data, http)
         } catch let error as TapoError {
            throw error
         } catch {
            throw TapoError.transport(error.localizedDescription)
         }
      }

    private func ip(name: String) -> String? {
        if let dev = devices.first(where: { $0.name == name }), !dev.ip.isEmpty {
            return dev.ip
         }
        return nil
      }

     // MARK: Helpers

    private func jsonToString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        guard let str = String(data: data, encoding: .utf8) else {
            throw TapoError.decoding("could not UTF-8-encode request body")
         }
        return str
      }

    private static func onState(from result: [String: Any]) -> Bool? {
         // Top-level `device_on` (older / simple bulbs).
        if let on = result["device_on"] as? Bool { return on }
         // Newer bulbs nest state under `components[].status`.
        if let components = result["components"] as? [Any] {
            for component in components {
                if let status = component as? [String: Any], let on = status["device_on"] as? Bool {
                    return on
                 }
             }
         }
        return nil
      }

    private static func extractSessionID(from response: HTTPURLResponse) -> String? {
        guard let raw = firstHeader("Set-Cookie", in: response.allHeaderFields) else { return nil }
         // Format: "TP_SESSIONID=abc123; Path=/" (possibly quoted by the header field).
        for fragment in raw.components(separatedBy: ";") {
            let pair = fragment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "TP_SESSIONID" else { continue }
            let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : "TP_SESSIONID=\(unquoted)"
         }
        return nil
      }

    private static func firstHeader(_ name: String, in fields: [AnyHashable: Any]) -> String? {
        for (k, v) in fields {
            if (k as? String)?.caseInsensitiveCompare(name) == .orderedSame {
                if let s = v as? String { return s }
                if let arr = v as? [String] { return arr.joined(separator: ", ") }
             }
         }
        return nil
      }

     /// Async-safe per-device session cache (Swift 6: an actor is concurrency-safe;
     /// `NSLock` is not usable from an async context).
    private actor SessionStore {
        var sessions: [String: KlapSession] = [:]
        func get(_ ip: String) -> KlapSession? { sessions[ip] }
        func put(_ ip: String, _ session: KlapSession) { sessions[ip] = session }
        func remove(_ ip: String) { sessions[ip] = nil }
      }
}

// `SHA256(concat)` - the small shared primitive the handshake needs a few times.
extension KlapCipher {
    static func digest(concat: [UInt8]) -> [UInt8] {
        TapoHash.sha256(concat)
      }
}

// MARK: - TDP discovery wake-up

enum TapoDiscoveryProbe {
    private static let port: UInt16 = 20_002
    private static let crcSeed: UInt32 = 0x5A6B_7C8D
    private static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsrfXWgBS6W18B5QXgzwV
    cQb2YoySgJcPNbuI5lJTe2Q1Fbc+diPuwV6JKm9JxJb6t6MZWIplBxS/zSSVx2Yi
    hqjpn8aQvVqR3tJr4Z++h5WzQwhU0qQWCuBJ2HEZlqJYjU0zNHvNvnSJJ8miSSNV
    oQg7hSKxrbM3Lw5T08sALqTN1uQeoh1AWBgJO2gl0kOKIOttvmWZoKePjN0TjL6K
    GfGSkZKeerSDpwl5NmoqG0CNHUoG3Vpl8LoLxe48vd3MLF/UDbbaMFqjeYUiqJ9Y
    Qx9NlKlDF1CJCh4MG0aLTDSuAoeRHV25yeA9oobx23F9mZkm8wIDAQAB
    -----END PUBLIC KEY-----

    """

    static func send(to ip: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.port).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }

        let packet = Self.datagram()
        packet.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    _ = Darwin.sendto(fd, baseAddress, packet.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func datagram(serial: UInt32 = UInt32.random(in: .min ... .max)) -> [UInt8] {
        let body = ["params": ["rsa_key": Self.publicKeyPEM]]
        let payloadData = try! JSONSerialization.data(withJSONObject: body, options: [])
        let payload = Array(payloadData)
        var packet: [UInt8] = [2, 0]
        packet.append(bigEndian: UInt16(1))
        packet.append(bigEndian: UInt16(payload.count))
        packet.append(contentsOf: [17, 0])
        packet.append(bigEndian: serial)
        packet.append(bigEndian: Self.crcSeed)
        packet.append(contentsOf: payload)
        packet.replaceSubrange(12..<16, with: Array(bigEndian: Self.crc32(packet)))
        return packet
    }

    static func crc32(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var crc = seed ^ 0xffff_ffff
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ Self.crcTable[index]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { value -> UInt32 in
            var crc = UInt32(value)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = 0xedb8_8320 ^ (crc >> 1)
                } else {
                    crc >>= 1
                }
            }
            return crc
        }
    }()
}

private extension Array where Element == UInt8 {
    mutating func append(bigEndian value: UInt16) {
        self.append(UInt8((value >> 8) & 0xff))
        self.append(UInt8(value & 0xff))
    }

    mutating func append(bigEndian value: UInt32) {
        self.append(UInt8((value >> 24) & 0xff))
        self.append(UInt8((value >> 16) & 0xff))
        self.append(UInt8((value >> 8) & 0xff))
        self.append(UInt8(value & 0xff))
    }
}
