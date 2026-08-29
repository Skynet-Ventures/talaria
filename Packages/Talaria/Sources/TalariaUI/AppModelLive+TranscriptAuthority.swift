import Foundation
import TalariaKit

/// Exact source evidence carried across a transcript WS/REST suspension.
/// Primary publication retains the exact app client; secondary publication
/// additionally retains the pool slot and routed event-pump generation.
@MainActor
struct TranscriptHydrationSourceAuthority {
    let route: GatewayBotRoute
    let client: GatewayClient
    let liveGeneration: Int
    let wasPrimary: Bool
    let pooledSnapshot: GatewayClientPool.ConnectionSnapshot?
    let routedEventGeneration: UInt64?
    let pool: GatewayClientPool
}

extension AppModel {
    func captureTranscriptHydrationSourceAuthority(
        route: GatewayBotRoute, client: GatewayClient,
        expectedPooledSnapshot: GatewayClientPool.ConnectionSnapshot? = nil
    ) async -> TranscriptHydrationSourceAuthority? {
        let generation = LiveRuntime.shared.generation
        let wasPrimary = route.gatewayID == LiveRuntime.shared.gatewayID
        let pool = ConnectionRegistry.shared.clientPool
        guard mode == .live, profileLifecycleAllowsGatewayTraffic(route.gatewayID) else {
            return nil
        }
        if wasPrimary {
            guard self.client.map(ObjectIdentifier.init) == ObjectIdentifier(client) else {
                return nil
            }
            return TranscriptHydrationSourceAuthority(
                route: route, client: client, liveGeneration: generation,
                wasPrimary: true, pooledSnapshot: nil,
                routedEventGeneration: nil, pool: pool)
        }

        let snapshot: GatewayClientPool.ConnectionSnapshot
        if let expectedPooledSnapshot {
            guard ObjectIdentifier(expectedPooledSnapshot.client) == ObjectIdentifier(client),
                  await pool.isCurrent(expectedPooledSnapshot, for: route.gatewayID) else {
                return nil
            }
            snapshot = expectedPooledSnapshot
        } else {
            guard let retained = await pool.retainedConnectionSnapshots().first(where: {
                $0.gatewayID == route.gatewayID
                    && ObjectIdentifier($0.connection.client) == ObjectIdentifier(client)
            })?.connection else { return nil }
            snapshot = retained
        }
        guard LiveRuntime.shared.generation == generation,
              LiveRuntime.shared.gatewayID != route.gatewayID,
              let events = MultiGatewayRuntime.shared.routedEvents[route.gatewayID],
              ObjectIdentifier(events.client) == ObjectIdentifier(client),
              MultiGatewayRuntime.shared.routedEventGenerations[route.gatewayID]
                == events.generation else { return nil }
        return TranscriptHydrationSourceAuthority(
            route: route, client: client, liveGeneration: generation,
            wasPrimary: false, pooledSnapshot: snapshot,
            routedEventGeneration: events.generation, pool: pool)
    }

    func transcriptHydrationSourceIsCurrent(
        _ authority: TranscriptHydrationSourceAuthority
    ) async -> Bool {
        guard mode == .live,
              LiveRuntime.shared.generation == authority.liveGeneration,
              profileLifecycleAllowsGatewayTraffic(authority.route.gatewayID) else {
            return false
        }
        if authority.wasPrimary {
            return LiveRuntime.shared.gatewayID == authority.route.gatewayID
                && self.client.map(ObjectIdentifier.init)
                    == ObjectIdentifier(authority.client)
        }
        guard let snapshot = authority.pooledSnapshot,
              let eventGeneration = authority.routedEventGeneration,
              LiveRuntime.shared.gatewayID != authority.route.gatewayID,
              transcriptRoutedEventMatches(
                gatewayID: authority.route.gatewayID, client: authority.client,
                generation: eventGeneration),
              await authority.pool.isCurrent(snapshot, for: authority.route.gatewayID) else {
            return false
        }
        return mode == .live
            && LiveRuntime.shared.generation == authority.liveGeneration
            && profileLifecycleAllowsGatewayTraffic(authority.route.gatewayID)
            && transcriptRoutedEventMatches(
                gatewayID: authority.route.gatewayID, client: authority.client,
                generation: eventGeneration)
    }

    private func transcriptRoutedEventMatches(
        gatewayID: String, client: GatewayClient, generation: UInt64
    ) -> Bool {
        guard let events = MultiGatewayRuntime.shared.routedEvents[gatewayID] else {
            return false
        }
        return ObjectIdentifier(events.client) == ObjectIdentifier(client)
            && events.generation == generation
            && MultiGatewayRuntime.shared.routedEventGenerations[gatewayID] == generation
    }
}
