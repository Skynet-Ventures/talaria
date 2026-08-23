import Foundation

/// Self-contained protocol conformance checks, runnable without XCTest via
/// `swift run talaria-verify` (Command Line Tools-only hosts included) and
/// wrapped by the XCTest target for Xcode/CI.
public enum ProtocolChecks {

    public struct CheckFailure: Error, CustomStringConvertible {
        public var description: String
    }

    static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw CheckFailure(description: "FAILED: \(label)") }
    }

    public static func runAll() throws {
        try eventEnvelopeDecoding()
        try usageParsing()
        try gatewayURLNormalization()
        try webSocketURLBuilding()
        try pkceChallengeShape()
        try tokenSetRefreshWindow()
        try demoDataIntegrity()
        try liveSessionParsing()
        try gatewayBotRouting()
        try canonicalSessionParsing()
        try rosterSearchSemantics()
        try mentionRouting()
        try agentHandleRules()
        try rosterCosmeticsSurviveRefresh()
        try unreadWatermarks()
        try toastPairing()
        try botModeNotices()
        try transcriptActing()
        try messageBranching()
    }

    static func eventEnvelopeDecoding() throws {
        let frame = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"a1b2c3d4",
         "payload":{"command":"rm -rf build","description":"Recursive delete","pattern_key":"rm",
                    "allow_permanent":true,"allow_session":true,"request_id":"9f3c",
                    "choices":["once","session","always","deny"]}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
        let params = value["params"]
        try expect(params?["type"]?.stringValue == "approval.request", "event type parses")
        let event = GatewayEvent(type: params?["type"]?.stringValue ?? "",
                                 sessionID: params?["session_id"]?.stringValue ?? "",
                                 payload: params?["payload"])
        guard case .approvalRequest(let req) = TypedGatewayEvent(event) else {
            throw CheckFailure(description: "expected approvalRequest event")
        }
        try expect(req.requestID == "9f3c", "request id")
        try expect(req.sessionID == "a1b2c3d4", "session id from envelope")
        try expect(req.choices == ["once", "session", "always", "deny"], "choices")
        try expect(req.allowPermanent, "allow_permanent")
    }

    static func usageParsing() throws {
        let json = """
        {"model":"Hermes-4-405B","input":100,"output":50,"total":9130,
         "context_used":8500,"context_max":200000,"context_percent":4}
        """
        let usage = Usage(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        try expect(usage.total == 9130, "usage total")
        try expect(usage.contextPercent == 4, "context percent")
        try expect(usage.model == "Hermes-4-405B", "usage model")
    }

    static func gatewayURLNormalization() throws {
        try expect(GatewayURL.normalize("100.84.12.9:9119")?.absoluteString == "http://100.84.12.9:9119",
                   "scheme-less input gets http:// prefix")
        try expect(GatewayURL.normalize("https://gw.example.com/hermes/")?.absoluteString == "https://gw.example.com/hermes",
                   "trailing slash stripped, path prefix kept")
        try expect(GatewayURL.normalize("") == nil, "empty input rejected")
        try expect(GatewayURL.normalize("ftp://x") == nil, "non-http scheme rejected")
    }

    static func webSocketURLBuilding() throws {
        let base = GatewayURL.normalize("https://gw.example.com/prefix")!
        let url = GatewayURL.webSocket(base: base, query: URLQueryItem(name: "ticket", value: "T"))
        try expect(url?.absoluteString == "wss://gw.example.com/prefix/api/ws?ticket=T",
                   "https → wss with path prefix preserved")

        let local = GatewayURL.normalize("100.84.12.9:9119")!
        let localWS = GatewayURL.webSocket(base: local, query: URLQueryItem(name: "token", value: "S"))
        try expect(localWS?.absoluteString == "ws://100.84.12.9:9119/api/ws?token=S",
                   "http → ws with token query")
    }

    static func pkceChallengeShape() throws {
        let flow = NativePKCEFlow()
        try expect(!flow.codeVerifier.isEmpty, "verifier non-empty")
        try expect(!flow.codeChallenge.contains("="), "challenge is base64url unpadded")
        try expect(!flow.codeChallenge.contains("+"), "challenge has no +")
        try expect(!flow.codeChallenge.contains("/"), "challenge has no /")
        try expect(flow.codeVerifier != NativePKCEFlow().codeVerifier, "verifiers never collide")
    }

    static func tokenSetRefreshWindow() throws {
        let fresh = TokenSet(accessToken: "a", refreshToken: "r",
                             expiresAt: Date().timeIntervalSince1970 + 3600,
                             provider: "nous", userID: nil)
        try expect(!fresh.needsRefresh, "fresh token needs no refresh")
        let stale = TokenSet(accessToken: "a", refreshToken: "r",
                             expiresAt: Date().timeIntervalSince1970 + 30,
                             provider: "nous", userID: nil)
        try expect(stale.needsRefresh, "refresh at expiresAt - 60s like desktop")
    }

    static func demoDataIntegrity() throws {
        try expect(DemoData.bots.count == 6, "6 demo bots")
        try expect(DemoData.approvals.count == 3, "3 demo approvals")
        let ids = Set(DemoData.bots.map(\.id))
        for a in DemoData.approvals { try expect(ids.contains(a.botID), "approval \(a.id) references roster bot") }
        for r in DemoData.routines { try expect(ids.contains(r.botID), "routine \(r.id) references roster bot") }
        for a in DemoData.artifacts { try expect(ids.contains(a.botID), "artifact \(a.id) references roster bot") }
    }

    static func liveSessionParsing() throws {
        let json = """
        {"session_id":"a1b2c3d4","stored_session_id":"6c1f00aa","message_count":0,
         "messages":[],"running":false,
         "info":{"model":"Hermes-4-405B","yolo":false,"desktop_contract":6,"profile_name":"researcher"}}
        """
        let live = LiveSession(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        try expect(live.sessionID == "a1b2c3d4", "runtime sid")
        try expect(live.storedSessionID == "6c1f00aa", "durable key")
        try expect(live.info.desktopContract == 6, "desktop contract v6")
        try expect(live.info.profileName == "researcher", "profile name")
        try expect(live.pendingApproval == nil, "no pending approval")
    }
}
