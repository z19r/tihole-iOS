import Foundation
import XCTest

@testable import PiholeKit

/// A request as the mock FTL server saw it.
struct RecordedRequest {
    let method: String
    let host: String
    /// Path exactly as sent on the wire, percent-encoding intact.
    let rawPath: String
    /// Query string exactly as sent, or "" when absent.
    let rawQuery: String
    let headers: [String: String]
    let body: Data

    var sid: String? { headers["X-FTL-SID"] }

    /// The body parsed as a JSON object.
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// What the mock server answers with.
struct MockResponse {
    var status: Int
    var body: Data
    var contentType: String

    static func json(_ status: Int = 200, _ body: String) -> MockResponse {
        MockResponse(
            status: status, body: Data(body.utf8),
            contentType: "application/json")
    }

    static func text(_ status: Int = 200, _ body: String) -> MockResponse {
        MockResponse(
            status: status, body: Data(body.utf8), contentType: "text/plain")
    }

    static func empty(_ status: Int = 204) -> MockResponse {
        MockResponse(
            status: status, body: Data(), contentType: "application/json")
    }

    /// A valid login response carrying `sid`.
    static func authOK(_ sid: String) -> MockResponse {
        .json(
            200,
            #"""
            {"session":{"valid":true,"sid":"\#(sid)","csrf":"c","validity":1800,
             "totp":false},"took":0.1}
            """#
        )
    }
}

/// Stands in for the FTL webserver: every request made through a session
/// configured with this protocol is answered by the current handler.
final class MockURLProtocol: URLProtocol {
    typealias Handler = (RecordedRequest) throws -> MockResponse

    private static let lock = NSLock()
    private static var storedHandler: Handler?

    static var handler: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest
    {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler, let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            host: url.host ?? "",
            rawPath: components?.percentEncodedPath ?? url.path,
            rawQuery: components?.percentEncodedQuery ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: MockURLProtocol.readBody(of: request)
        )

        do {
            let answer = try handler(recorded)
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: answer.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": answer.contentType]
                )
            else {
                client?.urlProtocol(
                    self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(
                self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !answer.body.isEmpty {
                client?.urlProtocol(self, didLoad: answer.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func readBody(of request: URLRequest) -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A lock-protected log of the requests a test's handler received.
final class RequestLog {
    private let lock = NSLock()
    private var stored: [RecordedRequest] = []

    func append(_ request: RecordedRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }

    var all: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var last: RecordedRequest? { all.last }

    func count(_ method: String, _ path: String) -> Int {
        all.filter { $0.method == method && $0.rawPath == path }.count
    }
}

class MockFTLTestCase: XCTestCase {
    let log = RequestLog()

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// A client pointed at the mock server. Every request is recorded in
    /// `log` before `handler` answers it.
    func makeClient(_ handler: @escaping MockURLProtocol.Handler)
        -> PiholeClient
    {
        let log = self.log
        MockURLProtocol.handler = { request in
            log.append(request)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PiholeClient(
            baseURL: "http://pi.test",
            password: "secret-pw",
            session: URLSession(configuration: configuration)
        )
    }

    /// A client that already holds session "S", answering every request with
    /// one canned response.
    func makeAuthedClient(_ response: MockResponse) async -> PiholeClient {
        let client = makeClient { _ in response }
        await client.setSessionID("S")
        return client
    }
}
