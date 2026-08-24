import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private struct RecordedModelRequest: Sendable {
    var method: String
    var url: URL
    var body: Data?
}

private actor ModelRequestRecorder {
    private var values: [RecordedModelRequest] = []

    func append(_ request: URLRequest) {
        values.append(RecordedModelRequest(
            method: request.httpMethod ?? "GET", url: request.url!, body: request.httpBody))
    }

    func snapshot() -> [RecordedModelRequest] { values }
}

final class ModelManagementContractTests: XCTestCase {
    func testAuxiliaryInventoryIsBoundedAndRejectsMalformedWritableIdentities() {
        var tasks: [JSONValue] = [
            .object(["task": "vision", "provider": "auto", "model": "",
                     "base_url": ""]),
            .object(["task": "vision", "provider": "duplicate", "model": "bad",
                     "base_url": ""]),
            .object(["task": "bad\nslot", "provider": "auto", "model": "",
                     "base_url": ""]),
        ]
        tasks += (0..<40).map { index in
            .object(["task": .string("slot-\(index)"), "provider": "auto",
                     "model": "", "base_url": ""])
        }
        let decoded = AuxiliaryModelInventory(.object([
            "tasks": .array(tasks),
            "main": .object(["provider": "openrouter", "model": "anthropic/opus"]),
        ]))

        XCTAssertLessThanOrEqual(decoded.tasks.count, AuxiliaryModelInventory.maximumTasks)
        XCTAssertEqual(decoded.tasks.filter { $0.task == "vision" }.count, 1)
        XCTAssertFalse(decoded.tasks.contains { $0.task.contains("\n") })
        XCTAssertEqual(decoded.mainProvider, "openrouter")
        XCTAssertEqual(decoded.mainModel, "anthropic/opus")

        let outcome = AuxiliaryModelAssignmentOutcome(.object([
            "ok": true,
            "tasks": .array(["vision", "bad\nslot"]),
            "provider": "unsafe\u{202e}",
            "model": .string(String(repeating: "m", count: 1_025)),
            "confirm_message": "Review this model.",
        ]))
        XCTAssertEqual(outcome.tasks, ["vision"])
        XCTAssertEqual(outcome.provider, "")
        XCTAssertEqual(outcome.model, "")
        XCTAssertEqual(outcome.confirmMessage, "Review this model.")
    }

    func testCurrentHermesAuxiliaryAndMoARoutesAreProfileScopedAndExact() async throws {
        let recorder = ModelRequestRecorder()
        let base = try XCTUnwrap(URL(string: "https://gateway.example/root/"))
        let client = GatewayClient(
            baseURL: base, credential: .sessionToken("token"),
            restExecutor: { request, _ in
                await recorder.append(request)
                let path = request.url?.path ?? ""
                let payload: JSONValue
                if path.hasSuffix("/api/model/auxiliary") {
                    payload = .object([
                        "tasks": .array([.object([
                            "task": "vision", "provider": "auto", "model": "",
                            "base_url": "",
                        ])]),
                        "main": .object(["provider": "openrouter", "model": "opus"]),
                    ])
                } else if path.hasSuffix("/api/model/moa") {
                    payload = .object(["default_preset": "balanced", "presets": .object([:])])
                } else {
                    payload = .object([
                        "ok": true, "scope": "auxiliary", "tasks": ["vision"],
                        "provider": "openrouter", "model": "vision-model",
                    ])
                }
                let data = try JSONEncoder().encode(payload)
                return (data, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!)
            })

        let inventory = try await client.auxiliaryModelInventory(profile: "research")
        XCTAssertEqual(inventory.tasks.map(\.task), ["vision"])
        _ = try await client.assignAuxiliaryModel(
            task: "vision", provider: "openrouter", model: "vision-model",
            profile: " research ")
        _ = try await client.resetAuxiliaryModels(profile: "research")
        let moa = try await client.moaModelConfiguration(profile: "research")
        XCTAssertEqual(moa["default_preset"]?.stringValue, "balanced")

        let requests = await recorder.snapshot()
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "POST", "GET"])
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/root/api/model/auxiliary", "/root/api/model/set",
            "/root/api/model/set", "/root/api/model/moa",
        ])
        XCTAssertTrue(requests.allSatisfy {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(URLQueryItem(name: "profile", value: "research")) == true
        })

        let assign = try XCTUnwrap(requests[1].body).decodedJSONValue
        XCTAssertEqual(assign["scope"], "auxiliary")
        XCTAssertEqual(assign["task"], "vision")
        XCTAssertEqual(assign["profile"], "research")
        let reset = try XCTUnwrap(requests[2].body).decodedJSONValue
        XCTAssertEqual(reset["task"], "__reset__")
    }
}

private extension Data {
    var decodedJSONValue: JSONValue {
        get throws { try JSONDecoder().decode(JSONValue.self, from: self) }
    }
}
