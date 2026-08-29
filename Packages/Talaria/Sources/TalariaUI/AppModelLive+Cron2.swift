import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

// Routine editing and run history — the administering half of cron.
//
// The socket can list, add, pause, resume and remove (cron.manage,
// tui_gateway/methods_tools.py:1676). Everything else a person needs to keep a
// schedule healthy — read the whole prompt, change it, see what actually ran,
// open the resulting session, and understand WHY a job stopped firing — is on
// the REST cron router. GatewayClient+Cron2.swift carries those calls; this
// file is the state and the verbs on top of them.
//
// The one non-obvious rule here is the FAIL-CLOSED one. An agent cron job that
// pins neither provider nor model follows the gateway's global config at fire
// time, and cron/jobs.py:1695 snapshots what that resolved to at creation. When
// the global config later moves, cron/scheduler.py:5318 SKIPS the job rather
// than silently billing the run to a different model — no inference call, no
// output, `last_error` stamped `[drift_skip]`, and (by the alert-once contract)
// exactly one notification ever. A phone that only renders `last_status` shows
// such a routine as "failed" forever with no reason and no way out. So the
// snapshot state is a first-class thing on this screen, with the server's own
// remediation — pin the axes — as a one-tap action.

// MARK: - Runtime (side table)

/// Per-job detail the routines list does not carry. Separate from
/// `FeedsRuntime` (another owner's file) and keyed by source-qualified routine
/// id so colliding raw job ids cannot share detail or history.
@MainActor
@Observable
public final class CronDetailRuntime {
    public static let shared = CronDetailRuntime()

    /// Source-qualified routine id → the raw stored record.
    public var detail: [String: CronJobDetail] = [:]
    /// Source-qualified routine id → its run sessions, newest first.
    public var runs: [String: [CronRun]] = [:]
    /// Gateway id → delivery routes that source can actually offer.
    public var deliveryTargets: [String: [CronDeliveryTarget]] = [:]

    /// Gateway id → whether its REST cron router exists. Missing means
    /// unknown; false hides only that source's REST-backed controls.
    public var restSupported: [String: Bool] = [:]
    /// Generation that produced each REST capability verdict. A replacement
    /// client must probe again even when it reuses the gateway id.
    @ObservationIgnored var restSupportGeneration: [String: CronSourceMutationFence] = [:]

    public var loadingDetail: Set<String> = []
    public var loadingRuns: Set<String> = []
    /// Source-qualified routine id → the last failure worth showing.
    public var detailError: [String: String] = [:]

    /// Bumped on every `cron.changed` broadcast. Open screens observe it and
    /// re-read; there is no per-job event, and the broadcast is already
    /// floor-limited to 1 s server-side (tui_gateway/server.py:3750).
    public var changeTick = 0

    /// The client this runtime's cron.changed handler is attached to. No
    /// handler id is kept: a handler's lifetime is its client's, and a new link
    /// means a new `GatewayClient` — the old handler is discarded with it.
    ///
    /// Held WEAKLY by identity, never as an `ObjectIdentifier`. An identifier is
    /// the object's address, and `connectGateway` allocates a fresh client over
    /// the released one — so a recycled address would read as "already routed"
    /// and leave `cron.changed` unsubscribed on the new link. A weak reference
    /// goes nil when the old client dies, which is exactly the answer wanted.
    @ObservationIgnored weak var routedClient: GatewayClient?
    @ObservationIgnored var deliveryLoaded: Set<String> = []
    /// Generation that produced each gateway's delivery-target cache. A pool
    /// replacement reuses the gateway id but not this authority.
    @ObservationIgnored var deliveryGeneration: [String: CronSourceMutationFence] = [:]
    /// Source authority for the per-routine caches. A stale task may finish
    /// after a replacement row reuses the same UI id; it must not clear or
    /// overwrite that newer row's detail/history.
    @ObservationIgnored var detailAuthority: [String: CronRoutineMutationFence] = [:]
    @ObservationIgnored var runsAuthority: [String: CronRoutineMutationFence] = [:]
    @ObservationIgnored var detailLoadingAuthority: [String: CronRoutineMutationFence] = [:]
    @ObservationIgnored var runsLoadingAuthority: [String: CronRoutineMutationFence] = [:]
    /// Full routine-fence identities already force-paused on this link, so the
    /// migration runs once per source/profile generation instead of on every
    /// list refresh. Raw job ids are deliberately not enough here.
    @ObservationIgnored var quarantined: Set<String> = []

    /// Everything derived from one gateway; dropped when the link changes.
    func reset() {
        detail.removeAll(); runs.removeAll(); deliveryTargets.removeAll()
        detailError.removeAll(); loadingDetail.removeAll(); loadingRuns.removeAll()
        deliveryLoaded.removeAll(); deliveryGeneration.removeAll()
        detailAuthority.removeAll(); runsAuthority.removeAll()
        detailLoadingAuthority.removeAll(); runsLoadingAuthority.removeAll()
        restSupported.removeAll(); restSupportGeneration.removeAll(); quarantined.removeAll()
    }
}

// MARK: - Mutation authority

/// Connection-role generation captured with a cron mutation. Gateway ids are
/// durable registry identities; generations prove that the client currently
/// occupying that identity is still the one the user acted on.
enum CronGatewayGeneration: Sendable, Equatable {
    case primary(Int)
    case retained(UInt64)

    var activityIdentity: String {
        switch self {
        case .primary(let generation): "primary-\(generation)"
        case .retained(let generation): "retained-\(generation)"
        }
    }
}

/// Existing-job operations use a distinct outcome from the accepted-add
/// partial result. A stale completion must never look like a successful write
/// or invite a retry against the replacement source.
enum CronMutationFenceError {
    /// GatewayTransport reserves -5 for an ordinary request timeout. A stale
    /// completion is a different state: the request may have landed on the
    /// old source, but its result is not authoritative for the current one.
    static let sourceChanged = -10
}

/// Common post-await decision for cron reads and writes. Keeping stale as an
/// explicit outcome makes it impossible for a caller to accidentally treat a
/// rejected fence as a successful no-op.
enum CronAsyncFencePolicy: Sendable, Equatable {
    case accepted
    case sourceChanged

    init(sourceAccepted: Bool) {
        self = sourceAccepted ? .accepted : .sourceChanged
    }

    var mayPublish: Bool { self == .accepted }
    var shouldRollbackOptimisticState: Bool { self == .sourceChanged }
}

enum CronQuarantinePolicy {
    /// A failed pause never owns a durable local dedupe marker. Keeping it
    /// would suppress the next safety sweep indefinitely.
    static let retainMarkerAfterPauseFailure = false

    /// Activity keys carry either the full routine-fence identity or a legacy
    /// raw id. Both forms belong to the removed routine; a sibling whose id
    /// merely shares the same prefix must survive.
    static func ownsActivityKey(_ key: String, routineID: String) -> Bool {
        let identity: String
        if key.hasPrefix("cron-quarantine:") {
            identity = String(key.dropFirst("cron-quarantine:".count))
        } else if key.hasPrefix("cron-run:") {
            identity = String(key.dropFirst("cron-run:".count))
        } else {
            return false
        }
        return identity == routineID
            || identity.hasPrefix("\(routineID)|")
            || identity.hasPrefix("\(routineID):")
    }
}

/// Exact source + profile store authority for one cron write.
struct CronSourceMutationFence: Sendable, Equatable {
    var gatewayID: String
    var profile: String?
    var generation: CronGatewayGeneration
    var profileGeneration: UInt64? = nil
    /// The profile store whose lifecycle owns an otherwise unscoped request.
    /// `profile == nil` is still meaningful for launch-store REST/WS calls, so
    /// keep its lifecycle route separate from the wire's optional profile.
    var lifecycleProfile: String? = nil

    static func accepts(_ fence: Self, primaryGatewayID: String?,
                        primaryGeneration: Int,
                        retainedGenerations: [String: UInt64]) -> Bool {
        switch fence.generation {
        case .primary(let generation):
            return fence.gatewayID == primaryGatewayID && generation == primaryGeneration
        case .retained(let generation):
            return fence.gatewayID != primaryGatewayID
                && retainedGenerations[fence.gatewayID] == generation
        }
    }
}

/// The socket create is the irreversible half of a new routine.  Once it has
/// returned a job id, the caller must distinguish an accepted add from the
/// optional REST completion instead of treating a lost source as permission to
/// retry or remove the job.
enum CronCreatePostAddDecision: Sendable, Equatable {
    /// The source changed while `cronAdd` was in flight.  No activity, cache
    /// publication, or REST patch may be attributed to the old source.
    case acceptedButStale
    /// The socket add is complete and there are no REST-only fields to apply.
    case accepted
    /// The captured source is still authoritative and the REST patch is safe.
    case readyForREST
    /// The add is complete, but requested REST-only fields could not be
    /// attempted from the captured authority.  The caller must surface the
    /// recoverable partial result.
    case acceptedWithoutREST

    var shouldIssueRESTPatch: Bool { self == .readyForREST }
    var preservesAcceptedAdd: Bool { true }
    var requiresRecoveryNotice: Bool {
        self == .acceptedButStale || self == .acceptedWithoutREST
    }
}

enum CronCreatePostAddPolicy {
    static func decision(
        sourceFence: CronSourceMutationFence,
        primaryGatewayID: String?,
        primaryGeneration: Int,
        retainedGenerations: [String: UInt64],
        hasRESTOnlyFields: Bool,
        hasJobID: Bool,
        hasRESTAuthority: Bool,
        restSupported: Bool
    ) -> CronCreatePostAddDecision {
        guard CronSourceMutationFence.accepts(
            sourceFence,
            primaryGatewayID: primaryGatewayID,
            primaryGeneration: primaryGeneration,
            retainedGenerations: retainedGenerations
        ) else {
            return .acceptedButStale
        }
        guard hasRESTOnlyFields else { return .accepted }
        guard hasJobID, hasRESTAuthority, restSupported else {
            return .acceptedWithoutREST
        }
        return .readyForREST
    }
}

/// `cron.manage add` is irreversible once the frame is sent. These are the
/// same transport outcomes the mutation surfaces treat as ambiguous-after-
/// send; a timeout or lost socket response must become a terminal partial
/// result rather than a retryable validation error. Tool/auth/route refusals
/// remain definite failures and are still thrown to the editor.
enum CronCreateAddFailurePolicy {
    static func isAmbiguousAfterSend(_ error: Error) -> Bool {
        if let gateway = error as? GatewayError {
            // GatewayTransport: timeout, cancellation-after-send, socket loss.
            return [-5, -6, -7].contains(gateway.code)
        }
        if let url = error as? URLError {
            return [.cancelled, .timedOut, .networkConnectionLost].contains(url.code)
        }
        // A response that reached the client but could not be decoded cannot
        // prove that the gateway rejected the irreversible add.
        return error is DecodingError
    }

