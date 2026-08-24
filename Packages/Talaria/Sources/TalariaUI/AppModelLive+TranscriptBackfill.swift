import Foundation
import TalariaKit

// MARK: - Stored transcript backfill

/// The user-visible state of the older-history control.
///
/// `unknown` is deliberately distinct from `more`: a full page without a
/// server continuation hint is not proof that history exists, but it is still
/// safe to offer one explicitly requested, bounded follow-up read.
public enum TranscriptBackfillStatus: Sendable, Equatable {
    case unavailable
    case loading
    case more
    case unknown
    case exhausted
    case limited
    case failed
}

/// A deliberately finite foreground ledger. Each network response is bounded
/// independently, but without a cumulative ceiling repeated user requests
/// could still make the main-actor transcript projection grow toward the
/// transport's much larger offset limit.
public enum TranscriptBackfillLimits {
    public static let maximumRetainedRows = 2_000
}

/// Presentation facts for one exact, durable stored transcript.
///
/// This value belongs to `ChatState` so SwiftUI observes both a page result and
/// an error/retry transition. The raw rows and the captured client authority
/// intentionally stay in the private runtime ledger below: neither is UI
/// state, and neither may be reused by another chat merely because its profile
/// has the same display name.
public struct TranscriptBackfillPresentation: Sendable, Equatable {
    public var source: StoredTranscriptPageSource?
    /// The durable root used in every request. It never changes to a resolved
    /// compression tip.
    public var rootStoredSessionID: String?
    /// The most recent resolved tip the server actually echoed. It is display
    /// evidence only; no future page is addressed to it.
    public var resolvedSessionID: String?
    public var status: TranscriptBackfillStatus
    /// The only offset the ledger may request next. Nil means there is no
    /// bounded continuation request available.
    public var nextOffset: Int?
    /// Increments after a successful raw-row prepend, allowing the view to
    /// restore its reader anchor without treating an ordinary live append as a
    /// prepend.
    public var prependGeneration: UInt

    public init(source: StoredTranscriptPageSource? = nil,
                rootStoredSessionID: String? = nil,
                resolvedSessionID: String? = nil,
                status: TranscriptBackfillStatus = .unavailable,
                nextOffset: Int? = nil,
                prependGeneration: UInt = 0) {
        self.source = source
        self.rootStoredSessionID = rootStoredSessionID
        self.resolvedSessionID = resolvedSessionID
        self.status = status
        self.nextOffset = nextOffset
        self.prependGeneration = prependGeneration
    }

    public var canLoadEarlier: Bool {
        nextOffset != nil && (status == .more || status == .unknown || status == .failed)
    }

    public var controlTitle: String {
        switch status {
        case .unavailable:
            return ""
        case .loading:
            return "Loading earlier messages…"
        case .more, .unknown, .failed:
            return "Show earlier"
        case .exhausted:
            return "Beginning of conversation"
        case .limited:
            return "Earlier history limit reached"
        }
    }

    /// A deliberately small copy surface. Server responses can carry arbitrary
    /// error text, so failed reads never render it directly in the transcript.
    public var controlDetail: String? {
        switch status {
        case .unknown:
            return "Older messages may be available."
        case .failed:
            return "Couldn’t load earlier messages. Try again."
        case .exhausted:
            return "No earlier messages are available."
        case .limited:
            return "This device retained the newest 2,000 transcript rows."
        default:
            return nil
        }
    }
}

/// A raw, chronological ledger for a single stored transcript source.
///
/// The REST endpoint pages from the newest end while rows inside each response
/// remain chronological. Between requests a new row can land at that newest
/// end, shifting a later reverse offset. We therefore retain raw rows, remove
/// only exact durable-id overlap, and reject a page that would require a
/// text/position guess. The caller then sends the retained raw sequence back
/// through the existing transcript hydrator, preserving ordered parts, tool
/// pairing, media directives, and response-alternative lifecycle rules.
struct StoredTranscriptBackfillLedger: Equatable {
    enum MergeError: Error, Equatable {
        case sourceMismatch
        case unexpectedOffset
        case identitylessOverlap
        case nonSuffixOverlap
    }

    let source: StoredTranscriptPageSource
    let rootStoredSessionID: String
    private(set) var resolvedSessionID: String?
    private(set) var rows: [StoredTranscriptRow]
    private var knownIdentities: Set<StoredTranscriptRow.Identity>
    private(set) var continuation: StoredTranscriptPage.Continuation
    private(set) var nextOffset: Int?
    private(set) var reachedLocalLimit = false

