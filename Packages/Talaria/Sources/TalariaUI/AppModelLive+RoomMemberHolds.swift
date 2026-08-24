import Foundation
import TalariaKit

@MainActor
private struct RoomMemberHoldInterruptResult: Sendable {
    var state: RoomMemberHoldInterruptState
    var connectionGeneration: UInt64?
}

private struct RoomMemberHoldPreparation: Sendable {
    var hold: RoomMemberHold
    var attempt: RoomAttempt?
    var created: Bool
}

enum RoomMemberHoldActionError: LocalizedError {
    case roomMissing
    case memberMissing
    case identityCollision

    var errorDescription: String? {
        switch self {
        case .roomMissing: "This room no longer exists."
        case .memberMissing: "That exact room member is no longer available."
        case .identityCollision: "The member identity changed. Nothing was resumed."
        }
    }
}

extension AppModel {
    /// Persist the sticky hold before attempting any remote interrupt. A
    /// definite or ambiguous stop failure therefore cannot accidentally
    /// resume this member or allow the room driver to schedule new work.
    @discardableResult
    func holdRoomMember(roomID: RoomID, member route: GatewayBotRoute,
                        reason: String = "Held by you") async throws -> RoomMemberHold {
        // Phase 1: publish scheduling authority durably, then release the gate.
        // Peers must remain free to advance while a source interrupt is slow.
        let preparation = try await RoomMutationGate.shared.withLock(roomID.description) {
            let runtime = RoomRuntime.shared
            guard let before = try await runtime.store.room(id: roomID) else {
                throw RoomMemberHoldActionError.roomMissing
            }
            guard before.members.contains(where: {
                $0.route == route && !$0.isFrozenProjection
            }) else { throw RoomMemberHoldActionError.memberMissing }
            if let existing = before.memberHolds.first(where: { $0.member == route }) {
                return RoomMemberHoldPreparation(
                    hold: existing, attempt: nil, created: false)
            }

            let candidates = before.attempts.filter {
                $0.member == route && $0.finishedAt == nil
                    && [.accepted, .uncertain, .working, .timedOut].contains($0.state)
            }
            // More than one unfinished submitted attempt is corrupt/ambiguous
            // authority. Hold the member, but do not choose a session to stop.
            let attempt = candidates.count == 1 ? candidates[0] : nil
            let hold = RoomMemberHold(
                member: route, driveEpoch: before.epoch,
                threadID: attempt?.threadID, attemptID: attempt?.id,
                storedSessionID: attempt?.storedSessionID,
                runtimeSessionID: attempt?.runtimeSessionID,
                interruptState: candidates.count > 1 ? .staleAuthority
                    : (attempt == nil ? .notNeeded : .pending),
                reason: reason)
            let persisted = try await runtime.store.mutate(roomID: roomID) { current in
                guard current.epoch == before.epoch,
                      current.members.contains(where: {
                          $0.route == route && !$0.isFrozenProjection
                      }), !current.memberHolds.contains(where: { $0.member == route })
                else { throw RoomMemberHoldActionError.identityCollision }
                current.memberHolds.append(hold)
                current.updatedAt = Date()
            }
            runtime.replace(persisted)
            return RoomMemberHoldPreparation(
                hold: hold, attempt: attempt, created: true)
        }
        let hold = preparation.hold
        guard preparation.created, hold.interruptState == .pending,
              let attempt = preparation.attempt else { return hold }

        // Phase 2: no RoomMutationGate is held across network or an injected
        // test operation. The durable hold is already visible to arbitration.
        let result: RoomMemberHoldInterruptResult
        if let operation = RoomRuntime.shared.memberHoldInterruptOperation {
            result = RoomMemberHoldInterruptResult(
                state: await operation(hold), connectionGeneration: nil)
        } else {
            result = await interruptHeldRoomMember(
                roomID: roomID, hold, attempt: attempt)
        }

        // Phase 3: settle only the exact hold and anchored attempt that phase
        // 1 published. Resume/removal/recreation wins by making this a no-op.
        let settlement = try? await RoomMutationGate.shared.withLock(roomID.description) {
            let runtime = RoomRuntime.shared
            guard let before = try await runtime.store.room(id: roomID),
                  before.members.contains(where: {
                    $0.route == route && !$0.isFrozenProjection
                  }), before.memberHolds.contains(where: {
                    $0.id == hold.id && $0.member == route
                  }), before.attempts.contains(where: {
                    $0.id == attempt.id && $0.member == route
                        && $0.threadID == hold.threadID
                        && $0.epoch == hold.driveEpoch
                        && $0.storedSessionID == hold.storedSessionID
                        && $0.runtimeSessionID == hold.runtimeSessionID
                        && $0.finishedAt == nil
                  }) else { throw CancellationError() }
            let settled = try await runtime.store.mutate(roomID: roomID, { current in
                guard let index = current.memberHolds.firstIndex(where: {
                    $0.id == hold.id && $0.member == route
                }), current.members.contains(where: {
                    $0.route == route && !$0.isFrozenProjection
                }), current.attempts.contains(where: {
                    $0.id == attempt.id && $0.member == route
                        && $0.threadID == hold.threadID
                        && $0.epoch == hold.driveEpoch
                        && $0.storedSessionID == hold.storedSessionID
                        && $0.runtimeSessionID == hold.runtimeSessionID
                        && $0.finishedAt == nil
                }) else { throw CancellationError() }
                current.memberHolds[index].interruptState = result.state
                current.memberHolds[index].connectionGeneration = result.connectionGeneration
                current.memberHolds[index].updatedAt = Date()
                if result.state == .confirmed, let attemptID = hold.attemptID,
                   let attemptIndex = current.attempts.firstIndex(where: {
                       $0.id == attemptID && $0.member == route
                           && $0.threadID == hold.threadID
                           && $0.storedSessionID == hold.storedSessionID
                           && $0.runtimeSessionID == hold.runtimeSessionID
                           && $0.finishedAt == nil
                   }) {
                    current.attempts[attemptIndex].state = .cancelled
                    current.attempts[attemptIndex].finishedAt = Date()
                    current.attempts[attemptIndex].outboundAttachments = []
                }
            })
            runtime.replace(settled)
            if result.state == .confirmed, let attemptID = hold.attemptID,
               let attempt = settled.attempts.first(where: { $0.id == attemptID }) {
                runtime.clearPendingPrompt(for: attempt, roomID: roomID)
            }
            return settled.memberHolds.first(where: { $0.id == hold.id })
        }
        return settlement ?? hold
    }

