import Foundation
import XCTest
@testable import TalariaKit

final class StoredTranscriptPageTests: XCTestCase {
    private func row(_ id: Int, text: String, compacted: Bool = false) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .number(Double(id)),
            "role": .string("user"),
            "content": .string(text),
            "timestamp": .number(Double(1_700_000_000 + id)),
        ]
        if compacted {
            // SQLite's `compacted` column reaches REST JSON as 0/1, rather
            // than the Bool spelling used by some future projections.
            value["compacted"] = .number(1)
            value["active"] = .number(0)
        }
        return .object(value)
    }

    private func currentPayload(sessionID: String = "tip",
                                rows: [JSONValue], limit: Int, offset: Int,
                                total: Int? = nil, hasMore: Bool? = nil,
                                incomplete: Bool? = nil,
                                order: String = "latest",
                                returned: Int? = nil,
                                includeCompacted: Bool? = nil) -> JSONValue {
        var pagination: [String: JSONValue] = [
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset)),
            "order": .string(order),
            "returned": .number(Double(returned ?? rows.count)),
        ]
        if let total { pagination["total"] = .number(Double(total)) }
        if let hasMore { pagination["has_more"] = .bool(hasMore) }
        if let incomplete { pagination["incomplete"] = .bool(incomplete) }
        if let includeCompacted { pagination["include_compacted"] = .bool(includeCompacted) }
        return [
            "session_id": .string(sessionID),
            "messages": .array(rows),
            "pagination": .object(pagination),
        ]
    }

    private func protocolFailure(_ work: () throws -> Void, file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual((error as? GatewayError)?.code, -8, file: file, line: line)
        }
    }

    func testFullAndShortPagesKeepChronologicalOrderAndContinuationTruth() throws {
        let request = StoredTranscriptPageRequest(
            storedSessionID: "root", profile: "research", offset: 0, limit: 2)
        let full = try StoredTranscriptPage(
            payload: currentPayload(rows: [row(41, text: "older"), row(42, text: "newer")],
                                    limit: 2, offset: 0, total: 6, hasMore: true,
                                    incomplete: true),
            request: request)

        XCTAssertEqual(full.rows.map(\.rowID), [41, 42])
        XCTAssertEqual(full.messages.map { $0["content"]?.stringValue }, ["older", "newer"])
        XCTAssertEqual(full.order, .latest)
        XCTAssertEqual(full.total, 6)
        XCTAssertEqual(full.pagination.continuation, .more)
        XCTAssertTrue(full.hasMore)
        XCTAssertTrue(full.incomplete)
        XCTAssertEqual(full.nextOffset, 2)

        let shortRequest = StoredTranscriptPageRequest(
            storedSessionID: "root", profile: "research", offset: 2, limit: 2)
        let short = try StoredTranscriptPage(
            payload: currentPayload(rows: [row(40, text: "oldest")], limit: 2, offset: 2,
                                    total: 3, hasMore: false, incomplete: false),
            request: shortRequest)

        XCTAssertEqual(short.rows.map(\.rowID), [40])
        XCTAssertEqual(short.pagination.continuation, .complete)
        XCTAssertFalse(short.hasMore)
        XCTAssertTrue(short.hasKnownContinuation)
        XCTAssertFalse(short.incomplete)
        XCTAssertNil(short.nextOffset)
    }

    func testFullPageWithoutNewerControlsRemainsUnknownRatherThanClaimingMore() throws {
        let request = StoredTranscriptPageRequest(storedSessionID: "root", offset: 0, limit: 2)
        let page = try StoredTranscriptPage(
            payload: currentPayload(rows: [row(4, text: "a"), row(5, text: "b")],
                                    limit: 2, offset: 0),
            request: request)

        XCTAssertEqual(page.pagination.continuation, .unknown)
        XCTAssertFalse(page.hasMore, "unknown is not an affirmative continuation")
        XCTAssertFalse(page.hasKnownContinuation)
        XCTAssertTrue(page.incomplete, "a full page can still be the end")
        XCTAssertEqual(page.nextOffset, 2)
    }

    func testStableDurableIDsAreReadyForOverlappingPagesAndSourceFences() throws {
        let source = StoredTranscriptPageSource(
            gatewayID: "gateway-a", profile: "research", storedSessionID: "root")
        let first = try StoredTranscriptPage(
            payload: currentPayload(rows: [row(30, text: "c"), row(31, text: "d")],
                                    limit: 2, offset: 0, total: 4, hasMore: true),
            request: StoredTranscriptPageRequest(source: source, offset: 0, limit: 2))
        // An append can land between reverse-page reads. The next response may
        // overlap the retained tail, so exact durable ids—not text—are what a
        // future ledger will use to dedupe it.
        let older = try StoredTranscriptPage(
            payload: currentPayload(rows: [row(28, text: "a"), row(30, text: "c")],
                                    limit: 2, offset: 2, total: 5, hasMore: true),
            request: StoredTranscriptPageRequest(source: source, offset: 2, limit: 2))

        let overlap = Set(first.rows.compactMap(\.identity))
            .intersection(Set(older.rows.compactMap(\.identity)))
        XCTAssertEqual(overlap, [.integer(30)])
        XCTAssertTrue(first.matches(source))
        XCTAssertFalse(first.matches(StoredTranscriptPageSource(
            gatewayID: "gateway-b", profile: "research", storedSessionID: "root")))
        XCTAssertFalse(first.matches(StoredTranscriptPageSource(
            gatewayID: "gateway-a", profile: "other", storedSessionID: "root")))
    }

    func testLegacyMissingPaginationIsOneBoundedCompleteRead() throws {
        let request = StoredTranscriptPageRequest(storedSessionID: "root", offset: 200, limit: 200)
        let page = try StoredTranscriptPage(payload: [
            "messages": .array([row(1, text: "first"), row(2, text: "second")]),
        ], request: request)

        XCTAssertFalse(page.hasPagingMetadata)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.limit, 2)
        XCTAssertEqual(page.returned, 2)
        XCTAssertNil(page.total)
        XCTAssertEqual(page.pagination.continuation, .complete)
        XCTAssertFalse(page.incomplete)
        XCTAssertEqual(page.resolvedSessionID, "root")
        XCTAssertFalse(page.resolvedSessionIDWasEchoed)
    }

    func testMalformedOrConflictingEchoNeverBecomesAUsablePage() throws {
        let request = StoredTranscriptPageRequest(storedSessionID: "root", offset: 4, limit: 2)
        let rows = [row(1, text: "one"), row(2, text: "two")]

        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: rows, limit: 3, offset: 4), request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: rows, limit: 2, offset: 0), request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: rows, limit: 2, offset: 4, order: "oldest"),
                request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: rows, limit: 2, offset: 4, returned: 1),
                request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: rows, limit: 2, offset: 4,
                                             total: 9, hasMore: false), request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(payload: [
                "session_id": "tip",
                "messages": .array(rows),
                "pagination": ["limit": 2, "offset": 4, "order": "latest"],
            ], request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(sessionID: "tip\u{202e}", rows: rows,
                                             limit: 2, offset: 4),
                request: request)
        }
        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: [
                    .object(["id": .string(String(repeating: "x", count: 1_025)),
                             "role": "user", "content": "oversized identity"]),
                ], limit: 2, offset: 4, returned: 1),
                request: request)
        }
    }

    func testRequestAndResponseCapsFailBeforeAHostileTranscriptCanGrow() throws {
        let normalized = StoredTranscriptPageRequest(
            storedSessionID: "root", offset: Int.max, limit: Int.max)
        XCTAssertEqual(normalized.offset, StoredTranscriptPageRequest.maximumOffset)
        XCTAssertEqual(normalized.limit, StoredTranscriptPageRequest.maximumLimit)

        let oversizedRows = (0...StoredTranscriptPage.maximumRows).map {
            row($0, text: "row-\($0)")
        }
        protocolFailure {
            _ = try StoredTranscriptPage(payload: ["messages": .array(oversizedRows)],
                                         request: normalized)
        }

        protocolFailure {
            _ = try StoredTranscriptPage(
                payload: self.currentPayload(rows: [], limit: 501, offset: 0),
                request: StoredTranscriptPageRequest(storedSessionID: "root", limit: 500))
        }
    }

    func testCompactedEvidenceAndResolvedTipDoNotRewriteRootIdentity() throws {
        let source = StoredTranscriptPageSource(
            gatewayID: "gateway", profile: "bot", storedSessionID: "root-session")
        let page = try StoredTranscriptPage(
            payload: currentPayload(sessionID: "tip-session", rows: [
                row(1, text: "before compaction", compacted: true),
                row(2, text: "current"),
            ], limit: 2, offset: 0, total: 2, hasMore: false),
            request: StoredTranscriptPageRequest(source: source, offset: 0, limit: 2,
                                                  includeCompacted: true))

        XCTAssertEqual(page.requestedSessionID, "root-session")
        XCTAssertEqual(page.resolvedSessionID, "tip-session")
        XCTAssertTrue(page.resolvedSessionIDWasEchoed)
        XCTAssertTrue(page.includesCompacted)
        XCTAssertTrue(page.hasCompactedRows)
        XCTAssertTrue(page.rows[0].isCompacted)
        XCTAssertEqual(page.rows[0].raw["active"]?.intValue, 0)
    }

    func testClientUsesExactLatestCompactedRequestAndRejectsOversizeExecutorBody() async throws {
        actor Capture {
            var request: URLRequest?
            var responseLimit: Int?

            func record(_ request: URLRequest, responseLimit: Int?) {
                self.request = request
                self.responseLimit = responseLimit
            }
        }

        let capture = Capture()
        let oversized = Data(repeating: 0, count: StoredTranscriptPage.maximumResponseBytes + 1)
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example/base")),
            credential: .sessionToken("test"),
            restExecutor: { request, responseLimit in
                await capture.record(request, responseLimit: responseLimit)
                return (oversized, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!)
            })
        let request = StoredTranscriptPageRequest(
            storedSessionID: "root-1", profile: "bot", offset: 240, limit: 50,
            includeCompacted: true)

        do {
            _ = try await client.storedTranscriptPage(request)
            XCTFail("oversize response must fail before JSON decoding")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, -8)
        }

        let sent = await capture.request
        let sentURL = try XCTUnwrap(sent?.url)
        let components = try XCTUnwrap(URLComponents(url: sentURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/base/api/sessions/root-1/messages")
        XCTAssertEqual(components.queryItems?.map { "\($0.name)=\($0.value ?? "")" }, [
            "profile=bot",
            "limit=50",
            "offset=240",
            "order=latest",
            "include_compacted=true",
        ])
        let responseLimit = await capture.responseLimit
        XCTAssertEqual(responseLimit, StoredTranscriptPage.maximumResponseBytes)

        let invalid = StoredTranscriptPageRequest(storedSessionID: "root/other")
        do {
            _ = try await client.storedTranscriptPage(invalid)
            XCTFail("a path-separator session id must fail before REST")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, -11)
        }
        for hostile in ["root\\other", "root\u{202e}", String(repeating: "x", count: 1_025)] {
            do {
                _ = try await client.storedTranscriptPage(
                    StoredTranscriptPageRequest(storedSessionID: hostile))
                XCTFail("a hostile session id must fail before REST")
            } catch let error as GatewayError {
                XCTAssertEqual(error.code, -11)
            }
        }
    }
}
