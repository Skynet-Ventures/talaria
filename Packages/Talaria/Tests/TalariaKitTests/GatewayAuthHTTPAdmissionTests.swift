import Foundation
import XCTest
@testable import TalariaKit

final class GatewayAuthHTTPAdmissionTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler:
            ((URLRequest) throws -> (URLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    /// A request that has begun but deliberately never completes. The bounded
    /// reconnect tests wait for `startLoading` before allowing the auth
    /// deadline to fire, then prove cancellation reaches URLSession through
    /// `stopLoading`.
    private final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var onStart: (() -> Void)?
        nonisolated(unsafe) static var onStop: (() -> Void)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() { Self.onStart?() }
        override func stopLoading() { Self.onStop?() }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class CredentialRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [GatewayCredential] = []

        func record(_ credential: GatewayCredential) {
            lock.lock()
            saved.append(credential)
            lock.unlock()
        }

        var credentials: [GatewayCredential] {
            lock.lock()
            defer { lock.unlock() }
            return saved
        }
    }

    private enum ReconnectTestError: Error, Sendable {
        case keychainSaveFailed
    }

    private let baseURL = URL(string: "https://gateway.example")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        HangingURLProtocol.onStart = nil
        HangingURLProtocol.onStop = nil
        super.tearDown()
    }

    private func client(handler: @escaping (URLRequest) throws -> (URLResponse, Data))
        -> GatewayAuthClient {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GatewayAuthClient(baseURL: baseURL,
                                 session: URLSession(configuration: configuration))
    }

    private func hangingClient(deadline: TimeInterval = 0.25) -> GatewayAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        return GatewayAuthClient(
            baseURL: baseURL, session: URLSession(configuration: configuration),
            reconnectRequestDeadline: deadline)
    }

    private func http(_ request: URLRequest, status: Int,
                      contentType: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
    }

    func testStatus503JSONAndHTMLNeverDecodeAsHealthy() async {
        for (contentType, body, expected) in [
            ("application/json", #"{"version":"fake","detail":"maintenance"}"#, "maintenance"),
            ("text/html", "<html><body>Service Unavailable</body></html>", "Service Unavailable"),
        ] {
            let auth = client { request in
                (self.http(request, status: 503, contentType: contentType), Data(body.utf8))
            }
            do {
                _ = try await auth.status()
                XCTFail("503 must not decode as GatewayStatus")
            } catch let error as GatewayHTTPError {
                XCTAssertEqual(error.statusCode, 503)
                XCTAssertTrue(error.detail.contains(expected), error.detail)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTicket502503504RemainTypedTransportFailures() async {
        for status in [502, 503, 504] {
            let auth = client { request in
                XCTAssertEqual(request.httpMethod, "POST")
                return (self.http(request, status: status),
                        Data(#"{"error":"upstream unavailable"}"#.utf8))
            }
            do {
                _ = try await auth.mintWSTicket(credential: .sessionToken("request-secret"))
                XCTFail("HTTP \(status) must fail")
            } catch let error as GatewayHTTPError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.detail, "upstream unavailable")
                XCTAssertFalse(error.detail.contains("request-secret"))
            } catch let auth as AuthError {
                XCTFail("server fault was misclassified as auth: \(auth)")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func test401And403RemainDistinctAuthenticationFailures() async {
        for status in [401, 403] {
            let auth = client { request in
                (self.http(request, status: status),
                 Data(#"{"error":"session rejected"}"#.utf8))
            }
            do {
                _ = try await auth.mintWSTicket(credential: .sessionToken("secret"))
                XCTFail("HTTP \(status) must fail")
            } catch AuthError.unauthorized(let detail) {
                XCTAssertEqual(detail, "session rejected")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSuccessfulResponsesRemainStrictlyDecoded() async throws {
        let statusClient = client { request in
            (self.http(request, status: 200), Data(#"""
            {
                "version":"1.2.3","auth_required":true,
                "auth_flows":["native_pkce"],"gateway_running":true
            }
            """#.utf8))
        }
        let status = try await statusClient.status()
        XCTAssertEqual(status.version, "1.2.3")
        XCTAssertTrue(status.authRequired)
        XCTAssertTrue(status.supportsNativePKCE)
        XCTAssertTrue(status.gatewayRunning)

        let ticketClient = client { request in
            (self.http(request, status: 200), Data(#"{"ticket":"one-use"}"#.utf8))
        }
        let ticket = try await ticketClient.mintWSTicket(
            credential: .sessionToken("secret"))
        XCTAssertEqual(ticket, "one-use")
    }

    func testMalformedSuccessfulStatusAndTicketFailClosed() async {
        let cases: [(String, Data, Bool)] = [
            ("status invalid JSON", Data("<html>ok</html>".utf8), false),
            ("status non-object", Data("[]".utf8), false),
            ("ticket invalid JSON", Data("not-json".utf8), true),
            ("ticket missing", Data(#"{"ok":true}"#.utf8), true),
            ("ticket empty", Data(#"{"ticket":""}"#.utf8), true),
        ]
        for (label, body, ticket) in cases {
            let auth = client { request in (self.http(request, status: 200), body) }
            do {
                if ticket {
                    _ = try await auth.mintWSTicket(credential: .sessionToken("secret"))
                } else {
                    _ = try await auth.status()
                }
                XCTFail("\(label) must fail")
            } catch is AuthError {
                // Expected fail-closed protocol shape.
            } catch {
                XCTFail("unexpected error for \(label): \(error)")
            }
        }
    }

    func testHostileBodyIsRawBoundedControlSanitizedAndCredentialRedacted() async {
        let hostile = "failure\u{001B}\u{202E}\r\u{2028}Authorization: Bearer secret-bearer "
            + "access_token=secret-access " + String(repeating: "x", count: 390)
            + " refresh_token=secret-near-boundary " + String(repeating: "y", count: 1_000)
        let body = try! JSONEncoder().encode(JSONValue.object([
            "detail": .string(hostile),
            "refresh_token": .string("body-secret-that-must-not-be-selected"),
        ]))
        let auth = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                           "request-secret")
            return (self.http(request, status: 503), body)
        }

        do {
            _ = try await auth.mintWSTicket(credential: .sessionToken("request-secret"))
            XCTFail("503 must fail")
        } catch let error as GatewayHTTPError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertLessThanOrEqual(error.detail.unicodeScalars.count, 512)
            XCTAssertTrue(error.detail.contains("[redacted]"), error.detail)
            XCTAssertTrue(error.detail.contains("response detail clipped"), error.detail)
            XCTAssertFalse(error.detail.contains("secret-bearer"))
            XCTAssertFalse(error.detail.contains("secret-access"))
            XCTAssertFalse(error.detail.contains("secret-near-boundary"))
            XCTAssertFalse(error.detail.contains("body-secret"))
            XCTAssertFalse(error.detail.contains("request-secret"))
            XCTAssertFalse(error.detail.unicodeScalars.contains(where: {
                $0.value == 0x1B || $0.value == 0x202E || $0.value == 0x0D
                    || $0.value == 0x2028
            }))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOversizedBodyIsOmittedWholeWithoutPrefixParsingOrSecretLeak() async {
        let body = Data((#"{"detail":"visible","access_token":"secret-after-cut","padding":""#
            + String(repeating: "z", count: 10_000) + #""}"#).utf8)
        let auth = client { request in
            (self.http(request, status: 503), body)
        }

        do {
            _ = try await auth.status()
            XCTFail("503 must fail")
        } catch let error as GatewayHTTPError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertTrue(error.detail.contains("oversized response detail omitted"))
            XCTAssertFalse(error.detail.contains("visible"))
            XCTAssertFalse(error.detail.contains("secret-after-cut"))
            XCTAssertFalse(error.detail.contains("padding"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonHTTPResponsesFailClosedForStatusAndTicket() async {
        for ticket in [false, true] {
            let auth = client { request in
                (URLResponse(url: request.url!, mimeType: "application/json",
                             expectedContentLength: 2, textEncodingName: "utf-8"),
                 Data("{}".utf8))
            }
            do {
                if ticket {
                    _ = try await auth.mintWSTicket(credential: .sessionToken("secret"))
                } else {
                    _ = try await auth.status()
                }
                XCTFail("non-HTTP must fail")
            } catch AuthError.protocolError(let detail) {
                XCTAssertTrue(detail.contains("was not HTTP"), detail)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRefresh503StillMeansProviderUnreachableAndKeepsExistingSemantics() async {
        let auth = client { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/auth/native/refresh") == true)
            return (self.http(request, status: 503), Data(#"{"error":"idp down"}"#.utf8))
        }
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 0, provider: "nous", userID: nil)
        do {
            _ = try await auth.refresh(tokens)
            XCTFail("503 refresh must fail")
        } catch AuthError.providerUnreachable {
            // Exact pre-existing contract: caller retains the token set.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHungOAuthRefreshHitsDeadlineAndCancelsURLSessionTask() async {
        let started = expectation(description: "refresh request started")
        let stopped = expectation(description: "refresh request cancelled")
        HangingURLProtocol.onStart = { started.fulfill() }
        HangingURLProtocol.onStop = { stopped.fulfill() }

        let auth = hangingClient()
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 0, provider: "nous", userID: nil)
        let request = Task { try await auth.refresh(tokens) }

        await fulfillment(of: [started], timeout: 1)
        switch await request.result {
        case .success:
            XCTFail("a hung refresh must time out")
        case .failure(let error as URLError):
            XCTAssertEqual(error.code, .timedOut)
        case .failure(let error):
            XCTFail("unexpected refresh failure: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testHungWSTicketHitsDeadlineAndCancelsURLSessionTask() async {
        let started = expectation(description: "ticket request started")
        let stopped = expectation(description: "ticket request cancelled")
        HangingURLProtocol.onStart = { started.fulfill() }
        HangingURLProtocol.onStop = { stopped.fulfill() }

        let auth = hangingClient()
        let request = Task {
            try await auth.mintWSTicket(credential: .sessionToken("ticket-secret"))
        }

        await fulfillment(of: [started], timeout: 1)
        switch await request.result {
        case .success:
            XCTFail("a hung WS-ticket request must time out")
        case .failure(let error as URLError):
            XCTAssertEqual(error.code, .timedOut)
        case .failure(let error):
            XCTFail("unexpected ticket failure: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testRefreshKeychainSaveFailureStopsBeforeTicketOrCredentialPublication() async {
        let original = GatewayCredential.oauth(TokenSet(
            accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: 0, provider: "nous", userID: "user"))
        let refreshed = TokenSet(
            accessToken: "new-access", refreshToken: "new-refresh",
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            provider: "nous", userID: "user")
        let ticketRequests = LockedCounter()
        let savedCredentials = CredentialRecorder()
        let auth = client { request in
            if request.url?.path.hasSuffix("/auth/native/refresh") == true {
                let response = JSONValue.object([
                    "access_token": .string(refreshed.accessToken),
                    "refresh_token": .string(refreshed.refreshToken),
                    "expires_at": .number(refreshed.expiresAt),
                    "provider": .string(refreshed.provider),
                    "user_id": .string(refreshed.userID!),
                ])
                return (self.http(request, status: 200), try JSONEncoder().encode(response))
            }
            if request.url?.path.hasSuffix("/api/auth/ws-ticket") == true {
                ticketRequests.increment()
                return (self.http(request, status: 503), Data(#"{"error":"must not mint"}"#.utf8))
            }
            throw URLError(.badURL)
        }
        let keychain = KeychainStore(saveOverrideForTesting: { credential, _ in
            savedCredentials.record(credential)
            throw ReconnectTestError.keychainSaveFailed
        })
        let client = GatewayClient(
            baseURL: baseURL, credential: original, keychain: keychain,
            restExecutor: { request, _ in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 500,
                                         httpVersion: nil, headerFields: nil)!)
            },
            authClient: auth)

        do {
            try await client.connect()
            XCTFail("a rotated credential must not connect when persistence fails")
        } catch ReconnectTestError.keychainSaveFailed {
            // Expected fail-closed persistence boundary.
        } catch {
            XCTFail("unexpected connection failure: \(error)")
        }

        XCTAssertEqual(savedCredentials.credentials, [.oauth(refreshed)])
        XCTAssertEqual(ticketRequests.count, 0,
                       "ticket minting would permit a socket with an unadoptable credential")
        let ownsOriginal = await client.ownsCredential(original)
        XCTAssertTrue(ownsOriginal)
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }
}