    /// Resume removes only the exact durable hold instance. A stale sheet or
    /// same-name recreation cannot release another member's hold.
    func resumeRoomMember(roomID: RoomID, holdID: UUID,
                          member route: GatewayBotRoute) async throws {
        try await RoomMutationGate.shared.withLock(roomID.description) {
            let runtime = RoomRuntime.shared
            guard let before = try await runtime.store.room(id: roomID) else {
                throw RoomMemberHoldActionError.roomMissing
            }
            guard before.memberHolds.contains(where: {
                $0.id == holdID && $0.member == route
            }), before.members.contains(where: {
                $0.route == route && !$0.isFrozenProjection
            }) else { throw RoomMemberHoldActionError.identityCollision }
            let updated = try await runtime.store.mutate(roomID: roomID) { current in
                guard current.memberHolds.contains(where: {
                    $0.id == holdID && $0.member == route
                }), current.members.contains(where: {
                    $0.route == route && !$0.isFrozenProjection
                }) else { throw RoomMemberHoldActionError.identityCollision }
                current.memberHolds.removeAll { $0.id == holdID && $0.member == route }
                current.updatedAt = Date()
            }
            runtime.replace(updated)
            scheduleRoomDrive(roomID: roomID)
        }
    }

    private func interruptHeldRoomMember(
        roomID: RoomID, _ hold: RoomMemberHold, attempt: RoomAttempt
    ) async -> RoomMemberHoldInterruptResult {
        guard let storedID = hold.storedSessionID,
              hold.runtimeSessionID != nil else {
            return .init(state: .notNeeded, connectionGeneration: nil)
        }
        let route = hold.member
        let routeGeneration = RoomRuntime.shared.profileRouteGeneration(route)
        guard RoomRuntime.shared.acceptsProfileRoute(
            route, generation: routeGeneration),
              profileLifecycleAllowsGatewayTraffic(route.gatewayID) else {
            return .init(state: .staleAuthority, connectionGeneration: nil)
        }
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == route.gatewayID }),
              let baseURL = gateway.baseURL,
              let credential = registry.credential(for: gateway) else {
            return .init(state: .failed, connectionGeneration: nil)
        }
        var requestStarted = false
        var capturedGeneration: UInt64?
        do {
            let snapshot = try await registry.clientPool.connectWithGeneration(
                gatewayID: route.gatewayID, baseURL: baseURL,
                credential: credential)
            capturedGeneration = snapshot.generation
            let state = try await registry.clientPool
                .withCommandConnectionAndTrafficLease(
                    snapshot, for: route.gatewayID
                ) { @MainActor in
                    guard RoomRuntime.shared.acceptsProfileRoute(
                        route, generation: routeGeneration),
                          profileLifecycleAllowsGatewayTraffic(route.gatewayID),
                          await registry.clientPool.isCurrent(
                            snapshot, for: route.gatewayID),
                          route.gatewayID != activeGatewayID
                            || client.map(ObjectIdentifier.init)
                                == ObjectIdentifier(snapshot.client) else {
                        throw CancellationError()
                    }
                    let live = try await snapshot.client.readRoomSession(
                        storedID: storedID, profile: route.profile)
                    guard live.storedID == storedID,
                          !live.runtimeID.isEmpty,
                          live.containsAttempt(attempt),
                          let current = try await RoomRuntime.shared.store.room(
                            id: roomID),
                          current.epoch == hold.driveEpoch,
                          current.memberHolds.contains(where: {
                            $0.id == hold.id && $0.member == route
                          }),
                          current.attempts.contains(where: {
                            $0.id == attempt.id && $0.member == route
                                && $0.threadID == hold.threadID
                                && $0.epoch == hold.driveEpoch
                                && $0.storedSessionID == storedID
                                && $0.finishedAt == nil
                          }) else {
                        return RoomMemberHoldInterruptState.staleAuthority
                    }
                    guard live.running || live.awaitingUser else {
                        return RoomMemberHoldInterruptState.alreadyIdle
                    }
                    guard RoomRuntime.shared.acceptsProfileRoute(
                        route, generation: routeGeneration),
                          await registry.clientPool.isCurrent(
                            snapshot, for: route.gatewayID) else {
                        throw CancellationError()
                    }
                    requestStarted = true
                    try await snapshot.client.interruptSession(live.runtimeID)
                    guard RoomRuntime.shared.acceptsProfileRoute(
                        route, generation: routeGeneration),
                          await registry.clientPool.isCurrent(
                            snapshot, for: route.gatewayID) else {
                        throw CancellationError()
                    }
                    return RoomMemberHoldInterruptState.confirmed
                }
            return .init(state: state ?? .staleAuthority,
                         connectionGeneration: snapshot.generation)
        } catch {
            return .init(
                state: requestStarted && PromptMutationFailure.isAmbiguous(error)
                    ? .ambiguous : (error is CancellationError ? .staleAuthority : .failed),
                connectionGeneration: capturedGeneration)
        }
    }
}
