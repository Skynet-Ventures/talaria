import Foundation
import TalariaKit

// Gateway primitives used by the mobile room coordinator.  A room member
// always runs in its own hidden, persistent Hermes session on the member's
// source gateway; this file deliberately knows nothing about AppModel or the
// active connection so callers cannot accidentally route a remote member
// through the primary client.

public struct RoomOutboundAttachment: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case image, pdf, file }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var data: Data

    public init(id: UUID = UUID(), kind: Kind, name: String, data: Data) {
        self.id = id
        self.kind = kind
        self.name = name
        self.data = data
    }
}

/// A source-local member session read. `messageCount` is the pre-submit
/// baseline retained with a durable attempt; `containsAttempt` is the exact
/// acceptance proof used after a transport-uncertain submit.
public struct RoomMemberSessionSnapshot: Sendable {
    public var runtimeID: String
    public var storedID: String
    public var messages: [JSONValue]
    public var running: Bool
    /// `session.resume` replays a clarify that was raised while the room's
    /// source socket was detached. It is raw because batch clarifies add
    /// per-question fields that the general chat model intentionally does not
    /// flatten.
    public var pendingClarify: JSONValue?
    /// The oldest unresolved approval replayed by `session.resume`. The room
    /// prompt model keeps its runtime SID separate because approval responses
    /// must target the current connection-local session id.
    public var pendingApproval: ApprovalRequest?

    public init(runtimeID: String, storedID: String, messages: [JSONValue], running: Bool,
                pendingClarify: JSONValue? = nil,
                pendingApproval: ApprovalRequest? = nil) {
        self.runtimeID = runtimeID
        self.storedID = storedID
        self.messages = messages
        self.running = running
        self.pendingClarify = pendingClarify
        self.pendingApproval = pendingApproval
    }

    init(liveSession: LiveSession) {
        self.init(runtimeID: liveSession.sessionID,
                  storedID: liveSession.storedSessionID,
                  messages: liveSession.messages,
                  running: liveSession.running || liveSession.hasInflightTurn,
                  pendingClarify: liveSession.pendingClarify,
                  pendingApproval: liveSession.pendingApproval)
    }

    public var messageCount: Int { messages.count }

    /// A valid replayed question or approval is a third state alongside idle
    /// and running: the hidden member is waiting specifically for the human.
    /// Invalid/missing request ids never hold a room driver open.
    public var awaitingUser: Bool {
        !runtimeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RoomPendingPrompt.isAwaitingUser(pendingClarify: pendingClarify,
                                                 pendingApproval: pendingApproval)
    }

    /// Normalize this snapshot into the runtime-only room prompt model. The
    /// caller supplies the durable attempt so a delayed poll cannot attach an
    /// old prompt to a newer thread/epoch/member turn.
    public func pendingPrompt(roomID: RoomID, route: GatewayBotRoute,
                              attempt: RoomAttempt) -> RoomPendingPrompt? {
        RoomPendingPrompt.normalize(roomID: roomID, route: route,
                                    attempt: attempt, snapshot: self)
    }

    public func pendingPrompt(roomID: RoomID, attempt: RoomAttempt) -> RoomPendingPrompt? {
        RoomPendingPrompt.normalize(roomID: roomID, attempt: attempt, snapshot: self)
    }

    public func containsAttempt(_ attemptID: UUID) -> Bool {
        let marker = GatewayClient.roomAttemptMarker(attemptID)
        return messages.contains { message in
            guard message["role"]?.stringValue == "user" else { return false }
            return GatewayClient.roomMessageText(message).contains(marker)
        }
    }

    /// Strong reconciliation: the marker belongs to a user row whose prompt
    /// prefix matches the exact body persisted with this attempt.
    public func containsAttempt(_ attempt: RoomAttempt) -> Bool {
        messages.contains { message in
            guard message["role"]?.stringValue == "user" else { return false }
            let text = GatewayClient.roomMessageText(message)
            guard text.hasPrefix(attempt.promptAnchor + "\n") else { return false }
            let body = String(text.dropFirst(attempt.promptAnchor.count + 1))
            guard body.hasPrefix(attempt.promptText) else { return false }
            return RoomAttempt.hash(String(body.prefix(attempt.promptText.count))) == attempt.promptHash
        }
    }