    /// Only an ambiguous transport result can become a terminal partial. A
    /// definite refusal must remain a thrown, retryable error even when the
    /// source fence changed while the request was in flight.
    static func ambiguousPartialReason(
        for error: Error, sourceFenceStillCurrent: Bool
    ) -> CronAcceptedPartialReason? {
        guard isAmbiguousAfterSend(error) else { return nil }
        return sourceFenceStillCurrent ? .addOutcomeUnknown : .sourceChangedBeforeACK
    }

    static func unresolvedAddReason(sourceFenceStillCurrent: Bool)
        -> CronAcceptedPartialReason {
        sourceFenceStillCurrent ? .addOutcomeUnknown : .sourceChangedBeforeACK
    }

    static func unresolvedPartial(reason: CronAcceptedPartialReason)
        -> CronAcceptedPartialOutcome {
        CronAcceptedPartialOutcome(
            jobID: "", gatewayID: nil, profile: nil, reason: reason)
    }
}

/// A socket add is irreversible. If its REST completion is not authoritative,
/// callers must carry the accepted job forward as a typed partial result so a
/// UI cannot turn an ambiguous follow-up into a duplicate create retry.
public enum CronAcceptedPartialReason: Sendable, Equatable {
    /// The add returned no authoritative acknowledgement. The job may exist,
    /// but there is no id to claim or safely reconcile.
    case addOutcomeUnknown
    /// The source changed while the add was throwing, before an id was known.
    case sourceChangedBeforeACK
    /// A job id was known before a later source replacement.
    case sourceChanged
    case followUpUnavailable
    case followUpAmbiguous
}

public struct CronAcceptedPartialOutcome: Sendable, Equatable {
    public var jobID: String
    public var gatewayID: String?
    public var profile: String?
    public var reason: CronAcceptedPartialReason

    public init(jobID: String, gatewayID: String?, profile: String?,
                reason: CronAcceptedPartialReason) {
        self.jobID = jobID; self.gatewayID = gatewayID; self.profile = profile
        self.reason = reason
    }
}

public enum CronCreateOutcome: Sendable, Equatable {
    case completed
    case acceptedPartial(CronAcceptedPartialOutcome)

    public var acceptedPartial: CronAcceptedPartialOutcome? {
        guard case .acceptedPartial(let outcome) = self else { return nil }
        return outcome
    }

    /// Both a completed add and an accepted/ambiguous add must leave the
    /// create form. Keeping it open after an irreversible socket attempt
    /// would turn the primary button into a duplicate-create invitation.
    var shouldDismissCreateEditor: Bool { true }

    /// Partial outcomes are terminal warnings, not ordinary retryable errors.
    var needsWarningFeedback: Bool { acceptedPartial != nil }
}

/// The only REST cron acknowledgement accepted for publication. The job id is
/// not enough: an unscoped response can come from any profile store on the
/// gateway, so every response must echo a non-empty exact profile as well.
enum CronJobAcknowledgementPolicy {
    static func returnedProfile(_ detail: CronJobDetail, jobID: String,
                                expectedProfile: String) -> String? {
        guard !jobID.isEmpty, detail.id == jobID,
              let returned = detail.profile,
              !returned.isEmpty,
              returned == returned.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedProfile.isEmpty, expectedProfile == returned else { return nil }
        return returned
    }

    static func accepts(_ detail: CronJobDetail, jobID: String,
                        profile: String?) -> Bool {
        guard let profile else { return false }
        return returnedProfile(detail, jobID: jobID, expectedProfile: profile) != nil
    }
}

/// REST detail/history/update routes search by job id when no profile query is
/// supplied. That lookup is unsafe for colliding ids, so only a profile already
/// established by a scoped socket listing may authorize those calls.
enum CronDetailAuthorityPolicy {
    static func allowsProfileScopedREST(profile: String?) -> Bool {
        guard let profile else { return false }
        return !profile.isEmpty
    }
}

/// Kept as a source-compatible spelling for the original create tests. All
/// production call sites use `CronJobAcknowledgementPolicy` directly so
/// detail/save/pin/create share one identity check.
enum CronCreateAcknowledgementPolicy {
    static func accepts(_ detail: CronJobDetail, jobID: String,
                        profile: String?) -> Bool {
        guard let profile else { return false }
        return CronJobAcknowledgementPolicy.accepts(detail, jobID: jobID,
                                                    profile: profile)
    }
}

enum CronDeletePostRefreshPolicy {
    /// A successful remove may be followed by a refresh that installs a newer
    /// same-id row. Clearing is safe only when that id is now absent (the
    /// accepted delete is reflected) or still points at the exact captured
    /// target. A different target owns the caches and must be left alone.
    static func mayClear(capturedTarget: RoutineTarget,
                        currentTarget: RoutineTarget?) -> Bool {
        currentTarget == nil || currentTarget == capturedTarget
    }
}

/// Existing-job authority adds the UI row identity to the source fence. The
/// profile is part of `RoutineTarget`, so a refresh that moves the same raw job
/// id to another profile store invalidates this fence even if the source
/// connection did not change.
struct CronRoutineMutationFence: Sendable, Equatable {
    var routineID: String
    var target: RoutineTarget
    var source: CronSourceMutationFence
    var profileGeneration: UInt64? = nil

    static func accepts(_ fence: Self, currentTarget: RoutineTarget?,
                        primaryGatewayID: String?, primaryGeneration: Int,
                        retainedGenerations: [String: UInt64]) -> Bool {
        currentTarget == fence.target
            && sourceMatchesTarget(fence)
            && CronSourceMutationFence.accepts(
                fence.source, primaryGatewayID: primaryGatewayID,
                primaryGeneration: primaryGeneration,
                retainedGenerations: retainedGenerations)
    }

    private static func sourceMatchesTarget(_ fence: Self) -> Bool {
        fence.source.gatewayID == fence.target.route.gatewayID
            && fence.source.profile == fence.target.profile
    }

    /// Stable identity for optimistic cards and ledger rows. Include the
    /// generation so a replacement source cannot settle a new source's toast
    /// merely because a raw job id was reused.
    var activityIdentity: String {
        [routineID, target.route.gatewayID, target.route.jobID,
         target.profile ?? "", source.generation.activityIdentity,
         profileGeneration.map(String.init) ?? ""]
            .joined(separator: "|")
    }
}

enum CronReadCachePolicy {
    /// A current-source read may replace an older cache. A stale completion
    /// may clear only the cache it owned (or an unowned legacy cache), never a
    /// replacement source's authoritative row.
    static func shouldClearBeforeRead(sourceAccepted: Bool,
                                      cacheFence: CronRoutineMutationFence?,
                                      operationFence: CronRoutineMutationFence) -> Bool {
        sourceAccepted || cacheFence == nil || cacheFence == operationFence
    }
}

/// A secondary sweep is all-or-nothing for one gateway. A missing profile
/// token or a lifecycle change after any awaited RPC means the accumulated
/// dictionary is not a snapshot and must never prune the previous one.
enum CronProfileRefreshPolicy {
    static func mayPublishSnapshot(sourceAccepted: Bool,
                                   lifecycleAuthorityAccepted: Bool) -> Bool {
        sourceAccepted && lifecycleAuthorityAccepted
    }

    /// A profile list is a set of expected stores. Capture one lifecycle token
    /// for every expected name before the first cron read; a token missing from
    /// the map makes the whole snapshot incomplete rather than authorizing a
    /// partial prune.
    static func hasAllExpectedProfileTokens(
        expectedProfiles: [String],
        tokens: [String: ProfileLifecycleGenerationToken]
    ) -> Bool {
        guard Set(expectedProfiles).count == expectedProfiles.count,
              tokens.count == expectedProfiles.count else { return false }
        return expectedProfiles.allSatisfy { profile in
            tokens[profile]?.route.profile == profile
        }
    }

    /// Re-check every captured token, not just the profile whose RPC just
    /// completed. This closes the A-changes-during-B-read race.
    static func capturedProfilesRemainCurrent(
        expectedProfiles: [String],
        tokens: [String: ProfileLifecycleGenerationToken],
        isCurrent: (ProfileLifecycleGenerationToken) -> Bool
    ) -> Bool {
        hasAllExpectedProfileTokens(expectedProfiles: expectedProfiles, tokens: tokens)
            && expectedProfiles.allSatisfy { profile in
                guard let token = tokens[profile] else { return false }
                return isCurrent(token)
            }
    }
}

/// Only the request's explicit profile plus Hermes' exact `scoped` echo can
/// identify a profile store. Per-row `profile` fields and an unscoped listing's
/// top-level profile are merely payload data and cannot retarget a row.
enum CronListingScopePolicy {
    static let incompleteScopeMessage =
        "Profile-scoped routine response did not echo its requested profile."

    static func scope(for listing: CronListing, requestedProfile: String?) -> String? {
        guard let requestedProfile, !requestedProfile.isEmpty,
              listing.scopedProfile == requestedProfile else { return nil }
        return requestedProfile
    }

    static func acceptsExactScopeEcho(_ listing: CronListing,
                                      requestedProfile: String?) -> Bool {
        scope(for: listing, requestedProfile: requestedProfile) != nil
    }
}

/// Display attribution is deliberately separate from store authority. The
/// parser validates the namespaced `[bot:…]` shape; the result may identify the
/// row's UI bot and socket-management destination, but it never becomes a
/// `RoutineTarget.profile` or a REST profile argument.
enum CronListingAttributionPolicy {
    static func displayBotID(for job: CronJobRecord, scopedProfile: String? = nil) -> String {
        job.taggedBotID ?? scopedProfile ?? ""
    }
}

/// The old flat refresh has no source-qualified target fold and is therefore
/// safe only for the canned demo world. Every live caller uses
/// `refreshRoutinesLive`, which updates rows and targets under one fence.
enum CronRoutineRefreshAuthorityPolicy {
    static func allowsLegacyRefresh(mode: AppMode) -> Bool {
        mode == .demo
    }
}

/// Create's socket step is authoritative but unscoped. Until Hermes exposes
/// the process launch profile, no REST-only field may be serialized or shown as
/// available; otherwise the follow-up would be an ambiguous cross-store write.
enum CronCreateRESTPolicy {
    static func allowsExtras(launchProfile: String?) -> Bool {
        guard let launchProfile else { return false }
        return !launchProfile.isEmpty
    }

    static func extras(launchProfile: String?, deliver: [String], model: String?,
                       provider: String?, reasoningEffort: String?) -> [String: JSONValue] {
        guard allowsExtras(launchProfile: launchProfile) else { return [:] }
        var values: [String: JSONValue] = [:]
        if !deliver.isEmpty { values["deliver"] = .string(deliver.joined(separator: ",")) }
        if let model, !model.isEmpty { values["model"] = .string(model) }
        if let provider, !provider.isEmpty { values["provider"] = .string(provider) }
        if let reasoningEffort { values["reasoning_effort"] = .string(reasoningEffort) }
        return values
    }
}

