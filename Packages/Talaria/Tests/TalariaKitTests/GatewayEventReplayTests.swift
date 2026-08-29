#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class GatewayEventReplayTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []
        func append(_ value: UInt64) { lock.withLock { storage.append(value) } }
        var values: [UInt64] { lock.withLock { storage } }
    }
    private func page(
        events: [JSONValue], latest: Int, truncated: Bool = false,
        count: Int? = nil, epoch: String = "epoch-a"
    ) -> JSONValue {
        .object([
            "events": .array(events),
            "latest_seq": .number(Double(latest)),
            "truncated": .bool(truncated),
            "count": .number(Double(count ?? events.count)),
            "epoch": .string(epoch),
        ])
    }

    private func event(_ sequence: Int, sessionID: String = "s1") -> JSONValue {
        .object([
            "type": .string("message.delta"),
            "session_id": .string(sessionID),
            "seq": .number(Double(sequence)),
            "payload": .object(["text": .string("\(sequence)")]),
        ])
    }

    func testDecodesContiguousBareSameEpochSuffixInWireOrder() throws {
        let decoded = try XCTUnwrap(GatewayReplayCodec.decode(
            page(events: [event(4), event(5)], latest: 5),
            sessionID: "s1", lastSeen: 3, expectedEpoch: "epoch-a"))
        XCTAssertEqual(decoded.events.compactMap(\.sequence), [4, 5])
        XCTAssertNil(decoded.issue)
    }

    func testTransportAdmitsOnlyExactPositiveSequenceAndBoundedEpoch() {
        XCTAssertEqual(GatewayTransport.admittedSequence(.number(7)), 7)
        XCTAssertNil(GatewayTransport.admittedSequence(.number(0)))
        XCTAssertNil(GatewayTransport.admittedSequence(.number(7.5)))
        XCTAssertNil(GatewayTransport.admittedSequence(.string("7")))
        XCTAssertEqual(GatewayTransport.admittedReplayEpoch(.string(" epoch-a ")),
                       "epoch-a")
        XCTAssertNil(GatewayTransport.admittedReplayEpoch(.string("")))
        XCTAssertNil(GatewayTransport.admittedReplayEpoch(
            .string(String(repeating: "x", count: 257))))
    }

    func testReplayStatsRejectMalformedOrImpossibleOccupancy() throws {
        let stats = try XCTUnwrap(GatewayReplayStats.decode([
            "sessions": 2, "events": 9, "max_per_session": 512,
        ]))
        XCTAssertEqual(stats, GatewayReplayStats(
            sessions: 2, events: 9, maximumPerSession: 512))
        XCTAssertNil(GatewayReplayStats.decode([
            "sessions": 2, "events": 1_025, "max_per_session": 512,
        ]))
        XCTAssertNil(GatewayReplayStats.decode([
            "sessions": 1.5, "events": 1, "max_per_session": 512,
        ]))
    }

    func testEpochDispositionFailsClosedAcrossRestartAndOldGateway() {
        XCTAssertEqual(GatewayReplayCodec.epochDisposition(
            previous: "a", current: "a", hasWatermarks: true), .replay("a"))
        XCTAssertEqual(GatewayReplayCodec.epochDisposition(
            previous: "a", current: "b", hasWatermarks: true), .restarted("b"))
        XCTAssertEqual(GatewayReplayCodec.epochDisposition(
            previous: "a", current: nil, hasWatermarks: true), .unsupported)
        XCTAssertEqual(GatewayReplayCodec.epochDisposition(
            previous: nil, current: "b", hasWatermarks: false), .noGap)
    }

    func testRejectsEnvelopeWrongSessionGapCountEpochAndFractionalSequence() {
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": event(4),
        ])
        let cases: [JSONValue] = [
            page(events: [envelope], latest: 4),
            page(events: [event(4, sessionID: "other")], latest: 4),
            page(events: [event(5)], latest: 5),
            page(events: [event(4)], latest: 4, count: 2),
            page(events: [event(4)], latest: 4, epoch: "epoch-b"),
            page(events: [.object([
                "type": .string("message.delta"), "session_id": .string("s1"),
                "seq": .number(4.5),
            ])], latest: 4),
        ]
        for candidate in cases {
            XCTAssertNil(GatewayReplayCodec.decode(
                candidate, sessionID: "s1", lastSeen: 3,
                expectedEpoch: "epoch-a"))
        }
    }

    func testTruncationIsAdmittedButExplicitlyUncertain() throws {
        let decoded = try XCTUnwrap(GatewayReplayCodec.decode(
            page(events: [event(90), event(91)], latest: 91, truncated: true),
            sessionID: "s1", lastSeen: 12, expectedEpoch: "epoch-a"))
        XCTAssertEqual(decoded.events.compactMap(\.sequence), [90, 91])
        XCTAssertEqual(decoded.issue, .truncated)
    }

    func testPreparedReplayFanoutExcludesPrimaryAndCommitsWatermark() async throws {
        let client = GatewayClient(
            baseURL: URL(string: "https://replay.example")!,
            credential: .sessionToken("test"))
        await client.setForegroundReadinessForTesting(true)
        let ordinary = Recorder()
        let primary = Recorder()
        let auxiliary = Recorder()
        _ = await client.addEventHandler { event in
            ordinary.append(event.sequence ?? 0)
        }
        let primaryID = await client.addEpochEventHandler { event, _ in
            primary.append(event.sequence ?? 0)
        }
        _ = await client.addEpochEventHandler { event, _ in
            auxiliary.append(event.sequence ?? 0)
        }
        await client.installPreparedReplayForTesting(events: [
            GatewayEvent(type: "message.delta", sessionID: "s1",
                         payload: ["text": "a"], sequence: 4),
            GatewayEvent(type: "message.delta", sessionID: "s1",
                         payload: ["text": "b"], sequence: 5),
        ], certainty: .complete)

        let prepared = await client.prepareCurrentTransportForEvents()
        let publication = try XCTUnwrap(prepared)
        let committed = await client.commitPreparedReplay(
            publication.token, excludingEpochHandler: primaryID)
        let watermarks = await client.replayWatermarksForTesting()
        XCTAssertTrue(committed)
        XCTAssertEqual(ordinary.values, [4, 5])
        XCTAssertEqual(primary.values, [])
        XCTAssertEqual(auxiliary.values, [4, 5])
        XCTAssertEqual(watermarks, ["s1": 5])
    }

    func testReplayLiveOverlapIsDeliveredExactlyOnceAndStaleCommitIsRejected() async throws {
        let client = GatewayClient(
            baseURL: URL(string: "https://replay-overlap.example")!,
            credential: .sessionToken("test"))
        await client.setForegroundReadinessForTesting(true)
        await client.installPreparedReplayForTesting(events: [
            GatewayEvent(type: "message.delta", sessionID: "s1",
                         payload: ["text": "3"], sequence: 3),
            GatewayEvent(type: "message.delta", sessionID: "s1",
                         payload: ["text": "4"], sequence: 4),
            GatewayEvent(type: "message.delta", sessionID: "s1",
                         payload: ["text": "5"], sequence: 5),
        ], certainty: .complete)
        let prepared = await client.prepareCurrentTransportForEvents()
        let publication = try XCTUnwrap(prepared)
        let committed = await client.commitPreparedReplay(
            publication.token, excludingEpochHandler: nil)
        let duplicate = await client.admitLiveEventForTesting(GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 5))
        let next = await client.admitLiveEventForTesting(GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 6))
        let overlapWatermarks = await client.replayWatermarksForTesting()
        XCTAssertTrue(committed)
        XCTAssertFalse(duplicate)
        XCTAssertTrue(next)
        XCTAssertEqual(overlapWatermarks, ["s1": 6])

        let gap = await client.admitLiveEventForTesting(GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 8))
        XCTAssertFalse(gap, "a same-epoch live gap must retire rather than reorder")

        await client.installPreparedReplayForTesting(events: [GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 7)],
            certainty: .complete)
        let stalePrepared = await client.prepareCurrentTransportForEvents()
        let stale = try XCTUnwrap(stalePrepared)
        _ = await client.advanceTransportEpochForTesting()
        let staleCommitted = await client.commitPreparedReplay(
            stale.token, excludingEpochHandler: nil)
        let finalWatermarks = await client.replayWatermarksForTesting()
        XCTAssertFalse(staleCommitted)
        XCTAssertEqual(finalWatermarks, ["s1": 6])
    }

    func testWatermarksRetainExactHermesSessionRingBound() async throws {
        let client = GatewayClient(
            baseURL: URL(string: "https://replay-session-bound.example")!,
            credential: .sessionToken("test"))
        await client.setForegroundReadinessForTesting(true)
        await client.installPreparedReplayForTesting(events: [GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 1)],
            certainty: .complete)
        let prepared = await client.prepareCurrentTransportForEvents()
        let publication = try XCTUnwrap(prepared)
        let committed = await client.commitPreparedReplay(
            publication.token, excludingEpochHandler: nil)
        XCTAssertTrue(committed)

        for index in 2...65 {
            let admitted = await client.admitLiveEventForTesting(GatewayEvent(
                type: "message.delta", sessionID: "s\(index)",
                payload: nil, sequence: 1))
            XCTAssertTrue(admitted)
        }

        let watermarks = await client.replayWatermarksForTesting()
        XCTAssertEqual(watermarks.count, 64)
        XCTAssertNil(watermarks["s1"])
        XCTAssertEqual(watermarks["s65"], 1)
    }

    func testUncertainSessionRetiresOldCursorInsteadOfReconnectLoop() async throws {
        let client = GatewayClient(
            baseURL: URL(string: "https://replay-failed-page.example")!,
            credential: .sessionToken("test"))
        await client.setForegroundReadinessForTesting(true)
        await client.installPreparedReplayForTesting(events: [GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 5)],
            certainty: .complete)
        var prepared = await client.prepareCurrentTransportForEvents()
        var publication = try XCTUnwrap(prepared)
        var committed = await client.commitPreparedReplay(
            publication.token, excludingEpochHandler: nil)
        XCTAssertTrue(committed)

        await client.installPreparedReplayForTesting(
            events: [], certainty: .uncertain([.requestFailed]),
            retiredSessionIDs: ["s1"])
        prepared = await client.prepareCurrentTransportForEvents()
        publication = try XCTUnwrap(prepared)
        committed = await client.commitPreparedReplay(
            publication.token, excludingEpochHandler: nil)
        let watermarks = await client.replayWatermarksForTesting()
        let admitted = await client.admitLiveEventForTesting(GatewayEvent(
            type: "message.delta", sessionID: "s1", payload: nil, sequence: 100))
        XCTAssertTrue(committed)
        XCTAssertTrue(watermarks.isEmpty)
        XCTAssertTrue(admitted)
    }

    func testParkingOverflowIsGloballyObservable() async {
        let transport = GatewayTransport(
            url: URL(string: "wss://replay-overflow.example/ws")!)
        for index in 1...(GatewayReplayCodec.maximumTotalEvents + 1) {
            await transport.enqueueEventForTesting(GatewayEvent(
                type: "message.delta", sessionID: "new-session",
                payload: nil, sequence: UInt64(index)))
        }
        let overflowed = await transport.replayBufferOverflowed
        XCTAssertTrue(overflowed)
    }
}
#endif