    public func newestAssistant(after baseline: Int) -> String? {
        guard messages.count > baseline else { return nil }
        for message in messages[baseline...].reversed()
        where message["role"]?.stringValue == "assistant" {
            let text = GatewayClient.roomMessageText(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }


    /// Assistant output causally following this exact anchored user row.
    public func assistantReply(for attempt: RoomAttempt) -> String? {
        guard let anchor = messages.firstIndex(where: { message in
            guard message["role"]?.stringValue == "user" else { return false }
            let text = GatewayClient.roomMessageText(message)
            return text.hasPrefix(attempt.promptAnchor + "\n")
                && text.dropFirst(attempt.promptAnchor.count + 1).hasPrefix(attempt.promptText)
        }), anchor + 1 < messages.count else { return nil }
        let start = anchor + 1
        let end = messages[start...].firstIndex(where: { $0["role"]?.stringValue == "user" })
            ?? messages.endIndex
        guard start < end else { return nil }
        for message in messages[start..<end].reversed()
        where message["role"]?.stringValue == "assistant" {
            let text = GatewayClient.roomMessageText(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}

public enum RoomPromptAcceptance: Sendable, Equatable {
    /// The submit RPC acknowledged, or a post-error resume found the exact
    /// attempt marker in this member's transcript.
    case accepted
    /// The transport failed and the exact marker was not yet observable.
    /// This is durable uncertainty, never permission to submit again.
    case uncertain(String)
    /// The source was already running unrelated work. No submit occurred.
    case busy
    /// Attachment staging or a pre-acceptance validation failed. No prompt
    /// was accepted; queued image/PDF state was detached.
    case rejected(String)
}

public struct RoomPromptSubmission: Sendable, Equatable {
    public var acceptance: RoomPromptAcceptance
    public var runtimeID: String
    public var storedID: String
    public var baseline: Int
    /// Queued image/PDF paths retained only while submit acceptance is
    /// uncertain. Definite rejection detaches before returning.
    public var stagedImagePaths: [String]

    public init(acceptance: RoomPromptAcceptance, runtimeID: String,
                storedID: String, baseline: Int, stagedImagePaths: [String] = []) {
        self.acceptance = acceptance
        self.runtimeID = runtimeID
        self.storedID = storedID
        self.baseline = baseline
        self.stagedImagePaths = stagedImagePaths
    }
}

enum RoomSessionResolver {
    /// Only Hermes' definitive durable-row absence (4007) permits moving to
    /// the next target or creating. Resolution order is durable id, immutable
    /// RoomID title, then the exact captured legacy name title (legacy records
    /// only). Transport/auth/lifecycle failures keep every remaining identity
    /// innocent and propagate to the caller.
    static func resolve<T>(storedID: String?, immutableTitle: String,
                           legacyTitle: String? = nil,
                           resume: (String) async throws -> T,
                           create: () async throws -> T) async throws -> T {
        var targets: [String] = []
        for target in [storedID, immutableTitle, legacyTitle] {
            guard let target, !target.isEmpty, !targets.contains(target) else { continue }
            targets.append(target)
        }
        for target in targets {
            do { return try await resume(target) }
            catch let error as GatewayError where error.code == GatewayError.storedSessionGone {
                continue
            }
        }
        return try await create()
    }
}

public extension GatewayClient {
    static func roomAttemptMarker(_ attemptID: UUID) -> String {
        RoomAttempt.anchor(for: RoomAttemptID(rawValue: attemptID))
    }

    static func roomMessageText(_ message: JSONValue) -> String {
        if let content = message["content"]?.stringValue { return content }
        if let text = message["text"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? []).compactMap { part in
            part.stringValue ?? part["text"]?.stringValue
        }.joined()
    }

    /// Resume by durable id first, then by the immutable RoomID title. A room
    /// decoded from the old name-title format gets one additional lookup by
    /// its captured (rename-stable) legacy name. Creation always uses RoomID,
    /// so a disbanded and same-name recreated room cannot adopt old sessions.
    func ensureRoomSession(roomID: RoomID, projectionRoomKey: String? = nil,
                           sessionTitleIdentityVersion: UInt8,
                           legacySessionTitleName: String?, profile: String,
                           storedID: String?) async throws -> RoomMemberSessionSnapshot {
        let sharedID = projectionRoomKey.flatMap { key -> String? in
            guard key.hasPrefix("id:"), key.count > 3 else { return nil }
            return String(key.dropFirst(3))
        }
        let immutableTitle = "Group: \(sharedID ?? roomID.description)"
        let legacyTitle: String?
        if sessionTitleIdentityVersion == RoomRecord.legacyNameSessionTitleVersion,
           let legacyName = legacySessionTitleName,
           !legacyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            legacyTitle = "Group: \(legacyName)"
        } else {
            legacyTitle = nil
        }
        let live = try await RoomSessionResolver.resolve(
            storedID: storedID, immutableTitle: immutableTitle, legacyTitle: legacyTitle,
            resume: { try await self.resumeSession($0, profile: profile) },
            create: {
                try await self.createSession(
                    profile: profile, title: immutableTitle, hidden: true,
                    runtimeContract: .roomPlumbing)
            })
        guard !live.sessionID.isEmpty, !live.storedSessionID.isEmpty else {
            throw GatewayError(code: -8, message: "Room session resolution returned no durable identity.")
        }
        return RoomMemberSessionSnapshot(liveSession: live)
    }

    func readRoomSession(storedID: String, profile: String) async throws -> RoomMemberSessionSnapshot {
        let resumed = try await resumeSession(storedID, profile: profile)
        guard !resumed.sessionID.isEmpty, !resumed.storedSessionID.isEmpty else {
            throw GatewayError(code: -8, message: "Room session read returned no durable identity.")
        }
        return RoomMemberSessionSnapshot(liveSession: resumed)
    }

    // MARK: - Hidden-room blocking prompts

    /// Send the exact approval response shape for a room-member prompt. The
    /// caller obtains this client from `routedClient(for: prompt.route)`;
    /// accepting an explicit runtime SID here keeps that source-qualified
    /// boundary visible instead of silently falling back to a foreground chat.
    @discardableResult
    func respondToRoomApproval(sessionID: String, requestID: String,
                               choice: ApprovalChoice) async throws -> Int {
        let params = try RoomPendingPrompt.approvalResponseParameters(
            sessionID: sessionID, requestID: requestID, choice: choice)
        let result = try await rpc("approval.respond", params, timeout: 30)
        return RoomPendingPromptResponse.resolvedCount(in: result)
    }

    /// `clarify.respond` is keyed by request id, not by session id. Batch
    /// calls add `question_id`; the ordinary clarify omits it entirely.
    func respondToRoomClarify(requestID: String, answer: String,
                              questionID: String? = nil) async throws {
        let params = try RoomPendingPrompt.clarifyResponseParameters(
            requestID: requestID, answer: answer, questionID: questionID)
        _ = try await rpc("clarify.respond", params, timeout: 30)
    }

    /// Multi-select answers are JSON-array strings, never comma-joined text.
    /// This preserves an individual choice label that itself contains commas.
    func respondToRoomClarify(requestID: String, selections: [String],
                              questionID: String? = nil) async throws {
        let params = try RoomPendingPrompt.clarifyResponseParameters(
            requestID: requestID,
            answer: RoomPendingPrompt.multiSelectAnswer(selections), questionID: questionID)
        _ = try await rpc("clarify.respond", params, timeout: 30)
    }

    /// Prompt-shaped convenience wrappers preserve the prompt's route in the
    /// caller's value flow and reject a kind mismatch before any wire call.
    @discardableResult
    func respondToRoomPrompt(_ prompt: RoomPendingPrompt,
                             choice: ApprovalChoice) async throws -> Int {
        let response = try prompt.approvalResponse(choice: choice)
        let result = try await rpc(response.method, response.params, timeout: 30)
        return RoomPendingPromptResponse.resolvedCount(in: result)
    }

    func respondToRoomPrompt(_ prompt: RoomPendingPrompt, answer: String,
                             questionID: String? = nil) async throws {
        let response = try prompt.clarifyResponse(answer: answer, questionID: questionID)
        _ = try await rpc(response.method, response.params, timeout: 30)
    }

    func respondToRoomPrompt(_ prompt: RoomPendingPrompt,
                             selections: [String],
                             questionID: String? = nil) async throws {
        let response = try prompt.clarifyResponse(selections: selections,
                                                  questionID: questionID)
        _ = try await rpc(response.method, response.params, timeout: 30)
    }

    func detachRoomStagedImages(_ paths: [String], sessionID: String) async {
        await detachRoomImages(paths, sessionID: sessionID)
    }

    /// Stage one responder's payload and submit exactly once. A caller must
    /// persist the attempt before entering this function. On a failed submit,
    /// queued images (including rendered PDF pages) are detached; file refs
    /// stay withheld because they are appended only to the submitted prompt.
    /// A transport error is reconciled against the exact marker and otherwise
    /// returned as uncertainty — it is never auto-retried.
    func submitRoomPrompt(
        attempt: RoomAttempt,
        session initial: RoomMemberSessionSnapshot,
        profile: String,
        attachments: [RoomOutboundAttachment]
    ) async -> RoomPromptSubmission {
        let baseline = initial.messageCount
        let baseResult = { (acceptance: RoomPromptAcceptance) in
            RoomPromptSubmission(acceptance: acceptance,
                                 runtimeID: initial.runtimeID,
                                 storedID: initial.storedID,
                                 baseline: baseline,
                                 stagedImagePaths: [])
        }

        // `prompt.submit` into a busy Hermes session redirects/interrupts
        // under some gateway policies. Rooms must never disturb that work.
        guard !initial.running else { return baseResult(.busy) }

        var queuedPaths: [String] = []
        var fileReferences: [String] = []
        do {
            for attachment in attachments {
                switch attachment.kind {
                case .image:
                    let staged = try await attachImageBytes(sessionID: initial.runtimeID,
                                                            data: attachment.data,
                                                            filename: attachment.name)
                    queuedPaths.append(contentsOf: staged.paths)
                case .pdf:
                    let staged = try await attachPDF(sessionID: initial.runtimeID,
                                                     data: attachment.data,
                                                     filename: attachment.name)
                    queuedPaths.append(contentsOf: staged.paths)
                case .file:
                    let staged = try await attachFile(sessionID: initial.runtimeID,
                                                      data: attachment.data,
                                                      filename: attachment.name)
                    if let ref = staged.refText, !ref.isEmpty {
                        fileReferences.append("\(attachment.name) → \(ref)")
                    }
                }
            }
        } catch {
            await detachRoomImages(queuedPaths, sessionID: initial.runtimeID)
            return baseResult(.rejected(error.localizedDescription))
        }

        let refs = fileReferences.isEmpty ? "" :
            "\n\nAttached files staged in your session workspace:\n" + fileReferences.joined(separator: "\n")
        let exactPrompt = attempt.promptAnchor + "\n" + attempt.promptText + refs

        do {
            // queued:true closes the resume→submit race without redirecting or
            // interrupting work that became busy after the preflight.
            try await submitPrompt(sessionID: initial.runtimeID, text: exactPrompt, queued: true)
            return RoomPromptSubmission(acceptance: .accepted,
                                        runtimeID: initial.runtimeID,
                                        storedID: initial.storedID,
                                        baseline: baseline,
                                        stagedImagePaths: [])
        } catch {
            // An error can happen after Hermes accepted the prompt but before
            // its acknowledgement reached the phone. Do one read-only exact
            // reconciliation. Never resubmit from this path.
            if let resumed = try? await readRoomSession(storedID: initial.storedID,
                                                        profile: profile),
               resumed.containsAttempt(attempt) {
                return RoomPromptSubmission(acceptance: .accepted,
                                            runtimeID: resumed.runtimeID,
                                            storedID: resumed.storedID,
                                            baseline: baseline,
                                            stagedImagePaths: [])
            }
            // Do not detach: Hermes may have accepted the prompt and not yet
            // persisted/returned. Paths ride the durable uncertain attempt.
            return RoomPromptSubmission(acceptance: .uncertain(error.localizedDescription),
                                        runtimeID: initial.runtimeID,
                                        storedID: initial.storedID,
                                        baseline: baseline,
                                        stagedImagePaths: queuedPaths)
        }
    }

    private func detachRoomImages(_ paths: [String], sessionID: String) async {
        for path in paths { _ = try? await detachImage(sessionID: sessionID, path: path) }
    }
}