extension AppModel {
    func cronSourceMutationFence(gatewayID: String,
                                 profile: String?,
                                 lifecycleProfile: String? = nil) -> CronSourceMutationFence? {
        let authorityProfile = lifecycleProfile ?? profile
        let profileGeneration: UInt64?
        if let authorityProfile, !authorityProfile.isEmpty {
            let rosterID = gatewayID == LiveRuntime.shared.gatewayID
                ? authorityProfile
                : GatewayBotRoute(gatewayID: gatewayID, profile: authorityProfile).qualifiedID
            guard let token = profileLifecycleGenerationToken(for: rosterID) else { return nil }
            profileGeneration = token.generation
        } else {
            profileGeneration = nil
        }
        if gatewayID == LiveRuntime.shared.gatewayID {
            return CronSourceMutationFence(
                gatewayID: gatewayID, profile: profile,
                generation: .primary(LiveRuntime.shared.generation),
                profileGeneration: profileGeneration,
                lifecycleProfile: authorityProfile)
        }
        let routed = MultiGatewayRuntime.shared
        guard routed.routedEvents[gatewayID] != nil,
              let generation = routed.routedEventGenerations[gatewayID] else { return nil }
        return CronSourceMutationFence(
            gatewayID: gatewayID, profile: profile,
            generation: .retained(generation), profileGeneration: profileGeneration,
            lifecycleProfile: authorityProfile)
    }

    func cronRoutineMutationFence(_ routineID: String) -> CronRoutineMutationFence? {
        guard let target = routineTarget(routineID),
              let source = cronSourceMutationFence(
                gatewayID: target.route.gatewayID, profile: target.profile) else { return nil }
        // An unscoped cron row belongs to the process launch store, whose
        // profile name is intentionally unknown here. Never turn a roster
        // default or a display bot into profile authority; only an exact
        // profile echoed by Hermes may carry lifecycle generation.
        let profileGeneration: UInt64?
        if let profile = target.profile, !profile.isEmpty {
            let profileID = target.route.gatewayID == LiveRuntime.shared.gatewayID
                ? profile
                : GatewayBotRoute(gatewayID: target.route.gatewayID,
                                  profile: profile).qualifiedID
            guard let profileToken = profileLifecycleGenerationToken(for: profileID) else {
                return nil
            }
            profileGeneration = profileToken.generation
        } else {
            profileGeneration = nil
        }
        return CronRoutineMutationFence(routineID: routineID, target: target, source: source,
                                        profileGeneration: profileGeneration)
    }

    /// Return the exact client currently occupying a source slot. A generation
    /// normally implies this identity, but keeping the identity check explicit
    /// closes the small handoff window where a pool swaps clients before its
    /// routed-event generation is published.
    func cronSourceClient(gatewayID: String) -> GatewayClient? {
        if gatewayID == LiveRuntime.shared.gatewayID {
            return client
        }
        return MultiGatewayRuntime.shared.routedEvents[gatewayID]?.client
    }

    func cronMutationFenceAccepts(_ fence: CronSourceMutationFence,
                                  expectedClient: GatewayClient? = nil) -> Bool {
        if let expectedClient {
            guard let currentClient = cronSourceClient(gatewayID: fence.gatewayID),
                  currentClient === expectedClient else { return false }
        }
        return profileLifecycleAllowsGatewayTraffic(fence.gatewayID)
            && cronSourceProfileLifecycleAccepts(fence)
            && CronSourceMutationFence.accepts(
                fence, primaryGatewayID: LiveRuntime.shared.gatewayID,
                primaryGeneration: LiveRuntime.shared.generation,
                retainedGenerations: MultiGatewayRuntime.shared.routedEventGenerations)
    }

    func cronMutationFenceAccepts(_ fence: CronRoutineMutationFence,
                                  expectedClient: GatewayClient? = nil) -> Bool {
        if let expectedClient {
            guard let currentClient = cronSourceClient(gatewayID: fence.source.gatewayID),
                  currentClient === expectedClient else { return false }
        }
        return profileLifecycleAllowsGatewayTraffic(fence.source.gatewayID)
            && cronSourceProfileLifecycleAccepts(fence.source)
            && cronRoutineProfileLifecycleAccepts(fence)
            && CronRoutineMutationFence.accepts(
                fence, currentTarget: routineTarget(fence.routineID),
                primaryGatewayID: LiveRuntime.shared.gatewayID,
                primaryGeneration: LiveRuntime.shared.generation,
                retainedGenerations: MultiGatewayRuntime.shared.routedEventGenerations)
    }

    /// Detail screens use this before enabling edits or retrying a write. It
    /// intentionally requires the same live client that produced the fence;
    /// a matching row/generation alone is not authority during client handoff.
    func cronRoutineAuthorityIsCurrent(_ fence: CronRoutineMutationFence) -> Bool {
        guard let sourceClient = cronSourceClient(gatewayID: fence.source.gatewayID) else {
            return false
        }
        return cronMutationFenceAccepts(fence, expectedClient: sourceClient)
    }

    /// A gateway/pool generation is not enough when the same connection keeps
    /// serving a profile that is being retired, renamed, or recreated. Reads
    /// and writes that carry a profile capture its lifecycle generation too.
    private func cronSourceProfileLifecycleAccepts(_ fence: CronSourceMutationFence) -> Bool {
        guard let profile = fence.lifecycleProfile ?? fence.profile, !profile.isEmpty else {
            return true
        }
        return cronProfileLifecycleAccepts(gatewayID: fence.gatewayID, profile: profile,
                                           generation: fence.profileGeneration)
    }

    private func cronRoutineProfileLifecycleAccepts(_ fence: CronRoutineMutationFence) -> Bool {
        guard let profile = fence.target.profile, !profile.isEmpty else {
            return fence.profileGeneration == nil
        }
        return cronProfileLifecycleAccepts(gatewayID: fence.source.gatewayID, profile: profile,
                                           generation: fence.profileGeneration)
    }

    private func cronProfileLifecycleAccepts(gatewayID: String, profile: String,
                                             generation: UInt64? = nil) -> Bool {
        guard !profile.isEmpty else { return false }
        let rosterID = gatewayID == LiveRuntime.shared.gatewayID
            ? profile : GatewayBotRoute(gatewayID: gatewayID, profile: profile).qualifiedID
        guard let token = profileLifecycleGenerationToken(for: rosterID),
              token.route == GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        else { return false }
        return profileLifecycleAccepts(token)
            && (generation == nil || token.generation == generation)
    }

    func cronSourceChangedError() -> GatewayError {
        GatewayError(code: CronMutationFenceError.sourceChanged,
                     message: theme.copy.routineSourceChanged(theme.themeID))
    }

    /// A negative REST probe is source authority, not a gateway-id property.
    /// The nil fallback keeps hand-seeded test/runtime state readable until the
    /// first probe records its generation; all production writes use the
    /// generation-aware setter below.
    func cronRESTSupported(gatewayID: String,
                           sourceFence: CronSourceMutationFence) -> Bool? {
        guard let knownFence = CronDetailRuntime.shared.restSupportGeneration[gatewayID]
        else { return CronDetailRuntime.shared.restSupported[gatewayID] }
        // REST capability is gateway-wide, while a routine fence may carry a
        // profile store. Compare the exact gateway generation (the client
        // identity is checked by each caller), not that unrelated profile
        // qualifier.
        guard knownFence.gatewayID == sourceFence.gatewayID,
              knownFence.generation == sourceFence.generation else { return nil }
        return CronDetailRuntime.shared.restSupported[gatewayID]
    }

    func setCronRESTSupported(_ supported: Bool,
                              gatewayID: String,
                              sourceFence: CronSourceMutationFence) {
        CronDetailRuntime.shared.restSupported[gatewayID] = supported
        CronDetailRuntime.shared.restSupportGeneration[gatewayID] =
            cronSourceMutationFence(gatewayID: gatewayID, profile: nil) ?? sourceFence
    }

}

// MARK: - Legacy delegation quarantine

public extension AppModel {

    /// Desktop's `SAFE_ROUTINE_MARKER` (plugin.js:5973). A delegating routine
    /// written before it interpolated unescaped values into a shell command.
    static let safeRoutineMarker = "[bot-mode:routine:v2] "
    static let legacyRoutinePrefix = "You are running the scheduled routine \""

    /// True for a delegated routine written before the v2 escaping fix —
    /// tagged `[bot:…]`, prompt starts with the delegation preamble, and the
    /// safety marker is absent (plugin.js:5984 `isLegacyDelegatedRoutine`).
    /// Desktop pauses every one of these on load; so does Talaria, because the
    /// prompt these run is a shell command built from unescaped text.
    static func isLegacyDelegated(_ job: CronJobRecord) -> Bool {
        guard job.taggedBotID != nil else { return false }
        let prompt = job.promptPreview
        return !prompt.hasPrefix(safeRoutineMarker) && prompt.hasPrefix(legacyRoutinePrefix)
    }

    static func isLegacyDelegated(_ job: CronJobDetail) -> Bool {
        guard job.name.hasPrefix("[bot:") else { return false }
        return !job.prompt.hasPrefix(safeRoutineMarker) && job.prompt.hasPrefix(legacyRoutinePrefix)
    }

    /// True when the routine behind this row is quarantined and must not be
    /// re-enabled from the phone.
    func routineIsQuarantined(_ routine: Routine) -> Bool {
        guard let job = FeedsRuntime.shared.cronJobs[routine.id] else { return false }
        return Self.isLegacyDelegated(job)
    }

    /// Pause every legacy delegated routine that is still armed.
    ///
    /// Each pause swallows its own failure. Desktop learned this the hard way
    /// (plugin.js:6000): letting a failing pause fail the LIST reports "could
    /// not load cronjobs" over data that loaded fine, and then retries the
    /// failing pause inside a failing query forever.
    func quarantineLegacyRoutines() async {
        guard mode == .live else { return }
        let runtime = CronDetailRuntime.shared
        let feeds = FeedsRuntime.shared
        let victims = feeds.cronJobs.filter { id, job in
            guard let fence = cronRoutineMutationFence(id) else { return false }
            return Self.isLegacyDelegated(job) && job.isActive
                && !runtime.quarantined.contains(fence.activityIdentity)
        }
        guard !victims.isEmpty else { return }
        var paused = false
        for (id, job) in victims {
            guard let fence = cronRoutineMutationFence(id),
                  let target = feeds.routineTargets[id], target == fence.target,
                  let client = try? await routedClient(gatewayID: target.route.gatewayID)
            else { continue }
            guard cronMutationFenceAccepts(fence, expectedClient: client) else { continue }
            let quarantineKey = fence.activityIdentity
            runtime.quarantined.insert(quarantineKey)
            do {
                try await client.cronSetPaused(jobID: target.route.jobID, paused: true,
                                               profile: target.profile)
                guard cronMutationFenceAccepts(fence, expectedClient: client) else {
                    runtime.quarantined.remove(quarantineKey)
                    continue
                }
                paused = true
                let botID = target.route.gatewayID == LiveRuntime.shared.gatewayID
                    ? target.bot.profile : target.bot.qualifiedID
                recordActivity(kind: .routine, botID: botID,
                               text: theme.copy.routineQuarantined(theme.themeID) + " — " + job.displayTitle,
                               subtext: theme.copy.routineQuarantineWhy(theme.themeID),
                               key: "cron-quarantine:\(fence.activityIdentity)")
            } catch {
                // Retried on the next list; never surfaced as a list failure.
                // The marker is only a same-source dedupe lease. If the pause
                // failed or the source was replaced while it was in flight,
                // retaining it would permanently hide the victim from the
                // next quarantine sweep and could leave an unsafe job armed.
                if !CronQuarantinePolicy.retainMarkerAfterPauseFailure {
                    runtime.quarantined.remove(quarantineKey)
                }
            }
        }
        if paused { await refreshRoutinesLive(force: true) }
    }
}