    init(tail page: StoredTranscriptPage, source: StoredTranscriptPageSource) throws {
        guard source.isUsable, page.matches(source),
              page.requestedSessionID == source.storedSessionID else {
            throw MergeError.sourceMismatch
        }
        self.source = source
        rootStoredSessionID = source.storedSessionID
        resolvedSessionID = page.resolvedSessionIDWasEchoed ? page.resolvedSessionID : nil
        rows = page.rows
        knownIdentities = Set(page.rows.compactMap(\.identity))
        continuation = page.continuation
        nextOffset = page.nextOffset
    }

    mutating func prepend(_ page: StoredTranscriptPage) throws -> [StoredTranscriptRow] {
        guard page.matches(source), page.requestedSessionID == rootStoredSessionID else {
            throw MergeError.sourceMismatch
        }
        guard page.offset == nextOffset else { throw MergeError.unexpectedOffset }

        // A reverse-page seam is potentially overlapping whenever a live
        // append raced these two reads. If either side has an id-less row,
        // deciding whether it is the same row from text (or from its index)
        // would silently drop or duplicate durable history. Refuse that seam.
        guard rows.allSatisfy({ $0.identity != nil }),
              page.rows.allSatisfy({ $0.identity != nil }) else {
            throw MergeError.identitylessOverlap
        }

        let overlapIndices = page.rows.indices.filter { index in
            guard let identity = page.rows[index].identity else { return false }
            return knownIdentities.contains(identity)
        }
        if let firstOverlap = overlapIndices.first {
            // In chronological order the previously retained tail can only
            // overlap a suffix of an older page. An interior overlap means the
            // gateway's moving offset no longer admits an unambiguous prepend.
            let expected = Array(firstOverlap..<page.rows.endIndex)
            guard overlapIndices == expected else { throw MergeError.nonSuffixOverlap }
        }

        let fresh = page.rows.filter { row in
            guard let identity = row.identity else { return false }
            return !knownIdentities.contains(identity)
        }
        let remainingCapacity = max(0, TranscriptBackfillLimits.maximumRetainedRows - rows.count)
        // A partial final admission keeps the newest portion of this older
        // page—the rows adjacent to the already-retained tail—rather than
        // creating a gap at the page seam.
        let admittedFresh = fresh.count > remainingCapacity
            ? Array(fresh.suffix(remainingCapacity))
            : fresh
        for row in admittedFresh {
            if let identity = row.identity { knownIdentities.insert(identity) }
        }
        rows = admittedFresh + rows
        if page.resolvedSessionIDWasEchoed { resolvedSessionID = page.resolvedSessionID }
        continuation = page.continuation
        reachedLocalLimit = fresh.count > remainingCapacity
            || (rows.count >= TranscriptBackfillLimits.maximumRetainedRows
                && page.nextOffset != nil)
        nextOffset = reachedLocalLimit ? nil : page.nextOffset
        return admittedFresh
    }

    var status: TranscriptBackfillStatus {
        if reachedLocalLimit { return .limited }
        switch continuation {
        case .complete: return .exhausted
        case .more: return nextOffset == nil ? .exhausted : .more
        case .unknown: return .unknown
        }
    }
}

@MainActor
fileprivate struct TranscriptBackfillLease {
    let id: UUID
    let botID: String
    let chatID: ObjectIdentifier
    let chatIdentity: UUID
    let runtimeSessionID: String?
    let route: GatewayBotRoute
    let source: StoredTranscriptPageSource
    let authority: TranscriptHydrationSourceAuthority
    let client: GatewayClient
}

@MainActor
fileprivate struct TranscriptBackfillRead {
    let token: UUID
    let leaseID: UUID
    let task: Task<Bool, Never>
}

/// Side-table storage for mutable backfill work. `ChatState` owns only the
/// observable presentation facts; source/client authority is deliberately
/// ephemeral and cancellation-owned by this runtime.
@MainActor
final class TranscriptBackfillRuntime {
    static let shared = TranscriptBackfillRuntime()

    var ledgers: [StoredTranscriptPageSource: StoredTranscriptBackfillLedger] = [:]
    private var leases: [StoredTranscriptPageSource: TranscriptBackfillLease] = [:]
    private var reads: [StoredTranscriptPageSource: TranscriptBackfillRead] = [:]

    fileprivate func install(_ ledger: StoredTranscriptBackfillLedger, lease: TranscriptBackfillLease) {
        cancel(source: ledger.source)
        ledgers[ledger.source] = ledger
        leases[ledger.source] = lease
    }

    fileprivate func read(for source: StoredTranscriptPageSource) -> TranscriptBackfillRead? {
        reads[source]
    }

