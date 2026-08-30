#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor MCPToolFilterRESTServer {
    struct RequestRecord: Sendable {
        var method: String?
        var path: String
        var profile: String?
        var body: JSONValue?
    }

    private let config: JSONValue
    private var records: [RequestRecord] = []

    init(config: JSONValue) {
        self.config = config
    }

    func requests() -> [RequestRecord] { records }

    func execute(_ request: URLRequest, responseLimit _: Int?) async throws
        -> (Data, URLResponse) {
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        records.append(RequestRecord(
            method: request.httpMethod,
            path: request.url?.path ?? "",
            profile: components?.queryItems?.first(where: { $0.name == "profile" })?.value,
            body: body))

        let payload: JSONValue = request.httpMethod == "GET" ? config : ["ok": true]
        let data = try JSONEncoder().encode(payload)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        return (data, response)
    }
}

final class MCPToolFilterCapabilityTests: XCTestCase {
    func testExplicitEmptyIncludeRoundTripsAsAnEmptyWhitelist() throws {
        let raw: JSONValue = [
            "include": [],
            "future_gateway_key": ["keep": true],
        ]
        let filter = MCPToolFilter(raw)

        XCTAssertEqual(filter.mode, .include)
        XCTAssertEqual(filter.patterns, [])
        let rewritten = try filter.applying(to: raw)
        XCTAssertEqual(rewritten?["include"], .array([]))
        XCTAssertNil(rewritten?["exclude"])
        XCTAssertEqual(rewritten?["future_gateway_key"], ["keep": true])
    }

    func testLegacyBareAllowListRemainsReadableAndUpgradesOnlyOnAnExplicitEdit() throws {
        let legacy: JSONValue = ["alpha", "beta"]
        let filter = MCPToolFilter(legacy)

        XCTAssertEqual(filter.mode, .include)
        XCTAssertEqual(filter.patterns, ["alpha", "beta"])
        let rewritten = try filter.applying(to: legacy)
        XCTAssertEqual(rewritten, ["include": ["alpha", "beta"]])
    }

    func testSingleStringFilterRemainsACompatibleOnePatternMode() throws {
        let raw: JSONValue = ["exclude": "*_secret_*"]
        let filter = MCPToolFilter(raw)

        XCTAssertEqual(filter.mode, .exclude)
        XCTAssertEqual(filter.patterns, ["*_secret_*"])
        XCTAssertEqual(try filter.applying(to: raw), raw)
    }

    func testExcludeGlobPatternsStayInExcludeModeWithoutGeneratingIncludeRows() throws {
        let raw: JSONValue = [
            "exclude": ["*_secret_*", "legacy_tool"],
            "future_gateway_key": "preserve me",
        ]
        let filter = MCPToolFilter(raw)
        let draft = MCPToolFilterEditorDraft(filter: filter)

        XCTAssertEqual(filter.mode, .exclude)
        XCTAssertEqual(draft.mode, .exclude)
        XCTAssertEqual(draft.patterns, ["*_secret_*", "legacy_tool"])

        let rewritten = try draft.filter.applying(to: raw)
        XCTAssertEqual(rewritten?["exclude"], .array(["*_secret_*", "legacy_tool"]))
        XCTAssertNil(rewritten?["include"])
        XCTAssertEqual(rewritten?["future_gateway_key"], .string("preserve me"))
    }

    func testMalformedFutureFilterIsLeftUnavailableRatherThanCompactedOrOverwritten() {
        let raw: JSONValue = ["include": ["known", 7]]
        let filter = MCPToolFilter(raw)

        XCTAssertEqual(filter.mode, .unavailable)
        XCTAssertFalse(filter.isEditable)
        XCTAssertThrowsError(try filter.applying(to: raw))
    }

    func testMalformedCompetingFilterIsAlsoPreservedInsteadOfBeingSilentlyDropped() {
        let raw: JSONValue = ["include": ["known"], "exclude": 7]
        let filter = MCPToolFilter(raw)

        XCTAssertEqual(filter.mode, .unavailable)
        XCTAssertThrowsError(try filter.applying(to: raw))
    }