// MARK: - cron.changed router

public extension AppModel {

    /// Subscribe the detail surfaces to `cron.changed`. The list already has
    /// its own debounced handler in the feeds runtime; this one only ticks a
    /// counter, so an open routine screen can re-read its own job and runs
    /// without the two refreshes racing each other.
    func attachCronDetailRouter() {
        guard mode == .live, let client else { return }
        let runtime = CronDetailRuntime.shared
        guard runtime.routedClient !== client else { return }
        // A new client means a new socket; the old handler died with it, and
        // every cached record belongs to the gateway we just left.
        runtime.reset()
        runtime.routedClient = client
        Task { @MainActor in
            _ = await client.addEpochEventHandler { event, transportEpoch in
                Task { @MainActor in
                    guard CronDetailRuntime.shared.routedClient === client,
                          await client.isCurrentReadyTransport(
                            epoch: transportEpoch) else { return }
                    guard case .changed(let what) = TypedGatewayEvent(event),
                          what == "cron.changed" else { return }
                    CronDetailRuntime.shared.changeTick &+= 1
                }
            }
        }
    }

    /// Tear the cron detail state down with the link. A job id, a run history
    /// and the "this gateway has no cron REST router" verdict all describe the
    /// gateway that just left; the last of those decides whether the editing
    /// and history surfaces exist at all, so carrying it to the next gateway
    /// would hide working controls (or offer missing ones).
    func detachCronDetailRouter() {
        let runtime = CronDetailRuntime.shared
        runtime.routedClient = nil
        runtime.reset()
        runtime.changeTick = 0
    }
}

// MARK: - Reads

public extension AppModel {

    /// The profile scope a job's calls must carry (nil = the launch store).
    func cronScope(_ routineID: String) -> String? {
        FeedsRuntime.shared.routineTargets[routineID]?.profile
            ?? FeedsRuntime.shared.cronScope[routineID] ?? nil
    }

    internal func routineTarget(_ routineID: String) -> RoutineTarget? {
        FeedsRuntime.shared.routineTargets[routineID]
    }

    func routineGatewayID(routineID: String? = nil, botID: String? = nil) -> String? {
        if let routineID, let target = routineTarget(routineID) {
            return target.route.gatewayID
        }
        if let botID, let route = GatewayBotRoute(qualifiedID: botID) {
            return route.gatewayID
        }
        return LiveRuntime.shared.gatewayID
    }

    /// True when the cron REST router is reachable — a live link, an HTTP
    /// credential, and no gateway that has already answered "no such route".
    /// Everything past list/toggle/delete depends on it, so the surfaces that
    /// need it check this before rendering rather than after failing.
    func cronRESTReady(routineID: String? = nil, botID: String? = nil) -> Bool {
        // Create has no authoritative process-launch profile. Do not expose
        // gateway-wide REST capability as if it authorized a future
        // unscoped add/follow-up; the create form must stay socket-only.
        guard mode == .live, let routineID,
              let gatewayID = routineGatewayID(routineID: routineID, botID: botID)
        else { return false }
        guard let fence = cronRoutineMutationFence(routineID),
              CronDetailAuthorityPolicy.allowsProfileScopedREST(profile: fence.target.profile),
              cronRoutineAuthorityIsCurrent(fence) else { return false }
        let sourceFence = fence.source
        return cronRESTSupported(gatewayID: gatewayID, sourceFence: sourceFence) != false
            && gatewayRESTContext(gatewayID: gatewayID) != nil
    }

