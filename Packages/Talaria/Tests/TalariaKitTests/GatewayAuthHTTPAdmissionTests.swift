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

    private let baseURL = URL(string: "https://gateway.example")!

    override func tearDown() {
        StubURLProtocol.handler = nil
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
            XCTAssertEqual(request.timeoutInterval, 8,
                           "ws-ticket is a finite HTTP POST; default 60s is a connect stall")
            return (self.http(request, status: 200), Data(#"{"ticket":"one-use"}"#.utf8))
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
}