    @MainActor
    func testInconclusiveServerListRetainsPriorExcludeFilterButAuthoritativeListReplacesIt() {
        let prior = MCPServer(
            name: "cloudflare", transport: "http", url: "https://mcp.cloudflare.com/mcp",
            toolFilter: MCPToolFilter(mode: .exclude, patterns: ["*_secret_*"]))

        let retained = AppModel.mcpServers(after: .failed("OAuth pending"), retaining: [prior])
        XCTAssertEqual(retained, [prior])

        let fresh = MCPServer(name: "cloudflare", transport: "http",
                              url: "https://mcp.cloudflare.com/mcp",
                              toolFilter: MCPToolFilter(mode: .include, patterns: []))
        let replaced = AppModel.mcpServers(after: .value([fresh]), retaining: [prior])
        XCTAssertEqual(replaced, [fresh])
    }

    func testCatalogInstallUsesTheServerOwnedFilterAwareInstaller() async throws {
        let server = MCPToolFilterRESTServer(config: [:])
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://mcp-catalog-install.example")),
            credential: .sessionToken("mcp-catalog-install-test"),
            restExecutor: { request, limit in
                try await server.execute(request, responseLimit: limit)
            })

        try await client.mcpAddFromCatalog(profile: "research", name: "cloudflare")

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].path, "/api/mcp/catalog/install")
        XCTAssertEqual(requests[0].profile, "research")
        XCTAssertEqual(requests[0].body, ["name": "cloudflare", "enable": true])
    }

    func testRESTWriteUsesFreshRawConfigAndPreservesUnknownServerValues() async throws {
        let config: JSONValue = [
            "mcp_servers": [
                "cloudflare": [
                    "url": "https://mcp.cloudflare.com/mcp",
                    "headers": ["Authorization": "Bearer ${CLOUDFLARE_TOKEN}"],
                    "future_server_key": ["revision": 3],
                    "tools": [
                        "exclude": ["*_secret_*", "legacy_tool"],
                        "future_tools_key": ["opaque": true],
                    ],
                ],
                "other": [
                    "command": "npx",
                    "args": ["-y", "other-server"],
                    "future_other_key": "untouched",
                ],
            ],
        ]
        let server = MCPToolFilterRESTServer(config: config)
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://mcp-filter.example/base/")),
            credential: .sessionToken("mcp-filter-test"),
            restExecutor: { request, limit in
                try await server.execute(request, responseLimit: limit)
            })

        try await client.setMCPToolFilter(
            profile: "research", name: "cloudflare",
            filter: MCPToolFilter(mode: .exclude,
                                  patterns: ["*_secret_*", "manual_block"]))

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].path, "/base/api/config")
        XCTAssertEqual(requests[0].profile, "research")
        XCTAssertEqual(requests[1].method, "PUT")
        XCTAssertEqual(requests[1].path, "/base/api/mcp/servers")
        XCTAssertEqual(requests[1].profile, "research")

        let servers = try XCTUnwrap(requests[1].body?["servers"]?.objectValue)
        let cloudflare = try XCTUnwrap(servers["cloudflare"]?.objectValue)
        let tools = try XCTUnwrap(cloudflare["tools"]?.objectValue)
        XCTAssertEqual(tools["exclude"], .array(["*_secret_*", "manual_block"]))
        XCTAssertNil(tools["include"])
        XCTAssertEqual(tools["future_tools_key"], ["opaque": true])
        XCTAssertEqual(cloudflare["headers"], ["Authorization": "Bearer ${CLOUDFLARE_TOKEN}"])
        XCTAssertEqual(cloudflare["future_server_key"], ["revision": 3])
        XCTAssertEqual(servers["other"]?["future_other_key"], .string("untouched"))
    }

    func testRESTWriteKeepsExplicitEmptyIncludeInTheWholeMapPayload() async throws {
        let config: JSONValue = [
            "mcp_servers": [
                "catalog": [
                    "url": "https://catalog.example/mcp",
                    "tools": ["exclude": ["previous"]],
                ],
            ],
        ]
        let server = MCPToolFilterRESTServer(config: config)
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://mcp-filter-empty.example")),
            credential: .sessionToken("mcp-filter-empty-test"),
            restExecutor: { request, limit in
                try await server.execute(request, responseLimit: limit)
            })

        try await client.setMCPToolFilter(
            profile: nil, name: "catalog",
            filter: MCPToolFilter(mode: .include, patterns: []))

        let requests = await server.requests()
        let payload = try XCTUnwrap(requests.last?.body)
        let tools = try XCTUnwrap(payload["servers"]?["catalog"]?["tools"]?.objectValue)
        XCTAssertEqual(tools["include"], .array([]))
        XCTAssertNil(tools["exclude"])
    }
}
#endif