    func cronDeliveryTargets(routineID: String? = nil, botID: String? = nil)
        -> [CronDeliveryTarget] {
        guard let (gatewayID, sourceFence) = cronDeliverySourceFence(
            routineID: routineID, botID: botID),
              let sourceClient = cronSourceClient(gatewayID: gatewayID),
              cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient),
              CronDetailRuntime.shared.deliveryGeneration[gatewayID] == sourceFence else { return [] }
        return CronDetailRuntime.shared.deliveryTargets[gatewayID] ?? []
    }

    internal func cronDeliverySourceFence(routineID: String? = nil, botID: String? = nil)
        -> (gatewayID: String, fence: CronSourceMutationFence)? {
        let selectedTarget = routineID.flatMap(routineTarget)
        let selectedBotRoute = botID.flatMap(GatewayBotRoute.init(qualifiedID:))
        guard routineID == nil || selectedTarget != nil else { return nil }
        // A routine target with nil profile is the process launch store. Keep
        // that identity unscoped; never fall back to the editor's selected bot
        // route for an existing row, because that display identity is not
        // launch-store authority. The selected bot is only meaningful for the
        // create-editor path, where there is no routine target yet.
        let selectedProfile = selectedTarget != nil
            ? selectedTarget?.profile
            : selectedBotRoute?.profile
        guard let gatewayID = selectedTarget?.route.gatewayID ?? selectedBotRoute?.gatewayID
                ?? routineGatewayID(routineID: routineID, botID: botID),
              let sourceFence = cronSourceMutationFence(
                gatewayID: gatewayID, profile: selectedProfile) else { return nil }
        return (gatewayID, sourceFence)
    }

    /// Load the raw job record. Returns nil when the gateway has no cron REST
    /// surface, which is a hide-the-section signal, not an error.
    @discardableResult
    func loadRoutineDetail(_ routineID: String) async -> CronJobDetail? {
        let runtime = CronDetailRuntime.shared
        guard mode == .live, let fence = cronRoutineMutationFence(routineID),
              let target = routineTarget(routineID), target == fence.target,
              // Hermes' unscoped REST lookup searches every profile store.
              // Keep launch-store rows read-only until a scoped socket list
              // establishes the exact profile; never retarget from a REST
              // response that may belong to a colliding row.
              CronDetailAuthorityPolicy.allowsProfileScopedREST(profile: target.profile),
              cronRESTSupported(gatewayID: target.route.gatewayID,
                                sourceFence: fence.source) != false,
              let sourceClient = cronSourceClient(gatewayID: target.route.gatewayID),
              let (base, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID),
              !target.route.jobID.isEmpty
        else {
            // A missing client/REST authority is not permission to keep an
            // old raw record looking current. The socket listing remains the
            // read-only fallback, while this cache must await a fresh detail.
            clearCronRoutineCaches(routineID)
            return nil
        }
        if runtime.loadingDetail.contains(routineID) {
            if runtime.detailLoadingAuthority[routineID] != fence {
                runtime.loadingDetail.remove(routineID)
                runtime.detailLoadingAuthority.removeValue(forKey: routineID)
            } else {
                return nil
            }
        }
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            if CronReadCachePolicy.shouldClearBeforeRead(
                sourceAccepted: false, cacheFence: runtime.detailAuthority[routineID],
                operationFence: fence) {
                runtime.detail.removeValue(forKey: routineID)
                runtime.detailAuthority.removeValue(forKey: routineID)
                runtime.detailError.removeValue(forKey: routineID)
            }
            return nil
        }
        // The old record is a display snapshot at best. It is not authority
        // while this exact source is being read again, so the editor must lock
        // until a fresh response arrives.
        if CronReadCachePolicy.shouldClearBeforeRead(
            sourceAccepted: true, cacheFence: runtime.detailAuthority[routineID],
            operationFence: fence) {
            runtime.detail.removeValue(forKey: routineID)
            runtime.detailError.removeValue(forKey: routineID)
            runtime.detailAuthority.removeValue(forKey: routineID)
        }
        runtime.loadingDetail.insert(routineID)
        runtime.detailLoadingAuthority[routineID] = fence
        defer {
            if runtime.detailLoadingAuthority[routineID] == fence {
                runtime.loadingDetail.remove(routineID)
                runtime.detailLoadingAuthority.removeValue(forKey: routineID)
            }
        }
        do {
            let job = try await GatewayREST.cronJob(baseURL: base, credential: credential,
                                                    jobID: target.route.jobID,
                                                    profile: target.profile)
            guard CronJobAcknowledgementPolicy.accepts(
                job, jobID: target.route.jobID, profile: target.profile) else {
                throw AckValidationError(
                    operation: "Load routine detail",
                    detail: "Hermes did not echo the exact cron job id and profile.")
            }
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return nil }
            setCronRESTSupported(true, gatewayID: target.route.gatewayID,
                                 sourceFence: fence.source)
            runtime.detail[routineID] = job
            runtime.detailAuthority[routineID] = fence
            runtime.detailError[routineID] = nil
            return job
        } catch let error as GatewayError where error.code == GatewayREST.cronRESTUnavailable {
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return nil }
            setCronRESTSupported(false, gatewayID: target.route.gatewayID,
                                 sourceFence: fence.source)
            if runtime.detailAuthority[routineID].map({ $0 == fence }) ?? true {
                runtime.detail.removeValue(forKey: routineID)
                runtime.detailAuthority.removeValue(forKey: routineID)
                runtime.detailError.removeValue(forKey: routineID)
            }
            return nil
        } catch let error as GatewayError where error.code == 404 {
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return nil }
            // The job is gone (a finite one-shot deletes itself after its last
            // run). Drop the stale cache rather than reporting a failure.
            if runtime.detailAuthority[routineID].map({ $0 == fence }) ?? true {
                runtime.detail.removeValue(forKey: routineID)
                runtime.detailAuthority.removeValue(forKey: routineID)
                runtime.detailError[routineID] = nil
            }
            return nil
        } catch {
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return nil }
            if runtime.detailAuthority[routineID].map({ $0 == fence }) ?? true {
                runtime.detail.removeValue(forKey: routineID)
                runtime.detailAuthority.removeValue(forKey: routineID)
                runtime.detailError[routineID] = Self.reason(error)
            }
            return nil
        }
    }

    /// Load this job's run sessions, newest first.
    func loadRoutineRuns(_ routineID: String, limit: Int = 20) async {
        let runtime = CronDetailRuntime.shared
        guard mode == .live, let fence = cronRoutineMutationFence(routineID),
              let target = routineTarget(routineID), target == fence.target,
              CronDetailAuthorityPolicy.allowsProfileScopedREST(profile: target.profile),
              cronRESTSupported(gatewayID: target.route.gatewayID,
                                sourceFence: fence.source) != false,
              let sourceClient = cronSourceClient(gatewayID: target.route.gatewayID),
              let (base, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID),
              !target.route.jobID.isEmpty
        else {
            if routineTarget(routineID) == nil {
                clearCronRoutineCaches(routineID)
            } else {
                runtime.runs.removeValue(forKey: routineID)
                runtime.runsAuthority.removeValue(forKey: routineID)
                runtime.runsLoadingAuthority.removeValue(forKey: routineID)
                runtime.loadingRuns.remove(routineID)
            }
            return
        }
        if runtime.loadingRuns.contains(routineID) {
            if runtime.runsLoadingAuthority[routineID] != fence {
                runtime.loadingRuns.remove(routineID)
                runtime.runsLoadingAuthority.removeValue(forKey: routineID)
            } else {
                return
            }
        }
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            if CronReadCachePolicy.shouldClearBeforeRead(
                sourceAccepted: false, cacheFence: runtime.runsAuthority[routineID],
                operationFence: fence) {
                runtime.runs.removeValue(forKey: routineID)
                runtime.runsAuthority.removeValue(forKey: routineID)
            }
            return
        }
        if CronReadCachePolicy.shouldClearBeforeRead(
            sourceAccepted: true, cacheFence: runtime.runsAuthority[routineID],
            operationFence: fence) {
            runtime.runs.removeValue(forKey: routineID)
            runtime.runsAuthority.removeValue(forKey: routineID)
        }
        runtime.loadingRuns.insert(routineID)
        runtime.runsLoadingAuthority[routineID] = fence
        defer {
            if runtime.runsLoadingAuthority[routineID] == fence {
                runtime.loadingRuns.remove(routineID)
                runtime.runsLoadingAuthority.removeValue(forKey: routineID)
            }
        }
        do {
            let rows = try await GatewayREST.cronJobRuns(baseURL: base, credential: credential,
                                                         jobID: target.route.jobID,
                                                         profile: target.profile,
                                                         limit: limit)
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return }
            setCronRESTSupported(true, gatewayID: target.route.gatewayID,
                                 sourceFence: fence.source)
            runtime.runs[routineID] = rows
            runtime.runsAuthority[routineID] = fence
        } catch let error as GatewayError where error.code == GatewayREST.cronRESTUnavailable {
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return }
            setCronRESTSupported(false, gatewayID: target.route.gatewayID,
                                 sourceFence: fence.source)
            if runtime.runsAuthority[routineID].map({ $0 == fence }) ?? true {
                runtime.runs.removeValue(forKey: routineID)
                runtime.runsAuthority.removeValue(forKey: routineID)
            }
        } catch {
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else { return }
            // A failed read cannot make an old history authoritative. Clear it
            // so the screen remains in its honest loading/unknown state.
            if runtime.runsAuthority[routineID].map({ $0 == fence }) ?? true {
                runtime.runs.removeValue(forKey: routineID)
                runtime.runsAuthority.removeValue(forKey: routineID)
            }
        }
    }

    /// Delivery routes this gateway offers. Loaded once per link — the list is
    /// derived from configured platforms, which do not change mid-session.
    func loadCronDeliveryTargets(routineID: String? = nil, botID: String? = nil) async {
        let runtime = CronDetailRuntime.shared
        guard let (gatewayID, sourceFence) = cronDeliverySourceFence(
            routineID: routineID, botID: botID) else { return }
        if let loadedFence = runtime.deliveryGeneration[gatewayID],
           loadedFence != sourceFence {
            runtime.deliveryTargets.removeValue(forKey: gatewayID)
            runtime.deliveryLoaded.remove(gatewayID)
        }
        guard mode == .live,
              cronRESTSupported(gatewayID: gatewayID, sourceFence: sourceFence) != false,
              let sourceClient = cronSourceClient(gatewayID: gatewayID),
              let (base, credential) = gatewayRESTContext(gatewayID: gatewayID) else { return }
        guard !runtime.deliveryLoaded.contains(gatewayID) else { return }
        guard cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else {
            runtime.deliveryTargets.removeValue(forKey: gatewayID)
            runtime.deliveryLoaded.remove(gatewayID)
            runtime.deliveryGeneration.removeValue(forKey: gatewayID)
            return
        }
        runtime.deliveryLoaded.insert(gatewayID)
        runtime.deliveryGeneration[gatewayID] = sourceFence
        do {
            let targets = try await GatewayREST.cronDeliveryTargets(
                baseURL: base, credential: credential)
            guard cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else {
                if runtime.deliveryGeneration[gatewayID] == sourceFence {
                    runtime.deliveryTargets.removeValue(forKey: gatewayID)
                    runtime.deliveryLoaded.remove(gatewayID)
                    runtime.deliveryGeneration.removeValue(forKey: gatewayID)
                }
                return
            }
            runtime.deliveryTargets[gatewayID] = targets
        } catch let error as GatewayError where error.code == GatewayREST.cronRESTUnavailable {
            // Delivery-target discovery and job update are routes on the same
            // Hermes cron router. This probe is what lets a legacy gateway
            // become inspect-only before the form offers a REST-only effort
            // picker that could never save.
            guard cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else {
                if runtime.deliveryGeneration[gatewayID] == sourceFence {
                    runtime.deliveryTargets.removeValue(forKey: gatewayID)
                    runtime.deliveryLoaded.remove(gatewayID)
                    runtime.deliveryGeneration.removeValue(forKey: gatewayID)
                }
                return
            }
            setCronRESTSupported(false, gatewayID: gatewayID, sourceFence: sourceFence)
            runtime.deliveryLoaded.remove(gatewayID)
            runtime.deliveryGeneration.removeValue(forKey: gatewayID)
        } catch {
            // No targets discovered = the picker stays hidden and every job
            // keeps whatever route it already has.
            if runtime.deliveryGeneration[gatewayID] == sourceFence {
                runtime.deliveryLoaded.remove(gatewayID)
                runtime.deliveryGeneration.removeValue(forKey: gatewayID)
                if cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) {
                    runtime.deliveryTargets.removeValue(forKey: gatewayID)
                }
            }
        }
    }

    /// Open the session a run produced. Cron runs are ordinary sessions
    /// (`cron_<job>_<stamp>`, cron/scheduler.py:4806), so the existing resume
    /// path takes them as-is. The owning profile is the one the server stamped
    /// on the row; a delegated routine's cron session lives in the launch
    /// store even though the work landed in the delegate's history.
    func openRoutineRun(_ run: CronRun, jobID: String, fallbackBotID: String) {
        guard let owner = routineRunBotID(run, routineID: jobID,
                                          fallbackBotID: fallbackBotID) else { return }
        openStoredSession(run.id, botID: owner)
    }

    internal func routineRunBotID(_ run: CronRun, routineID: String,
                                  fallbackBotID: String) -> String? {
        // Precedence: the profile the server stamped on the row, then the scope
        // the job's own RPCs use, then the row's exact bot tag. An unscoped row
        // with no server profile remains unresolved. `run.id` is a SESSION id,
        // never a job id, so it must not be used as a scope key.
        guard let target = routineTarget(routineID),
              let owner = run.profile ?? cronScope(routineID) ?? target.profile,
              !owner.isEmpty else { return nil }
        return target.route.gatewayID == LiveRuntime.shared.gatewayID
            ? owner
            : GatewayBotRoute(gatewayID: target.route.gatewayID, profile: owner).qualifiedID
    }
}

// MARK: - Writes

public extension AppModel {

    /// Create a routine for a bot.
    ///
    /// Two round trips by necessity: `cron.manage {action:"add"}` is the only
    /// create the socket has and it accepts name/schedule/prompt/repeat/
    /// continuity only (methods_tools.py:1716-1734) — no delivery route and no
    /// model pin. Those live on the REST create body (web_models.py:377), so a
    /// job that wants them is created over the socket and then PUT. Keeping the
    /// socket as the primary path means a gateway with no REST router still
    /// creates routines; it just cannot route or pin them.
    ///
    /// Prefer this over the plain create path: the delegation wrapper it emits
    /// shell-quotes every interpolation, which is the whole point of the v2
    /// marker (plugin.js:6098 `routinePrompt` + `shellQuote`).
    func scheduleRoutine(botID: String, title: String, schedule: String, instruction: String,
                         repeatForever: Bool = true, continuity: Bool = false,
                         deliver: [String] = [], model: String? = nil,
                         provider: String? = nil,
                         reasoningEffort: String? = nil) async throws -> CronCreateOutcome {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanInstruction.isEmpty else {
            throw GatewayError(code: -1, message: theme.copy.routineNeedsBoth(theme.themeID))
        }
        // The cron store round-trips through JSON on disk; a NUL would be
        // rejected there, and desktop refuses it at the form (plugin.js:6081).
        guard !cleanTitle.contains("\0"), !cleanInstruction.contains("\0") else {
            throw GatewayError(code: -1, message: theme.copy.routineNoNUL(theme.themeID))
        }
        guard let normalized = HermesSchedule.normalize(schedule) else {
            throw GatewayError(code: -1, message: theme.copy.scheduleHelp(theme.themeID))
        }
        guard mode == .live,
              let gatewayID = routineGatewayID(botID: botID) else {
            throw GatewayError(code: -3, message: theme.copy.routineNeedsGateway(theme.themeID))
        }
        // Hermes' unscoped cron.manage call addresses the process launch
        // HERMES_HOME, but this client has no authoritative process-profile
        // response. Keep the wire unscoped; never substitute a roster default.
        let launchProfile: String? = nil
        guard let sourceFence = cronSourceMutationFence(
            gatewayID: gatewayID, profile: nil) else {
            throw GatewayRouteError.noRoute
        }
        let client = try await routedClient(gatewayID: gatewayID)
        guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
            throw CancellationError()
        }
        // Capture the REST authority before the first suspension. If the
        // socket add commits, finishing its PUT is one transaction and must
        // keep using this exact source/profile even if navigation changes.
        let restAuthority = gatewayRESTContext(gatewayID: gatewayID)
        let botProfile = GatewayBotRoute(qualifiedID: botID)?.profile ?? botID

        // Validate every authored value before the socket creates anything.
        // Create is necessarily a two-step transaction (cron.manage add, then
        // REST PUT for fields the socket cannot carry); rejecting bad effort
        // after step one would leave a live, partially configured routine.
        let canonicalEffort: String?
        if let reasoningEffort {
            canonicalEffort = try CronReasoningEffort.canonicalMutation(reasoningEffort)
        } else {
            canonicalEffort = nil
        }

        // No launch profile means no REST-only create fields. In particular,
        // the editor's default `local` delivery is a UI floor, not a wire
        // update; serializing it here would turn an ordinary socket create
        // into an ambiguous cross-profile follow-up.
        let extras = CronCreateRESTPolicy.extras(
            launchProfile: launchProfile, deliver: deliver, model: model,
            provider: provider, reasoningEffort: canonicalEffort)

