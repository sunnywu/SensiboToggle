import XCTest
@testable import SensiboToggle

/// Holds the scripted response sequence, guarded by a lock so the URLProtocol
/// dispatch thread can mutate it safely.
private final class Script: @unchecked Sendable {
     private let lock = NSLock()
     private var script: [(Int, Data)] = []
     private var callCount = 0
     private var handler: ((URLRequest) -> (Int, Data))?

     func reset() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.script = []
        self.callCount = 0
        self.handler = nil
        }

    func enqueue(_ items: [(Int, Data)]) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.script = items
        }

    func setHandler(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.handler = handler
        }

    func next(for request: URLRequest) -> (Int, Data) {
        self.lock.lock(); defer { self.lock.unlock() }
        if let handler {
            self.callCount += 1
            return handler(request)
        }
        if let n = self.script.first {
            self.script.removeFirst()
            self.callCount += 1
            return n
             }
        self.callCount += 1
        return (503, Data())
        }

    var count: Int {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.callCount
         }
}

/// A hermetic network layer: a single `URLProtocol` that replays a pre-scripted
/// sequence of `(status, body)` responses, one per request. This lets us
/// deterministically drive `SensiboClient` through 429 -> retry -> 200 without
/// touching the network or a real rate limit.
private final class ScriptedURLProtocol: URLProtocol {
     static let box = Script()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (status, body) = ScriptedURLProtocol.box.next(for: self.request)
        let url = self.request.url ?? URL(string: "https://x")!
        let headers = status == 429 ? ["Retry-After": "0.01"] : nil
        let response = HTTPURLResponse(url: url,
                 statusCode: status,
                 httpVersion: "HTTP/1.1",
                 headerFields: headers)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status >= 200, status < 300 {
            self.client?.urlProtocol(self, didLoad: body)
              }
        self.client?.urlProtocolDidFinishLoading(self)
          }

    override func stopLoading() {}
}

final class BackoffPolicyTests: XCTestCase {

    private func session(replay: [(Int, String)]) -> URLSession {
        ScriptedURLProtocol.box.reset()
        let items = replay.map { (status, body) -> (Int, Data) in
            (status, Data(body.utf8))
             }
        ScriptedURLProtocol.box.enqueue(items)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: config)
        }

    private func session(handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        ScriptedURLProtocol.box.reset()
        ScriptedURLProtocol.box.setHandler { request in
            let (status, body) = handler(request)
            return (status, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: config)
        }

         /// 429 on the first attempt triggers a backoff and a retry that succeeds.
     func testRetryOn429ThenSuccess() async throws {
        let session = self.session(replay: [
             (429, ""),
             (429, ""),
             (429, ""),
             (200, "{\"status\":\"success\",\"result\":[]}"),
             ])
        let client = SensiboClient(baseURL: "https://x", apiKey: "k", session: session)
        let result = try? await client.pods()
        XCTAssertNotNil(result, "retry should eventually succeed")
            // 3 failing 429s + 1 success = 4 requests issued.
        XCTAssertEqual(ScriptedURLProtocol.box.count, 4, "expected 4 attempts (3 retries then success)")
        }

         /// A persistent 429 exhausts retries and surfaces a 429 SensiboError.
     func testExhaustedRetriesThrow429() async {
        let session = self.session(replay: [
             (429, ""),
             (429, ""),
             (429, ""),
             (429, ""),
             (429, ""),
             ])
        let client = SensiboClient(baseURL: "https://x", apiKey: "k", session: session)
        do {
             _ = try await client.pods()
            XCTFail("expected a 429 SensiboError after retries exhausted")
             } catch let e as SensiboError {
            if case let SensiboError.http(status, _) = e {
                XCTAssertEqual(status, 429, "should surface the 429 status after exhausting retries")
                 } else {
                XCTFail("expected http 429 error, got \(e)")
                 }
             } catch {
            XCTFail("unexpected error \(error)")
            }
       }

    func testPodsRequestsAllFieldsSoRoomNamesAreAvailable() async throws {
        let session = self.session { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let fields = queryItems.first(where: { $0.name == "fields" })?.value
            if fields == "*" {
                return (200, """
                {"status":"success","result":[{"id":"wZnPcb29","room":{"name":"Bedroom 1"},"name":""}]}
                """)
            }
            return (200, """
            {"status":"success","result":[{"id":"wZnPcb29"}]}
            """)
        }
        let client = SensiboClient(baseURL: "https://x", apiKey: "k", session: session)

        let pods = try await client.pods()

        XCTAssertEqual(pods.first?.displayName, "Bedroom 1")
        }
}
