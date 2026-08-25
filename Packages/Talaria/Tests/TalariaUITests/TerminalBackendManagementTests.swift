import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor TerminalBackendConfigRecorder {
    private var request: URLRequest?

    func execute(_ request: URLRequest, responseLimit: Int?) async throws
        -> (Data, URLResponse) {
        self.request = request
        let payload: JSONValue
        if request.httpMethod == "GET" {
            payload = ["terminal": ["docker_shared_container_key": "trusted-team"]]
        } else {
            payload = ["ok": true]
        }
        let body = try JSONEncoder().encode(payload)
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }

    func recordedRequest() -> URLRequest? { request }
}

final class TerminalBackendManagementTests: XCTestCase {
    private let source = TerminalBackendSource(gatewayID: "home", profile: "research")

    private var catalog: TerminalBackendCatalog {
        TerminalBackendCatalog(
            active: "plugin_sandbox",
            backends: [
                TerminalBackend(
                    name: "plugin_sandbox", label: "Plugin sandbox", description: "",
                    active: true, status: .needsSetup, detail: "Needs a token."
                ),
                TerminalBackend(
                    name: "gone_runner", label: "Gone runner", description: "",
                    active: false, status: .unavailable, detail: "Removed on gateway."
                ),
            ]
        )
    }

    func testSelectionRequiresSameSourceAndGenerationAndAdmittedRow() {
        XCTAssertTrue(TerminalBackendSelectionPolicy.admits(
            backendName: "plugin_sandbox", catalog: catalog,
            snapshotSource: source, snapshotGeneration: 7,
            currentSource: source, currentGeneration: 7
        ), "needs_setup remains intentionally selectable")

        XCTAssertFalse(TerminalBackendSelectionPolicy.admits(
            backendName: "gone_runner", catalog: catalog,
            snapshotSource: source, snapshotGeneration: 7,
            currentSource: source, currentGeneration: 7
        ), "unavailable rows remain visible but cannot be selected")

        XCTAssertFalse(TerminalBackendSelectionPolicy.admits(
            backendName: "plugin_sandbox", catalog: catalog,
            snapshotSource: source, snapshotGeneration: 7,
            currentSource: TerminalBackendSource(gatewayID: "home", profile: "other"),
            currentGeneration: 7
        ))
        XCTAssertFalse(TerminalBackendSelectionPolicy.admits(
            backendName: "plugin_sandbox", catalog: catalog,
            snapshotSource: source, snapshotGeneration: 7,
            currentSource: source, currentGeneration: 8
        ))
    }

    func testCurrentUnavailableBackendStillHasAVisibleFreshSnapshot() {
        let unavailableActive = TerminalBackendCatalog(
            active: "gone_runner",
            backends: [
                TerminalBackend(
                    name: "gone_runner", label: "Gone runner", description: "",
                    active: true, status: .unavailable, detail: "Removed on gateway."
                ),
            ]
        )
        XCTAssertTrue(TerminalBackendSelectionPolicy.matchesSnapshot(
            snapshotSource: source, snapshotGeneration: 4,
            currentSource: source, currentGeneration: 4
        ))
        XCTAssertNil(unavailableActive.admittedBackend(named: "gone_runner"),
                     "The active unavailable state remains rendered, but is not a selection target.")
    }

    func testSourceKeyCannotCollideAcrossGatewayOrProfileBoundaries() {
        XCTAssertNotEqual(
            TerminalBackendSource(gatewayID: "a|b", profile: "c").key,
            TerminalBackendSource(gatewayID: "a", profile: "b|c").key
        )
        XCTAssertNotEqual(
            TerminalBackendSource(gatewayID: "home", profile: "research").key,
            TerminalBackendSource(gatewayID: "other", profile: "research").key
        )
    }

    func testSharedKeyWriteUsesProfileScopedDeepMergeLeafOnly() async throws {
        let recorder = TerminalBackendConfigRecorder()
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("config-token"),
            restExecutor: { request, limit in
                try await recorder.execute(request, responseLimit: limit)
            }
        )

        try await client.setTerminalDockerSharedContainerKey(" trusted-team ", profile: "research")
        let recorded = await recorder.recordedRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/base/api/config")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "config-token")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: body),
            [
                "profile": "research",
                "config": ["terminal": ["docker_shared_container_key": "trusted-team"]],
            ],
            "The guarded config route receives only the one terminal leaf, preserving all unknown siblings."
        )
    }

    func testSharedKeyReadUsesProfileScopedConfig() async throws {
        let recorder = TerminalBackendConfigRecorder()
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("config-token"),
            restExecutor: { request, limit in
                try await recorder.execute(request, responseLimit: limit)
            }
        )

        let key = try await client.terminalDockerSharedContainerKey(profile: "research")
        XCTAssertEqual(key, "trusted-team")
        let recorded = await recorder.recordedRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/base/api/config")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "config-token")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url),
                                                      resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "profile", value: "research")])
    }

    func testEmptySharedKeyIsAnExplicitIsolationRestore() async throws {
        let recorder = TerminalBackendConfigRecorder()
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example")),
            credential: .sessionToken("config-token"),
            restExecutor: { request, limit in
                try await recorder.execute(request, responseLimit: limit)
            }
        )

        try await client.setTerminalDockerSharedContainerKey("   ", profile: "research")
        let recorded = await recorder.recordedRequest()
        let request = try XCTUnwrap(recorded)
        let body = try XCTUnwrap(request.httpBody)
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(value["config"]?["terminal"]?["docker_shared_container_key"], .string(""))
    }
}