        let jobID: String
        do {
            jobID = try await client.cronAdd(
                name: Self.namespacedTitle(botID: botProfile, title: cleanTitle),
                schedule: normalized,
                prompt: Self.delegatedPrompt(botID: botProfile, title: cleanTitle,
                                             instruction: cleanInstruction,
                                             launchProfile: launchProfile),
                profile: launchProfile,
                repeatCount: repeatForever ? nil : 1,
                continuity: continuity)
        } catch {
            // A timeout/socket loss can happen after Hermes accepted the add.
            // There is no job id to safely reconcile, so dismiss the editor
            // with a warning-shaped terminal outcome instead of inviting a
            // duplicate retry. Classify the error before consulting the
            // source fence: validation/tool refusals remain thrown even if a
            // source replacement raced this call. Only ambiguous transport
            // failures become unresolved partials.
            guard CronCreateAddFailurePolicy.isAmbiguousAfterSend(error) else {
                throw error
            }
            let reason = CronCreateAddFailurePolicy.ambiguousPartialReason(
                for: error,
                sourceFenceStillCurrent: cronMutationFenceAccepts(
                    sourceFence, expectedClient: client)) ?? .addOutcomeUnknown
            return .acceptedPartial(CronCreateAddFailurePolicy.unresolvedPartial(
                reason: reason))
        }

        // An empty acknowledgement is not a known accepted job. Check it
        // before the known-job source fence: if a source replacement raced
        // this response, the outcome is still unresolved pre-ACK identity,
        // never a known-job `.sourceChanged` partial.
        if jobID.isEmpty {
            let reason = CronCreateAddFailurePolicy.unresolvedAddReason(
                sourceFenceStillCurrent: cronMutationFenceAccepts(
                    sourceFence, expectedClient: client))
            return .acceptedPartial(CronCreateAddFailurePolicy.unresolvedPartial(
                reason: reason))
        }

        // `cronAdd` has committed an irreversible job.  Re-check the exact
        // source before publishing activity, refreshing the list, or issuing
        // the REST half.  A retained pool client can be replaced while the
        // socket call is suspended; in that case preserve the accepted add as
        // a recoverable partial result and never retry it against a new source.
        guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
            return .acceptedPartial(CronAcceptedPartialOutcome(
                jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                reason: .sourceChanged))
        }
        let postAddDecision = CronCreatePostAddPolicy.decision(
            sourceFence: sourceFence,
            primaryGatewayID: LiveRuntime.shared.gatewayID,
            primaryGeneration: LiveRuntime.shared.generation,
            retainedGenerations: MultiGatewayRuntime.shared.routedEventGenerations,
            hasRESTOnlyFields: !extras.isEmpty,
            hasJobID: !jobID.isEmpty,
            hasRESTAuthority: restAuthority != nil && launchProfile != nil,
            restSupported: launchProfile != nil
                && cronRESTSupported(gatewayID: gatewayID,
                                     sourceFence: sourceFence) != false)
        guard postAddDecision != .acceptedButStale else {
            return .acceptedPartial(CronAcceptedPartialOutcome(
                jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                reason: .sourceChanged))
        }

        guard postAddDecision != .acceptedWithoutREST else {
            guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
                return .acceptedPartial(CronAcceptedPartialOutcome(
                    jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                    reason: .sourceChanged))
            }
            await refreshRoutinesLive(force: true)
            guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
                return .acceptedPartial(CronAcceptedPartialOutcome(
                    jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                    reason: .sourceChanged))
            }
            recordActivity(kind: .routine, botID: botID,
                           text: theme.copy.feedRoutineAdded(theme.themeID) + " — " + cleanTitle,
                           subtext: normalized)
            return .acceptedPartial(CronAcceptedPartialOutcome(
                jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                reason: .followUpUnavailable))
        }
        guard postAddDecision.shouldIssueRESTPatch,
              let (base, credential) = restAuthority else {
            await refreshRoutinesLive(force: true)
            guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
                return .acceptedPartial(CronAcceptedPartialOutcome(
                    jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                    reason: .sourceChanged))
            }
            recordActivity(kind: .routine, botID: botID,
                           text: theme.copy.feedRoutineAdded(theme.themeID) + " — " + cleanTitle,
                           subtext: normalized)
            return .completed
        }
        var sourceChangedAfterREST = false
        do {
            let saved = try await GatewayREST.updateCronJob(baseURL: base, credential: credential,
                                                            jobID: jobID, profile: launchProfile,
                                                            updates: extras)
            guard CronJobAcknowledgementPolicy.accepts(
                saved, jobID: jobID, profile: launchProfile) else {
                throw AckValidationError(
                    operation: "Create routine",
                    detail: "Hermes did not echo the exact cron job id and profile.")
            }
            guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
                sourceChangedAfterREST = true
                throw cronSourceChangedError()
            }
            let routineID: String
            if case .primary = sourceFence.generation {
                routineID = jobID
            } else {
                routineID = GatewayRoutineRoute(
                    gatewayID: gatewayID, jobID: jobID).qualifiedID
            }
            await refreshRoutinesLive(force: true)
            guard cronMutationFenceAccepts(sourceFence, expectedClient: client) else {
                sourceChangedAfterREST = true
                throw cronSourceChangedError()
            }
            guard let detailFence = cronRoutineMutationFence(routineID),
                  detailFence.target.route.gatewayID == gatewayID,
                  detailFence.target.route.jobID == jobID,
                  detailFence.target.profile == launchProfile,
                  detailFence.source.profile == launchProfile,
                  cronMutationFenceAccepts(detailFence, expectedClient: client) else {
                throw GatewayError(code: -4,
                                   message: "cron list did not confirm the created job's profile")
            }
            CronDetailRuntime.shared.detail[routineID] = saved
            CronDetailRuntime.shared.detailAuthority[routineID] = detailFence
            recordActivity(kind: .routine, botID: botID,
                           text: theme.copy.feedRoutineAdded(theme.themeID) + " — " + cleanTitle,
                           subtext: normalized)
            return .completed
        } catch {
            // A transport error after the request began is ambiguous: the
            // gateway may have accepted the PUT even though no response made
            // it back. Re-check the exact source in the catch, not only after
            // a successful response, so a replacement source never turns this
            // into an ordinary retryable "not routed" result.
            sourceChangedAfterREST = !cronMutationFenceAccepts(
                sourceFence, expectedClient: client)
            if !sourceChangedAfterREST,
               let gateway = error as? GatewayError,
               gateway.code == GatewayREST.cronRESTUnavailable {
                setCronRESTSupported(false, gatewayID: gatewayID, sourceFence: sourceFence)
            }
            // The routine exists and WILL fire; only the route/pin did not
            // land. Say exactly that — the alternative, deleting a job the
            // gateway already scheduled, is worse than an unrouted one.
            if !sourceChangedAfterREST {
                await refreshRoutinesLive(force: true)
                sourceChangedAfterREST = !cronMutationFenceAccepts(
                    sourceFence, expectedClient: client)
            }
            if sourceChangedAfterREST {
                return .acceptedPartial(CronAcceptedPartialOutcome(
                    jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                    reason: .sourceChanged))
            }
            return .acceptedPartial(CronAcceptedPartialOutcome(
                jobID: jobID, gatewayID: gatewayID, profile: launchProfile,
                reason: .followUpAmbiguous))
        }
    }

    /// Apply an edit. Only the keys that changed are sent: `update_job` merges
    /// updates over the stored record (cron/jobs.py:2105), so an untouched
    /// field cannot be cleared by a partial write.
    ///
    /// - Parameter model/provider: `.some("")` clears a pin, `nil` leaves it.
    /// - Parameter reasoningEffort: nil leaves the raw stored value untouched;
    ///   an empty string clears it; a level sets a canonical per-job pin.
    func saveRoutine(_ job: CronJobDetail, routineID: String, botID: String,
                     title: String, schedule: String,
                     instruction: String, deliver: [String]?, model: String?,
                     provider: String?, reasoningEffort: String? = nil,
                     continuity: Bool?) async throws {
        guard mode == .live, let fence = cronRoutineMutationFence(routineID),
              let target = routineTarget(routineID), target == fence.target,
              target.profile != nil,
              let sourceClient = cronSourceClient(gatewayID: target.route.gatewayID),
              let (base, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID) else {
            throw GatewayError(code: -3, message: theme.copy.routineNeedsGateway(theme.themeID))
        }
        guard CronJobAcknowledgementPolicy.accepts(
            job, jobID: target.route.jobID, profile: target.profile) else {
            throw AckValidationError(
                operation: "Save routine",
                detail: "The editor does not hold an exact cron job/profile record.")
        }
        var updates: [String: JSONValue] = [:]

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw GatewayError(code: -1, message: theme.copy.routineNeedsBoth(theme.themeID))
        }
        guard !cleanTitle.contains("\0"), !instruction.contains("\0") else {
            throw GatewayError(code: -1, message: theme.copy.routineNoNUL(theme.themeID))
        }
        let renamed = job.namespacePrefix + cleanTitle
        if renamed != job.name { updates["name"] = .string(renamed) }

        let typedSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedSchedule.isEmpty, typedSchedule != job.scheduleDisplay {
            guard let normalized = HermesSchedule.normalize(typedSchedule) else {
                throw GatewayError(code: -1, message: theme.copy.scheduleHelp(theme.themeID))
            }
            if normalized != job.scheduleDisplay { updates["schedule"] = .string(normalized) }
        }

        // A script-only job legitimately has no prompt (its script is the job).
        // Writing an empty prompt back would corrupt it, and writing a prompt
        // at all would trip the server's mode invariants — leave it alone.
        if !job.isScriptOnly {
            let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanInstruction.isEmpty else {
                throw GatewayError(code: -1, message: theme.copy.routineNeedsBoth(theme.themeID))
            }
            let rewritten = Self.delegatedPrompt(botID: target.bot.profile, title: cleanTitle,
                                                 instruction: cleanInstruction,
                                                 launchProfile: target.profile)
            if rewritten != job.prompt { updates["prompt"] = .string(rewritten) }
        }

        if let deliver {
            let route = deliver.isEmpty ? "local" : deliver.joined(separator: ",")
            if route != job.deliver { updates["deliver"] = .string(route) }
        }

        // Both axes always travel together on an agent job, so clearing one pin
        // actually clears it — the server normalizes ""/null to "no override"
        // (web_server.py:12289). Script-only jobs never run an agent, so their
        // stored values are left exactly as found.
        if !job.isScriptOnly, model != nil || provider != nil {
            let m = (model ?? job.model ?? "").trimmingCharacters(in: .whitespaces)
            let p = (provider ?? job.provider ?? "").trimmingCharacters(in: .whitespaces)
            if m != (job.model ?? "") { updates["model"] = m.isEmpty ? .null : .string(m) }
            if p != (job.provider ?? "") { updates["provider"] = p.isEmpty ? .null : .string(p) }
        }

        // Unlike model/provider, this pin is one independent axis. Omission
        // must mean "do not touch": that is what preserves a future or
        // hand-edited value during an unrelated title/schedule save.
        if !job.isScriptOnly, let reasoningEffort {
            updates["reasoning_effort"] = try CronReasoningEffort.wireMutation(reasoningEffort)
        }

        if let continuity, continuity != job.continuity {
            // Preserve any real cross-job dependency; only the reserved "self"
            // entry is the continuity toggle (cronjob_tools.py:665).
            var refs = job.externalContext
            if continuity { refs.append("self") }
            updates["context_from"] = .array(refs.map(JSONValue.string))
        }

        guard !updates.isEmpty else { return }
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        var savedDetail: CronJobDetail?
        do {
            let response = try await GatewayREST.updateCronJob(baseURL: base, credential: credential,
                                                               jobID: target.route.jobID,
                                                               profile: target.profile,
                                                               updates: updates)
            guard CronJobAcknowledgementPolicy.accepts(
                response, jobID: target.route.jobID, profile: target.profile) else {
                throw AckValidationError(
                    operation: "Save routine",
                    detail: "Hermes did not echo the exact cron job id and profile.")
            }
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
                throw cronSourceChangedError()
            }
            savedDetail = response
        } catch let error as GatewayError where error.code == GatewayREST.cronRESTUnavailable {
            if cronMutationFenceAccepts(fence, expectedClient: sourceClient) {
                setCronRESTSupported(false, gatewayID: target.route.gatewayID,
                                     sourceFence: fence.source)
                throw error
            }
            throw cronSourceChangedError()
        } catch {
            if !cronMutationFenceAccepts(fence, expectedClient: sourceClient) {
                throw cronSourceChangedError()
            }
            throw error
        }
        await refreshRoutinesLive(force: true)
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        if let savedDetail {
            CronDetailRuntime.shared.detail[routineID] = savedDetail
            CronDetailRuntime.shared.detailAuthority[routineID] = fence
            CronDetailRuntime.shared.detailError[routineID] = nil
        }
    }

    /// Pin the inference axes the drift guard recorded at creation.
    ///
    /// This is the server's own remediation for a drift-skipped job, spelled as
    /// a CLI hint in the error text (cron/scheduler.py:5354: `hermes cron edit
    /// <id> --provider <p> --model <m>`). Pinning the SNAPSHOT — not the
    /// gateway's current default — restores the behaviour the routine was
    /// created with, which is what "keep the original values" means there.
    func pinRoutineInference(_ job: CronJobDetail, routineID: String) async throws {
        guard mode == .live, let fence = cronRoutineMutationFence(routineID),
              let target = routineTarget(routineID), target == fence.target,
              target.profile != nil,
              let sourceClient = cronSourceClient(gatewayID: target.route.gatewayID),
              let (base, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID) else {
            throw GatewayError(code: -3, message: theme.copy.routineNeedsGateway(theme.themeID))
        }
        guard CronJobAcknowledgementPolicy.accepts(
            job, jobID: target.route.jobID, profile: target.profile) else {
            throw AckValidationError(
                operation: "Pin routine inference",
                detail: "The editor does not hold an exact cron job/profile record.")
        }
        var updates: [String: JSONValue] = [:]
        if job.provider == nil, let snapshot = job.providerSnapshot {
            updates["provider"] = .string(snapshot)
        }
        if job.model == nil, let snapshot = job.modelSnapshot {
            updates["model"] = .string(snapshot)
        }
        guard !updates.isEmpty else { return }
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        var savedDetail: CronJobDetail?
        do {
            let response = try await GatewayREST.updateCronJob(baseURL: base, credential: credential,
                                                               jobID: target.route.jobID,
                                                               profile: target.profile,
                                                               updates: updates)
            guard CronJobAcknowledgementPolicy.accepts(
                response, jobID: target.route.jobID, profile: target.profile) else {
                throw AckValidationError(
                    operation: "Pin routine inference",
                    detail: "Hermes did not echo the exact cron job id and profile.")
            }
            guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
                throw cronSourceChangedError()
            }
            savedDetail = response
        } catch let error as GatewayError where error.code == GatewayREST.cronRESTUnavailable {
            if cronMutationFenceAccepts(fence, expectedClient: sourceClient) {
                setCronRESTSupported(false, gatewayID: target.route.gatewayID,
                                     sourceFence: fence.source)
                throw error
            }
            throw cronSourceChangedError()
        } catch {
            if !cronMutationFenceAccepts(fence, expectedClient: sourceClient) {
                throw cronSourceChangedError()
            }
            throw error
        }
        await refreshRoutinesLive(force: true)
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        if let savedDetail {
            CronDetailRuntime.shared.detail[routineID] = savedDetail
            CronDetailRuntime.shared.detailAuthority[routineID] = fence
            CronDetailRuntime.shared.detailError[routineID] = nil
        }
    }
}

