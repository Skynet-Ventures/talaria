import Foundation
import XCTest
@testable import TalariaKit

private actor TerminalBackendRESTServer {
    struct RequestRecord: Sendable {
        var path: String
        var query: [URLQueryItem]
        var method: String?
        var body: Data?
        var sessionToken: String?
    }

    private var records: [RequestRecord] = []

    func requests() -> [RequestRecord] { records }

    func execute(_ request: URLRequest, responseLimit: Int?) async throws
        -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        records.append(RequestRecord(
            path: url.path,
            query: components?.queryItems ?? [],
            method: request.httpMethod,
            body: request.httpBody,
            sessionToken: request.value(forHTTPHeaderField: "X-Hermes-Session-Token")
        ))
        let payload: JSONValue
        switch request.httpMethod {
        case "PUT":
            payload = ["ok": true, "backend": "remote_plugin"]
        default:
            payload = [
                "active": "remote_plugin",
                "backends": [
                    [
                        "name": "remote_plugin",
                        "label": "Remote plugin",
                        "description": "Dynamically supplied by the gateway.",
                        "active": true,
                        "status": "needs_setup",
                        "detail": "Add the gateway credential first.",
                    ],
                    [
                        "name": "retired_runner",
                        "label": "Retired runner",
                        "description": "Shown for diagnosis only.",
                        "active": false,
                        "status": "unavailable",
                        "detail": "The provider is unavailable.",
                    ],
                ],
            ]
        }
        let data = try JSONEncoder().encode(payload)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

final class TerminalBackendAPITests: XCTestCase {
    func testCatalogAndSelectionUseAuthenticatedProfileScopedREST() async throws {
        let server = TerminalBackendRESTServer()
        let baseURL = try XCTUnwrap(URL(string: "https://gateway.example/base/"))
        let client = GatewayClient(
            baseURL: baseURL,
            credential: .sessionToken("terminal-token"),
            restExecutor: { request, limit in
                try await server.execute(request, responseLimit: limit)
            }
        )

        let catalog = try await client.terminalBackendCatalog(profile: "research")
        XCTAssertEqual(catalog.active, "remote_plugin")
        XCTAssertEqual(catalog.backends.map(\.name), ["remote_plugin", "retired_runner"])
        XCTAssertEqual(catalog.admittedBackend(named: "remote_plugin")?.status, .needsSetup)
        XCTAssertNil(catalog.admittedBackend(named: "retired_runner"))

        let receipt = try await client.selectTerminalBackend("remote_plugin", profile: "research")
        XCTAssertEqual(receipt.backend, "remote_plugin")

        let records = await server.requests()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/base/api/tools/terminal/backends")
        XCTAssertEqual(records[0].method, "GET")
        XCTAssertEqual(records[0].query, [URLQueryItem(name: "profile", value: "research")])
        XCTAssertEqual(records[0].sessionToken, "terminal-token")

        XCTAssertEqual(records[1].path, "/base/api/tools/terminal/backend")
        XCTAssertEqual(records[1].method, "PUT")
        XCTAssertTrue(records[1].query.isEmpty)
        XCTAssertEqual(records[1].sessionToken, "terminal-token")
        let body = try XCTUnwrap(records[1].body)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: body),
            ["backend": "remote_plugin", "profile": "research"]
        )
    }

    func testMalformedOrContradictoryCatalogFailsClosed() {
        let mismatchedActive: JSONValue = [
            "active": "remote_plugin",
            "backends": [[
                "name": "remote_plugin", "label": "Remote plugin",
                "description": "", "active": false,
                "status": "ready", "detail": "",
            ]],
        ]
        XCTAssertNil(TerminalBackendCatalog(mismatchedActive))

        let unrecognizedStatus: JSONValue = [
            "active": "remote_plugin",
            "backends": [[
                "name": "remote_plugin", "label": "Remote plugin",
                "description": "", "active": true,
                "status": "future_state", "detail": "",
            ]],
        ]
        XCTAssertNil(TerminalBackendCatalog(unrecognizedStatus))
    }
}