    fileprivate func setRead(_ read: TranscriptBackfillRead, for source: StoredTranscriptPageSource) {
        reads[source] = read
    }

    func finishRead(source: StoredTranscriptPageSource, token: UUID) {
        guard reads[source]?.token == token else { return }
        reads[source] = nil
    }

    func cancel(source: StoredTranscriptPageSource) {
        reads[source]?.task.cancel()
        reads[source] = nil
        ledgers[source] = nil
        leases[source] = nil
    }

    /// Cancel only the suspended network read while retaining the accepted raw
    /// tail/cursor. A view disappearing should not erase already-loaded
    /// history, but its task must not later claim scroll ownership.
    func cancelRead(source: StoredTranscriptPageSource) {
        reads[source]?.task.cancel()
    }

    func cancel(chatID: ObjectIdentifier) {
        let sources = leases.compactMap { source, lease in
            lease.chatID == chatID ? source : nil
        }
        for source in sources { cancel(source: source) }
    }

    func resetPrimaryScope() {
        let sources = leases.compactMap { source, lease in
            lease.route.gatewayID == LiveRuntime.shared.gatewayID ? source : nil
        }
        for source in sources { cancel(source: source) }
    }

    func resetRoutedScope(gatewayID: String) {
        let sources = leases.compactMap { source, lease in
            lease.route.gatewayID == gatewayID ? source : nil
        }
        for source in sources { cancel(source: source) }
    }

    fileprivate func lease(for source: StoredTranscriptPageSource) -> TranscriptBackfillLease? {
        leases[source]
    }
}

extension AppModel {
    /// Publish the initial 200-row raw tail as a source-fenced paging ledger.
    /// This is invoked only after canonical/session hydration has accepted the
    /// same page, so the visible tail's behavior remains unchanged.
    func installTranscriptBackfillTail(
        _ page: StoredTranscriptPage,
        botID: String,
        chat: ChatState,
        route: GatewayBotRoute,
        authority: TranscriptHydrationSourceAuthority,
        runtimeSessionID: String
    ) async {
        guard let source = page.source,
              source.isUsable,
              page.matches(source),
              page.requestedSessionID == source.storedSessionID,
              source.gatewayID == route.gatewayID,
              source.profile == route.profile,
              await transcriptBackfillLeaseIsCurrent(
                botID: botID, chat: chat, route: route, source: source,
                runtimeSessionID: runtimeSessionID, authority: authority)
        else { return }
        do {
            let ledger = try StoredTranscriptBackfillLedger(tail: page, source: source)
            let lease = TranscriptBackfillLease(
                id: UUID(), botID: botID, chatID: ObjectIdentifier(chat),
                chatIdentity: chat.chatIdentity, runtimeSessionID: runtimeSessionID,
                route: route, source: source, authority: authority, client: authority.client)
            TranscriptBackfillRuntime.shared.install(ledger, lease: lease)
            chat.transcriptBackfill = TranscriptBackfillPresentation(
                source: source, rootStoredSessionID: ledger.rootStoredSessionID,
                resolvedSessionID: ledger.resolvedSessionID,
                status: ledger.status, nextOffset: ledger.nextOffset,
                prependGeneration: chat.transcriptBackfill.prependGeneration)
        } catch {
            // A protocol-valid page should always make a ledger. If an
            // internal invariant says otherwise, do not expose a button that
            // could attach a later page to an untrusted tail.
            chat.transcriptBackfill = TranscriptBackfillPresentation()
        }
    }