// MARK: - The delegation wrapper

public extension AppModel {

    /// Jobs are namespaced "[bot:<name>] <routine>" so a gateway that ignores
    /// the `profile` scope can still attribute them (plugin.js:5966).
    static func namespacedTitle(botID: String, title: String) -> String {
        "[bot:\(botID)] \(title)"
    }

    /// The stored prompt for a routine.
    ///
    /// A routine owned by the launch profile runs its instruction directly. Any
    /// other bot's routine has to re-enter that profile, so it stores the v2
    /// delegation wrapper: the marker, the prose, and a `hermes -p … chat` line
    /// the agent is told to run. Desktop's version is plugin.js:6098.
    ///
    /// EVERY interpolation into that command line is shell-quoted. This is the
    /// entire reason the v2 marker exists — the unmarked ancestor pasted raw
    /// text between single quotes, so an instruction containing an apostrophe
    /// escaped the quoting. Jobs still carrying the unmarked form are
    /// quarantined on sight (`quarantineLegacyRoutines`).
    static func delegatedPrompt(botID: String, title: String, instruction: String,
                                launchProfile: String? = nil) -> String {
        if let launchProfile,
           botID.lowercased() == launchProfile.lowercased() {
            return instruction
        }
        return safeRoutineMarker + """
        You are running the scheduled routine "\(title)" for agent '\(botID)'. \
        Execute it AS that agent so the run lands in its own history: run this in the terminal and \
        relay the output:

        hermes -p \(shellQuote(botID)) chat -c \(shellQuote("Routine: \(title)")) \
        -q \(shellQuote("[Scheduled routine] \(instruction)"))

        If the command fails, report the error instead.
        """
    }

    /// POSIX single-quoting: close, escape, reopen. The one form that is safe
    /// for arbitrary text (plugin.js:6076 `shellQuote`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Recover the bare instruction from a stored prompt so an edit shows what
    /// the person wrote instead of the wrapper the app generated. Returns nil
    /// when the prompt is not a wrapper this app can safely rewrite.
    static func routineInstruction(in prompt: String) -> String? {
        guard prompt.hasPrefix(safeRoutineMarker) else {
            // Not delegated: the prompt IS the instruction.
            return prompt.hasPrefix(legacyRoutinePrefix) ? nil : prompt
        }
        guard let commandStart = prompt.range(of: "\nhermes -p ") else { return nil }
        let rest = prompt[commandStart.upperBound...]
        let line = rest.prefix { $0 != "\n" }
        guard let qMark = line.range(of: " -q '") else { return nil }
        let quoted = line[qMark.upperBound...]
        guard quoted.hasSuffix("'") else { return nil }
        let unquoted = String(quoted.dropLast())
            .replacingOccurrences(of: "'\"'\"'", with: "'")
        let tag = "[Scheduled routine] "
        return unquoted.hasPrefix(tag) ? String(unquoted.dropFirst(tag.count)) : unquoted
    }

    /// One human line for an error of any origin.
    static func reason(_ error: Error) -> String {
        (error as? GatewayError)?.message ?? error.localizedDescription
    }
}

// MARK: - Formatting

public extension AppModel {

    /// "2m 14s" / "1h 06m" — a run's wall time.
    static func runDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    /// Absolute stamp for a run row — history is read across days, so a bare
    /// clock time is ambiguous in a way the roster's "HH:mm" never is. The two
    /// formatters are built once: a twenty-row history re-renders on every
    /// cron.changed, and DateFormatter construction is not cheap.
    static func runStamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return (Calendar.current.isDateInToday(date) ? todayStamp : datedStamp).string(from: date)
    }

    private static let todayStamp = localizedFormatter("jmm")
    private static let datedStamp = localizedFormatter("MMMd jmm")

    private static func localizedFormatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}

// MARK: - Copy

public extension CopyPack {

