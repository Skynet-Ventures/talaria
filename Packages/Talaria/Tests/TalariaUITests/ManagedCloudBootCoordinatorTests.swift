#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class ManagedCloudBootCoordinatorTests: XCTestCase {
    private let managed = URL(string: "https://ARES-1.agents.nousresearch.com/private?q=secret")!
    private let unmanaged = URL(string: "https://gateway.example.com")!

    @MainActor
    func testRepeatedServerDownMakesExactlySixCallsWithFullJitterThenPublishesSafeOutage()
        async {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        var randomCalls = 0
        runtime.randomUnit = {
            randomCalls += 1
            return 0.5
        }
        var delays: [TimeInterval] = []
        runtime.sleep = { delays.append($0) }
        var calls = 0
        let statuses = [502, 503, 504, 502, 503, 504]

        let error = await capturedError {
            try await AppModel().runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: "managed-source") {
                    let status = statuses[calls]
                    calls += 1
                    throw GatewayHTTPError(statusCode: status, detail: "unbounded raw detail")
                }
        }

        XCTAssertEqual((error as? GatewayHTTPError)?.statusCode, 504)
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(randomCalls, 5)
        XCTAssertEqual(delays, [1, 2, 4, 7.5, 7.5])
        XCTAssertEqual(AppModel().managedCloudBootOutage,
                       ManagedCloudBootOutage(
                           gatewayID: "managed-source",
                           sourceOrigin: "https://ares-1.agents.nousresearch.com",
                           host: "ares-1.agents.nousresearch.com",
                           statusCode: 504, attempts: 6, attemptsExhausted: true))
        XCTAssertFalse(String(describing: AppModel().managedCloudBootOutage)
            .contains("unbounded raw detail"))
    }

    @MainActor
    func testSafeSourceProjectionStripsCredentialsPathQueryAndFragmentButKeepsPort() {
        let source = URL(string:
            "https://user:secret@one.agents.nousresearch.com:8443/private?q=token#fragment")!
        XCTAssertEqual(AppModel.safeManagedCloudOrigin(source),
                       "https://one.agents.nousresearch.com:8443")
    }

    @MainActor
    func testNonmanagedAndNonServerDownStatusesFailImmediatelyWithoutSleepOrOutage() async {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        var sleeps = 0
        runtime.sleep = { _ in sleeps += 1 }

        for (url, status) in [(unmanaged, 503), (managed, 401), (managed, 500)] {
            var calls = 0
            let error = await capturedError {
                try await AppModel().runManagedCloudBootEpisode(
                    sourceURL: url, gatewayID: "exact-source") {
                        calls += 1
                        throw GatewayHTTPError(statusCode: status, detail: "failure")
                    }
            }
            XCTAssertEqual((error as? GatewayHTTPError)?.statusCode, status)
            XCTAssertEqual(calls, 1)
            XCTAssertNil(AppModel().managedCloudBootOutage)
        }
        XCTAssertEqual(sleeps, 0)
    }

    @MainActor
    func testStatusChangingOutsideServerDownSetStopsRetryImmediately() async {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        runtime.randomUnit = { 0 }
        var delays: [TimeInterval] = []
        runtime.sleep = { delays.append($0) }
        var statuses = [503, 500]

        let error = await capturedError {
            try await AppModel().runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: "source") {
                    throw GatewayHTTPError(statusCode: statuses.removeFirst(), detail: "failure")
                }
        }

        XCTAssertEqual((error as? GatewayHTTPError)?.statusCode, 500)
        XCTAssertEqual(delays, [0])
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertNil(AppModel().managedCloudBootOutage)
    }

    @MainActor
    func testSuccessAfterRetryAndNewSuccessClearOnlyCurrentEpisodeState() async throws {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        runtime.randomUnit = { 0 }
        runtime.sleep = { _ in }
        let model = AppModel()
        var calls = 0
        try await model.runManagedCloudBootEpisode(
            sourceURL: managed, gatewayID: "source") {
                calls += 1
                if calls < 3 {
                    throw GatewayHTTPError(statusCode: 502, detail: "booting")
                }
            }
        XCTAssertEqual(calls, 3)
        XCTAssertNil(model.managedCloudBootOutage)

        _ = await capturedError {
            try await model.runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: "old") {
                    throw GatewayHTTPError(statusCode: 503, detail: "down")
                }
        }
        XCTAssertNotNil(model.managedCloudBootOutage)
        try await model.runManagedCloudBootEpisode(
            sourceURL: managed, gatewayID: "new") {}
        XCTAssertNil(model.managedCloudBootOutage)
    }

    @MainActor
    func testSupersededConcurrentSourceCannotPublishStaleCompletionOrChooseGateway() async throws {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        let model = AppModel()
        var firstContinuation: CheckedContinuation<Void, Never>?
        var firstStarted = false

        let first = Task { @MainActor in
            try await model.runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: "first-gateway") {
                    firstStarted = true
                    await withCheckedContinuation { firstContinuation = $0 }
                }
        }
        await waitUntil { firstStarted && firstContinuation != nil }

        let secondURL = URL(string: "https://two.agents.nousresearch.com")!
        var secondCalls = 0
        try await model.runManagedCloudBootEpisode(
            sourceURL: secondURL, gatewayID: "second-gateway") {
                secondCalls += 1
            }
        firstContinuation?.resume()

        let firstError = await taskError(first)
        XCTAssertTrue(firstError is ManagedCloudBootSupersededError)
        XCTAssertEqual(secondCalls, 1)
        XCTAssertNil(model.managedCloudBootOutage)
        XCTAssertNil(runtime.active)
    }

    @MainActor
    func testExplicitInvalidationFencesSuspendedCompletion() async {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        let model = AppModel()
        var continuation: CheckedContinuation<Void, Never>?

        let task = Task { @MainActor in
            try await model.runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: "source") {
                    await withCheckedContinuation { continuation = $0 }
                }
        }
        await waitUntil { continuation != nil }
        model.invalidateManagedCloudBootEpisode()
        continuation?.resume()

        let error = await taskError(task)
        XCTAssertTrue(error is ManagedCloudBootSupersededError)
        XCTAssertNil(model.managedCloudBootOutage)
        XCTAssertNil(runtime.active)
    }

    @MainActor
    func testCallerCancellationDuringRetrySleepPublishesNoOutage() async {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        runtime.randomUnit = { 0.5 }
        runtime.sleep = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        let model = AppModel()
        var calls = 0

        let task = Task { @MainActor in
            try await model.runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: "source") {
                    calls += 1
                    throw GatewayHTTPError(statusCode: 503, detail: "down")
                }
        }
        await waitUntil { calls == 1 }
        task.cancel()

        let error = await taskError(task)
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(model.managedCloudBootOutage)
        XCTAssertNil(runtime.active)
    }

    @MainActor
    func testRemovingExactSourceDuringRetrySleepCancelsWithoutRecreation() async throws {
        let runtime = ManagedCloudBootRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        let registry = ConnectionRegistry.shared
        let gateway = try XCTUnwrap(registry.upsert(urlString: managed.absoluteString))
        defer {
            if registry.saved.contains(where: { $0.id == gateway.id }) {
                registry.remove(id: gateway.id)
            }
        }
        var sleepContinuation: CheckedContinuation<Void, Never>?
        runtime.randomUnit = { 0.5 }
        runtime.sleep = { _ in
            await withCheckedContinuation { sleepContinuation = $0 }
        }
        let model = AppModel()
        var calls = 0
        let task = Task { @MainActor in
            try await model.runManagedCloudBootEpisode(
                sourceURL: managed, gatewayID: gateway.id) {
                    calls += 1
                    throw GatewayHTTPError(statusCode: 503, detail: "booting")
                }
        }
        await waitUntil { calls == 1 && sleepContinuation != nil }

        await model.removeGateway(gateway)
        sleepContinuation?.resume()

        let error = await taskError(task)
        XCTAssertTrue(error is ManagedCloudBootSupersededError)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(registry.saved.contains(where: { $0.id == gateway.id }))
        XCTAssertNil(model.managedCloudBootOutage)
        XCTAssertNil(runtime.active)
    }

    @MainActor
    private func capturedError(_ operation: () async throws -> Void) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    @MainActor
    private func taskError(_ task: Task<Void, Error>) async -> Error? {
        do {
            try await task.value
            return nil
        } catch {
            return error
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate())
    }
}
#endif