    /// Read exactly one older raw page for the current chat. Calls sharing the
    /// same source await the same task; no second request is sent while a page
    /// is in flight. The return value says whether a page was accepted (not
    /// whether it happened to add visible bubbles—hidden/overlap-only raw rows
    /// still advance the source-fenced ledger safely).
    @discardableResult
    public func loadEarlierTranscript(botID: String) async -> Bool {
        guard let chat = chats[botID],
              let source = chat.transcriptBackfill.source,
              let lease = TranscriptBackfillRuntime.shared.lease(for: source),
              let ledger = TranscriptBackfillRuntime.shared.ledgers[source],
              chat.transcriptBackfill.canLoadEarlier,
              let offset = ledger.nextOffset,
              await transcriptBackfillLeaseIsCurrent(lease)
        else { return false }

        if let existing = TranscriptBackfillRuntime.shared.read(for: source) {
            return await existing.task.value
        }

        let request = StoredTranscriptPageRequest(
            source: source, offset: offset, limit: StoredTranscriptPageRequest.defaultLimit,
            includeCompacted: true)
        let token = UUID()
        chat.transcriptBackfill.status = .loading
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            do {
                let page = try await lease.client.storedTranscriptPage(request)
                try Task.checkCancellation()
                return try await self.acceptEarlierTranscriptPage(
                    page, source: source, token: token, lease: lease)
            } catch is CancellationError {
                await self.restoreTranscriptBackfillAfterCancellation(
                    source: source, token: token, lease: lease)
                return false
            } catch {
                await self.failEarlierTranscriptRead(source: source, token: token, lease: lease)
                return false
            }
        }
        TranscriptBackfillRuntime.shared.setRead(
            TranscriptBackfillRead(token: token, leaseID: lease.id, task: task), for: source)
        return await task.value
    }

    /// Explicitly discard a chat's retained raw pages. ChatState calls this on
    /// a runtime/durable-session replacement; lifecycle teardown calls the
    /// scoped reset helpers below. It is intentionally idempotent.
    func discardTranscriptBackfill(chat: ChatState) {
        TranscriptBackfillRuntime.shared.cancel(chatID: ObjectIdentifier(chat))
        chat.transcriptBackfill = TranscriptBackfillPresentation()
    }

    func cancelTranscriptBackfillRead(botID: String) {
        guard let source = chats[botID]?.transcriptBackfill.source else { return }
        TranscriptBackfillRuntime.shared.cancelRead(source: source)
    }

    func resetPrimaryTranscriptBackfillScope() {
        TranscriptBackfillRuntime.shared.resetPrimaryScope()
    }

    func resetRoutedTranscriptBackfillScope(gatewayID: String) {
        TranscriptBackfillRuntime.shared.resetRoutedScope(gatewayID: gatewayID)
    }

    private func acceptEarlierTranscriptPage(
        _ page: StoredTranscriptPage,
        source: StoredTranscriptPageSource,
        token: UUID,
        lease: TranscriptBackfillLease
    ) async throws -> Bool {
        guard page.matches(source),
              TranscriptBackfillRuntime.shared.read(for: source)?.token == token,
              TranscriptBackfillRuntime.shared.read(for: source)?.leaseID == lease.id,
              await transcriptBackfillLeaseIsCurrent(lease)
        else { throw CancellationError() }
        guard var ledger = TranscriptBackfillRuntime.shared.ledgers[source] else {
            throw CancellationError()
        }

        _ = try ledger.prepend(page)
        guard await transcriptBackfillLeaseIsCurrent(lease),
              TranscriptBackfillRuntime.shared.read(for: source)?.token == token,
              let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID else {
            throw CancellationError()
        }

        // Rehydrate the chronological raw ledger as one sequence rather than
        // projecting an older page in isolation. A tool invocation/result or
        // ordered media directive can straddle the reverse-page seam; the
        // established hydrator is the only place allowed to reconstruct it.
        let rebuilt = Self.chatMessages(
            fromTranscript: .array(ledger.rows.map(\.raw)),
            toolsMayBeRunning: chat.isRunning,
            maximumRows: ledger.rows.count)
        let baseline = chat.messages
        let protectedIDs = ChatRuntime.shared.retainedFailureRows[lease.chatID] ?? []
        var merged = TranscriptHydrationMerge.merge(
            history: rebuilt, baseline: baseline, current: chat.messages,
            clearWhenEmpty: false, protectedIDs: protectedIDs)
        // The tail can advance through normal live events while an older page
        // is in flight. Preserve every current row whose durable id is absent
        // from our raw ledger; the generic hydration merge intentionally keeps
        // only the newest turn, while this exact-id pass keeps earlier live
        // turns without deduplicating repeated text.
        merged = retainRowsNotRepresentedByRawLedger(
            merged, current: chat.messages, rawRows: ledger.rows)
        chat.messages = merged
        if !protectedIDs.isEmpty {
            let visible = Set(chat.messages.map(\.id))
            ChatRuntime.shared.retainedFailureRows[lease.chatID] = protectedIDs.intersection(visible)
        }
        if let binding = chat.assistantResponseBinding,
           !chat.messages.contains(where: {
               $0.author == .user && $0.id == binding.sourceUserID
           }) {
            // Rehydration minted a new authoritative source row. Leaving a
            // shelf bound to the old local UUID would make an alternative act
            // on the wrong turn, so follow the canonical hydrator's rule.
            chat.clearAssistantResponseAlternatives()
        }

        TranscriptBackfillRuntime.shared.ledgers[source] = ledger
        chat.transcriptBackfill = TranscriptBackfillPresentation(
            source: source, rootStoredSessionID: ledger.rootStoredSessionID,
            resolvedSessionID: ledger.resolvedSessionID,
            status: ledger.status, nextOffset: ledger.nextOffset,
            prependGeneration: chat.transcriptBackfill.prependGeneration &+ 1)
        TranscriptBackfillRuntime.shared.finishRead(source: source, token: token)
        // An overlap-only page is still an accepted, cursor-advancing page.
        // Callers use this result to decide whether to retain a reader anchor,
        // not to infer that a text row necessarily became visible.
        return true
    }

    private func restoreTranscriptBackfillAfterCancellation(
        source: StoredTranscriptPageSource, token: UUID, lease: TranscriptBackfillLease
    ) async {
        guard TranscriptBackfillRuntime.shared.read(for: source)?.token == token,
              TranscriptBackfillRuntime.shared.lease(for: source)?.id == lease.id else { return }
        guard await transcriptBackfillLeaseIsCurrent(lease),
              let ledger = TranscriptBackfillRuntime.shared.ledgers[source],
              let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID,
              chat.transcriptBackfill.source == source
        else {
            TranscriptBackfillRuntime.shared.finishRead(source: source, token: token)
            return
        }
        chat.transcriptBackfill.status = ledger.status
        TranscriptBackfillRuntime.shared.finishRead(source: source, token: token)
    }

    private func failEarlierTranscriptRead(
        source: StoredTranscriptPageSource, token: UUID, lease: TranscriptBackfillLease
    ) async {
        guard TranscriptBackfillRuntime.shared.read(for: source)?.token == token,
              TranscriptBackfillRuntime.shared.lease(for: source)?.id == lease.id else { return }
        guard await transcriptBackfillLeaseIsCurrent(lease),
              let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID,
              chat.transcriptBackfill.source == source
        else {
            TranscriptBackfillRuntime.shared.finishRead(source: source, token: token)
            return
        }
        // Keep the exact bounded offset for an explicit retry, but never show
        // transport/protocol error text from an untrusted gateway.
        chat.transcriptBackfill.status = .failed
        TranscriptBackfillRuntime.shared.finishRead(source: source, token: token)
    }

    private func transcriptBackfillLeaseIsCurrent(_ lease: TranscriptBackfillLease) async -> Bool {
        await transcriptBackfillLeaseIsCurrent(
            botID: lease.botID, chatID: lease.chatID, chatIdentity: lease.chatIdentity,
            route: lease.route, source: lease.source,
            runtimeSessionID: lease.runtimeSessionID, authority: lease.authority)
    }

    private func transcriptBackfillLeaseIsCurrent(
        botID: String, chat: ChatState, route: GatewayBotRoute,
        source: StoredTranscriptPageSource, runtimeSessionID: String,
        authority: TranscriptHydrationSourceAuthority
    ) async -> Bool {
        await transcriptBackfillLeaseIsCurrent(
            botID: botID, chatID: ObjectIdentifier(chat), chatIdentity: chat.chatIdentity,
            route: route, source: source, runtimeSessionID: runtimeSessionID,
            authority: authority)
    }

    private func transcriptBackfillLeaseIsCurrent(
        botID: String, chatID: ObjectIdentifier, chatIdentity: UUID,
        route: GatewayBotRoute, source: StoredTranscriptPageSource,
        runtimeSessionID: String?, authority: TranscriptHydrationSourceAuthority
    ) async -> Bool {
        guard source.isUsable,
              source.gatewayID == route.gatewayID,
              source.profile == route.profile,
              await transcriptHydrationSourceIsCurrent(authority),
              let owner = chats[botID], ObjectIdentifier(owner) == chatID,
              owner.chatIdentity == chatIdentity,
              owner.sessionID == runtimeSessionID,
              owner.storedSessionID == source.storedSessionID,
              owner.transcriptBackfill.source.map({ $0 == source }) ?? true,
              gatewayRoute(for: botID) == route
        else { return false }
        return true
    }

    private func retainRowsNotRepresentedByRawLedger(
        _ merged: [ChatMessage], current: [ChatMessage], rawRows: [StoredTranscriptRow]
    ) -> [ChatMessage] {
        let rawRowIDs = Set(rawRows.compactMap(\.rowID))
        var result = merged
        var knownMessageIDs = Set(result.map(\.id))
        for message in current {
            guard !knownMessageIDs.contains(message.id) else { continue }
            // A matching durable row is represented by the raw hydrator even
            // if it minted a fresh local UUID. Only a missing row id or an id
            // the ledger did not retain is safe to append without a text/
            // timestamp guess.
            if let rowID = message.rowID, rawRowIDs.contains(rowID) { continue }
            result.append(message)
            knownMessageIDs.insert(message.id)
        }
        return result
    }
}