    // Detail screen chrome.
    func routineDetailKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "ROUTINE"
        case .control: "CRON JOB"
        case .ink: "THE RITE"
        }
    }

    func routineDetailLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Loading the full routine detail…"
        case .control: "READING AUTHORITATIVE JOB DETAIL…"
        case .ink: "Reading the whole rite…"
        }
    }

    func routineDetailUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The full routine detail is unavailable, so editing is paused."
        case .control: "DETAIL UNAVAILABLE · EDITING LOCKED UNTIL READ SUCCEEDS"
        case .ink: "The whole rite could not be read, so its words remain untouched."
        }
    }

    func routineRetryDetail(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Retry detail"
        case .control: "RETRY DETAIL"
        case .ink: "Read again"
        }
    }

    func routineEditAction(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Edit"
        case .control: "EDIT"
        case .ink: "Amend"
        }
    }

    func routineSaveAction(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save"
        case .control: "COMMIT"
        case .ink: "Seal"
        }
    }

    func routineSavedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved."
        case .control: "WRITTEN"
        case .ink: "The amendment is sealed."
        }
    }

    func routineNewTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "New routine"
        case .control: "NEW CRON JOB"
        case .ink: "Inscribe a rite"
        }
    }

    // Field labels.
    func routineWhenLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "When"
        case .control: "SCHEDULE"
        case .ink: "When it is kept"
        }
    }

    func routineDoLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What it does"
        case .control: "PROMPT"
        case .ink: "What is asked"
        }
    }

    func routineTitleLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name"
        case .control: "NAME"
        case .ink: "Its name"
        }
    }

    func routineDeliverLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Send results to"
        case .control: "DELIVER"
        case .ink: "Where word is sent"
        }
    }

    func routineDeliverLocal(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Keep on the gateway"
        case .control: "LOCAL (SAVE ONLY)"
        case .ink: "Kept at the hearth"
        }
    }

    func routineDeliverUnset(_ t: ThemeID) -> String {
        switch t {
        case .soft: "needs a home channel"
        case .control: "NO HOME CHANNEL"
        case .ink: "no channel yet"
        }
    }

    func routineInferenceLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Model"
        case .control: "MODEL PIN"
        case .ink: "The mind it uses"
        }
    }

    func routineReasoningLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reasoning"
        case .control: "REASONING EFFORT"
        case .ink: "How deeply it thinks"
        }
    }

    func routineReasoningFollowConfig(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Follow model / gateway settings"
        case .control: "CONFIG RESOLUTION"
        case .ink: "Follow the mind's own setting"
        }
    }

    func routineReasoningOff(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Off"
        case .control: "OFF"
        case .ink: "No extended thought"
        }
    }

    func routineReasoningUnknown(_ t: ThemeID, value: String) -> String {
        switch t {
        case .soft: "Unknown stored value: \(value)"
        case .control: "UNKNOWN · \(value)"
        case .ink: "An unknown mark: \(value)"
        }
    }

    func routineReasoningPickerHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Choose this routine's reasoning effort, or follow configuration."
        case .control: "SELECT PER-JOB EFFORT OR CONFIG RESOLUTION."
        case .ink: "Choose this rite's depth of thought, or let its mind decide."
        }
    }

    func routineReasoningConfigPrecedence(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Resolved when it runs: this model's override first, then the gateway default."
        case .control: "RUN-TIME RESOLUTION · MODEL OVERRIDE > AGENT DEFAULT"
        case .ink: "When it is kept, the model's own rule comes first, then the gateway's."
        }
    }

    func routineReasoningPinned(_ t: ThemeID, value: String) -> String {
        switch t {
        case .soft: "Routine override: \(value). It wins over model and gateway settings; the provider may clamp unsupported levels."
        case .control: "JOB PIN · \(value.uppercased()) · OVERRIDES MODEL/GLOBAL; PROVIDER MAY CLAMP"
        case .ink: "This rite asks for \(value). It outranks the model and gateway rules, though the provider may temper it."
        }
    }

    func routineReasoningInvalid(_ t: ThemeID, value: String) -> String {
        switch t {
        case .soft: "“\(value)” is not recognized. Hermes ignores it and follows configuration at run time; unrelated edits preserve it."
        case .control: "INVALID STORED VALUE \(value.debugDescription) · IGNORED AT RUN TIME · CONFIG WINS"
        case .ink: "“\(value)” is unknown. Hermes passes it by and follows configuration; other amendments leave the mark untouched."
        }
    }

    func routineReasoningUnusedForScript(_ t: ThemeID, value: String) -> String {
        switch t {
        case .soft: "Stored as \(value), but unused: this routine runs a script without an agent or model."
        case .control: "STORED \(value.uppercased()) · INERT FOR NO-AGENT SCRIPT"
        case .ink: "Written as \(value), but unused: this rite runs only its script, with no mind invoked."
        }
    }

    func routineProviderPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Provider — leave blank to follow the gateway"
        case .control: "PROVIDER (BLANK = GLOBAL)"
        case .ink: "Provider — blank to follow the gateway"
        }
    }

    func routineModelPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Model — leave blank to follow the gateway"
        case .control: "MODEL (BLANK = GLOBAL)"
        case .ink: "Model — blank to follow the gateway"
        }
    }

    func routineFollowsGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Follows the gateway's default"
        case .control: "UNPINNED — FOLLOWS GLOBAL"
        case .ink: "It follows the gateway's own mind"
        }
    }

    func routineRecordedAs(_ t: ThemeID) -> String {
        switch t {
        case .soft: "recorded as"
        case .control: "SNAPSHOT"
        case .ink: "recorded as"
        }
    }

    func routinePinAction(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pin the recorded model"
        case .control: "PIN SNAPSHOT"
        case .ink: "Bind it to the recorded mind"
        }
    }

    func routineSnapshotWhy(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This routine did not pin a model, so Hermes recorded which one it "
            + "resolved to. If the gateway's default moves, the run is skipped instead of "
            + "billed to a different model — pin it to keep running."
        case .control: "UNPINNED AXIS. HERMES SNAPSHOTTED THE RESOLUTION AT CREATE TIME. "
            + "IF GLOBAL CONFIG DRIFTS THE RUN IS SKIPPED, NOT REROUTED. PIN TO RE-ARM."
        case .ink: "No mind was named for this rite, so Hermes wrote down the one it found. "
            + "Should the gateway change its mind, the rite is skipped rather than spent "
            + "elsewhere — bind it, and it keeps."
        }
    }

    // Health banners.
    func routineDriftTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Skipped — the gateway's model changed"
        case .control: "SKIPPED · INFERENCE DRIFT"
        case .ink: "Skipped — the gateway changed its mind"
        }
    }

    func routineBlockedTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Blocked before it ran"
        case .control: "BLOCKED · CONFIG"
        case .ink: "Refused before it began"
        }
    }

    func routineFireErrorTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A scheduled run never reached the agent"
        case .control: "FIRE NOT DELIVERED"
        case .ink: "The call never reached the familiar"
        }
    }

    func routineFailedTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The last run failed"
        case .control: "LAST RUN FAILED"
        case .ink: "The last keeping failed"
        }
    }

    func routineDeliveryFailedTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "It ran, but the result could not be delivered"
        case .control: "RAN · DELIVERY FAILED"
        case .ink: "It was kept, but no word arrived"
        }
    }

    func routinePausedTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Paused"
        case .control: "PAUSED"
        case .ink: "At rest"
        }
    }

    func routineFailureStreak(_ t: ThemeID, count: Int) -> String {
        switch t {
        case .soft: "\(count) failed runs in a row"
        case .control: "STREAK · \(count) CONSECUTIVE FAILURES"
        case .ink: "\(count) keepings failed, one after another"
        }
    }

    // Quarantine (legacy delegated routines).
    func routineQuarantined(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Routine paused for safety"
        case .control: "ROUTINE QUARANTINED"
        case .ink: "A rite was set aside"
        }
    }

    func routineQuarantineWhy(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This routine was written before the delegation command escaped its "
            + "inputs. Delete it and create it again to run it."
        case .control: "PRE-V2 DELEGATION WRAPPER — UNESCAPED SHELL INTERPOLATION. "
            + "DELETE AND RECREATE."
        case .ink: "This rite was inscribed before the words were properly bound. "
            + "Strike it out and inscribe it anew."
        }
    }

    // Run history.
    func routineRunHistory(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Run history"
        case .control: "RUNS"
        case .ink: "The record of keepings"
        }
    }

    func routineLoadingRuns(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reading the run history…"
        case .control: "READING RUNS…"
        case .ink: "Turning the pages…"
        }
    }

    func routineNoRuns(_ t: ThemeID) -> String {
        switch t {
        case .soft: "It hasn't run yet."
        case .control: "NO RUNS RECORDED"
        case .ink: "It has not yet been kept."
        }
    }

    func routineRunRunning(_ t: ThemeID) -> String {
        switch t {
        case .soft: "running"
        case .control: "RUNNING"
        case .ink: "in hand"
        }
    }

    func routineRunFinished(_ t: ThemeID) -> String {
        switch t {
        case .soft: "finished"
        case .control: "DONE"
        case .ink: "kept"
        }
    }

    func routineRunInterrupted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "did not finish"
        case .control: "INTERRUPTED"
        case .ink: "left unfinished"
        }
    }

    func routineOpenRunHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tap a run to open its transcript."
        case .control: "SELECT A RUN TO OPEN ITS SESSION"
        case .ink: "Touch a keeping to read what was said."
        }
    }

    // Errors and guards.
    func routineNeedsBoth(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A routine needs a name and something to do."
        case .control: "NAME AND PROMPT REQUIRED"
        case .ink: "A rite needs a name and a task."
        }
    }

    func routineNoNUL(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name and instruction cannot contain NUL."
        case .control: "NUL (U+0000) NOT PERMITTED"
        case .ink: "No null character may be inscribed."
        }
    }

    func routineNeedsGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Connect a gateway to schedule routines."
        case .control: "NO LINK — CANNOT SCHEDULE"
        case .ink: "Open a way to the gateway first."
        }
    }

    func routineMadeNotRouted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The routine was created, but its delivery and model settings "
            + "could not be applied. Open it to try again."
        case .control: "JOB CREATED · DELIVER/MODEL NOT APPLIED — EDIT TO RETRY"
        case .ink: "The rite is inscribed, but its channel and mind were not bound. "
            + "Open it and try once more."
        }
    }

    func routineMadeSourceChanged(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The routine was created, but the gateway changed before Talaria "
            + "could confirm it. Open it to verify; no automatic retry was attempted."
        case .control: "JOB CREATED · SOURCE CHANGED BEFORE CONFIRMATION — VERIFY IN EDITOR"
        case .ink: "The rite is inscribed, but its gateway changed before it could be "
            + "witnessed. Open it to verify; it was not retried."
        }
    }

    func routineMadeFollowUpAmbiguous(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The routine was created, but Talaria could not confirm its delivery or model settings. "
            + "Open it to verify; do not schedule it again."
        case .control: "JOB CREATED · FOLLOW-UP NOT CONFIRMED — OPEN TO VERIFY; DO NOT RETRY CREATE"
        case .ink: "The rite is inscribed, but its second witness did not arrive. "
            + "Open it to verify; do not inscribe another."
        }
    }

    /// Used only when the socket add itself returned no authoritative
    /// acknowledgement. This copy must never imply that the job was created,
    /// scheduled, or safe to retry.
    func toastRoutineOutcomeUnknown(_ title: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t confirm “\(title)”"
        case .control: "OUTCOME UNKNOWN — \(title.uppercased())"
        case .ink: "The outcome of “\(title)” is unwitnessed"
        }
    }

    func routineAddOutcomeUnknown(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Talaria could not confirm whether this routine was added. "
            + "Check the routine list; do not retry yet."
        case .control: "OUTCOME UNKNOWN — CHECK ROUTINE LIST; DO NOT RETRY YET"
        case .ink: "The rite’s outcome is unwitnessed. Check the routine list; "
            + "do not retry yet."
        }
    }

    func routineSourceChanged(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway changed before Talaria could confirm this routine action. "
            + "Nothing was reported as successful; reopen the routine on the current gateway."
        case .control: "SOURCE CHANGED BEFORE CONFIRMATION — NO SUCCESS RECORDED; REOPEN ROUTINE"
        case .ink: "The gateway changed before this rite could be witnessed. Nothing was "
            + "claimed; open it again from the current way."
        }
    }

    func routineWrapperNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This routine runs as another agent, so what you write is wrapped in a "
            + "hand-off command before it is stored."
        case .control: "CROSS-PROFILE JOB — PROMPT IS WRAPPED IN THE V2 DELEGATION COMMAND"
        case .ink: "This rite is kept in another familiar's name; your words are carried "
            + "inside the hand-off."
        }
    }

    func routineScriptNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This routine runs a script on the gateway, not a prompt. Edit the "
            + "script on the host that runs Hermes."
        case .control: "SCRIPT JOB (no_agent) — PROMPT NOT USED. EDIT THE SCRIPT ON THE HOST."
        case .ink: "This rite runs a script upon the gateway rather than asking anything. "
            + "Its text lives on that machine."
        }
    }

    func routineDeleteConfirm(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete this routine?"
        case .control: "DELETE THIS CRON JOB?"
        case .ink: "Strike this rite from the record?"
        }
    }

    /// Label for the "N of M runs used" fact on a job with a repeat cap.
    func routineRepeatCap(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Runs used"
        case .control: "REPEAT"
        case .ink: "Keepings used"
        }
    }
}
