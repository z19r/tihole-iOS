import Foundation
import XCTest

@testable import PiholeKit

final class ClientTests: MockFTLTestCase {
    func testNormalizesBaseURL() {
        XCTAssertEqual(
            PiholeClient.normalize("https://pi.hole"), "https://pi.hole")
        XCTAssertEqual(
            PiholeClient.normalize("https://pi.hole/"), "https://pi.hole")
        XCTAssertEqual(
            PiholeClient.normalize("https://pi.hole/api"), "https://pi.hole")
        XCTAssertEqual(
            PiholeClient.normalize("https://pi.hole/api/"), "https://pi.hole")
        XCTAssertEqual(
            PiholeClient.normalize("  http://10.0.0.53//  "), "http://10.0.0.53"
        )
    }

    func testSendsSessionHeader() async throws {
        let client = await makeAuthedClient(.json(200, #"{"groups":[]}"#))

        _ = try await client.groups()

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.rawPath, "/api/groups")
        XCTAssertEqual(request.sid, "S")
        XCTAssertEqual(request.headers["Accept"], "application/json")
    }

    func test401TriggersExactlyOneReauthAndRetry() async throws {
        let client = makeClient { request in
            if request.method == "POST" && request.rawPath == "/api/auth" {
                return .authOK("FRESH")
            }
            if request.sid == "FRESH" {
                return .json(
                    200,
                    #"{"groups":[{"name":"default","id":0,"enabled":true}]}"#)
            }
            return .json(
                401,
                #"""
                {"error":{"key":"unauthorized","message":"Unauthorized",
                 "hint":null},"took":0}
                """#
            )
        }
        await client.setSessionID("STALE")

        let groups = try await client.groups()

        XCTAssertEqual(groups.map(\.name), ["default"])
        XCTAssertEqual(log.count("POST", "/api/auth"), 1)
        XCTAssertEqual(log.count("GET", "/api/groups"), 2)
        let sid = await client.sessionID
        XCTAssertEqual(sid, "FRESH")
    }

    func testLoginRequestCarriesNoStaleSession() async throws {
        let client = makeClient { request in
            if request.rawPath == "/api/auth" {
                return .authOK("FRESH")
            }
            return request.sid == "FRESH"
                ? .json(200, #"{"groups":[]}"#) : .json(401, "{}")
        }
        await client.setSessionID("STALE")

        _ = try await client.groups()

        let login = try XCTUnwrap(log.all.first { $0.rawPath == "/api/auth" })
        XCTAssertNil(login.sid)
        XCTAssertEqual(login.json["password"] as? String, "secret-pw")
    }

    func test401AfterRetryThrowsAPIError() async throws {
        let client = makeClient { request in
            if request.rawPath == "/api/auth" {
                return .authOK("FRESH")
            }
            return .json(
                401,
                #"""
                {"error":{"key":"unauthorized","message":"Unauthorized"},
                 "took":0}
                """#
            )
        }

        do {
            _ = try await client.groups()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            XCTAssertEqual(error.apiError?.status, 401)
            XCTAssertEqual(error.apiError?.key, "unauthorized")
        }
        XCTAssertEqual(log.count("POST", "/api/auth"), 1)
        XCTAssertEqual(log.count("GET", "/api/groups"), 2)
    }

    func testDecodesErrorEnvelope() async throws {
        let client = await makeAuthedClient(
            .json(
                400,
                #"""
                {"error":{"key":"bad_request","message":"Invalid domain",
                 "hint":"check syntax"},"took":0.001}
                """#
            )
        )

        do {
            _ = try await client.domains()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            XCTAssertEqual(
                error.apiError,
                APIError(
                    status: 400, key: "bad_request", message: "Invalid domain",
                    hint: "check syntax")
            )
        }
    }

    func testTransportFailureIsNetworkError() async throws {
        let client = makeClient { _ in throw URLError(.cannotConnectToHost) }

        do {
            _ = try await client.summary()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            guard case .network(let operation, _) = error else {
                return XCTFail("expected a network error, got \(error)")
            }
            XCTAssertEqual(operation, "GET /stats/summary")
        }
    }

    func testCancelledRequestThrowsCancellationError() async throws {
        let client = makeClient { _ in throw URLError(.cancelled) }

        do {
            _ = try await client.summary()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMalformedBodyIsDecodingError() async throws {
        let client = await makeAuthedClient(.text(200, "not json"))

        do {
            _ = try await client.summary()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            guard case .decoding = error else {
                return XCTFail("expected a decoding error, got \(error)")
            }
        }
    }

    func testConcurrentRequestsLoginOnce() async throws {
        let client = makeClient { request in
            if request.rawPath == "/api/auth" {
                return .authOK("ONE")
            }
            return request.sid == "ONE"
                ? .json(200, #"{"groups":[]}"#) : .json(401, "{}")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    _ = try await client.groups()
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(log.count("POST", "/api/auth"), 1)
    }
}

final class AuthTests: MockFTLTestCase {
    func testLoginStoresSession() async throws {
        let client = makeClient { _ in .authOK("abc123") }

        try await client.login()

        let sid = await client.sessionID
        XCTAssertEqual(sid, "abc123")
        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.rawPath, "/api/auth")
        XCTAssertEqual(request.json["password"] as? String, "secret-pw")
        XCTAssertNil(request.json["totp"])
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }

    func testBadPasswordIsAuthError() async throws {
        // A rejected login returns 401 with a session object, not an FTL
        // error envelope.
        let client = makeClient { _ in
            .json(
                401,
                #"""
                {"session":{"valid":false,"sid":null,
                 "message":"password incorrect"},"took":0}
                """#
            )
        }

        do {
            try await client.login()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            guard case .auth(let status, let message) = error else {
                return XCTFail("expected an auth error, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "invalid credentials or expired session")
        }
        let sid = await client.sessionID
        XCTAssertNil(sid)
    }

    func testInvalidSessionBodyIsAuthError() async throws {
        let client = makeClient { _ in
            .json(
                200,
                #"""
                {"session":{"valid":false,"sid":"","message":"no seats"},
                 "took":0}
                """#
            )
        }

        do {
            try await client.login()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            guard case .auth(_, let message) = error else {
                return XCTFail("expected an auth error, got \(error)")
            }
            XCTAssertEqual(message, "no seats")
        }
    }

    func testLogoutClearsSession() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.logout()

        XCTAssertEqual(log.last?.method, "DELETE")
        XCTAssertEqual(log.last?.rawPath, "/api/auth")
        XCTAssertEqual(log.last?.sid, "S")
        let sid = await client.sessionID
        XCTAssertNil(sid)
    }

    func testLogoutWithoutSessionSendsNothing() async throws {
        let client = makeClient { _ in .empty(204) }

        try await client.logout()

        XCTAssertTrue(log.all.isEmpty)
    }
}

final class ErrorTests: XCTestCase {
    func testDecodesFullEnvelope() {
        let error = decodeAPIError(
            status: 403,
            data: Data(
                #"""
                {"error":{"key":"forbidden","message":"Nope",
                 "hint":"enable it"},"took":0}
                """#
                .utf8)
        )
        XCTAssertEqual(
            error,
            APIError(
                status: 403, key: "forbidden", message: "Nope",
                hint: "enable it"))
    }

    func testEmptyBody() {
        XCTAssertEqual(
            decodeAPIError(status: 500, data: Data()).message,
            "empty error response")
    }

    func testPlainTextBodyIsSurfacedVerbatim() {
        XCTAssertEqual(
            decodeAPIError(status: 502, data: Data("Bad Gateway".utf8)).message,
            "Bad Gateway")
    }

    func testJSONWithoutEnvelopeNeverLeaksBody() {
        let error = decodeAPIError(
            status: 401,
            data: Data(#"{"session":{"valid":false,"sid":"SECRET"}}"#.utf8)
        )
        XCTAssertEqual(error.message, "invalid credentials or expired session")
        XCTAssertFalse(error.message.contains("SECRET"))
    }

    func testDescriptionIncludesHint() {
        let error = PiholeError.api(
            APIError(
                status: 403, key: "forbidden", message: "Not allowed",
                hint: "Enable allow_destructive")
        )
        XCTAssertEqual(
            error.errorDescription,
            "Not allowed (status 403). Enable allow_destructive")
        XCTAssertEqual(error.status, 403)
    }
}

final class JSONValueTests: XCTestCase {
    func testDecodesEveryKind() throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"""
                {"a":null,"b":true,"c":1,"d":1.5,"e":"x","f":[1,"y"],
                 "g":{"h":false}}
                """#
                .utf8)
        )

        XCTAssertEqual(value["a"], .null)
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["c"], .number(1))
        XCTAssertEqual(value["d"], .number(1.5))
        XCTAssertEqual(value["e"], .string("x"))
        XCTAssertEqual(value["f"], .array([.number(1), .string("y")]))
        XCTAssertEqual(value.value(atPath: "g.h"), .bool(false))
        XCTAssertNil(value.value(atPath: "g.missing"))
    }

    func testBooleansAndNumbersStayDistinct() throws {
        let value = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"[true,1,false,0]"#.utf8))
        XCTAssertEqual(
            value, .array([.bool(true), .number(1), .bool(false), .number(0)]))
    }

    func testWholeNumbersEncodeAsIntegers() throws {
        let data = try JSONEncoder().encode(
            JSONValue.array([.number(85), .number(0.5)]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[85,0.5]")
    }
}
