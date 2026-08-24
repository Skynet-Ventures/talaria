import Foundation

/// Small pure projection used by mobile transcript views. It preserves the
/// admitted part order while reusing Talaria's existing text, reasoning and
/// exact-authority tool models. Media/file references remain inert evidence.
public enum OrderedTranscriptRun: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case attachment(kind: TranscriptPart.Kind, ref: String?, mimeType: String?, clipped: Bool)
    case tools([ToolCall])
    case evidence(String)

}

public enum OrderedTranscriptPresentation {
    /// Keep established whole-message projections for envelopes whose order is
    /// already representable by the legacy reasoning-then-text layout, and for
    /// text transformed by generated-image or MEDIA suppression. This prevents
    /// an additive envelope from bypassing copy/find/media semantics.
    public static func shouldRenderOrdered(
        _ envelope: TranscriptPartsEnvelope,
        legacyText: String,
        projectedVisibleText: String
    ) -> Bool {
        let text = envelope.parts.compactMap { part in
            part.kind == .text ? part.text : nil
        }.joined()
        guard text == legacyText, projectedVisibleText == legacyText,
              AssistantMediaProjection.project(legacyText).references.isEmpty else {
            return false
        }
        var sawText = false
        for part in envelope.parts {
            switch part.kind {
            case .text: sawText = true
            case .reasoning where sawText: return true
            case .image, .audio, .file, .toolCall, .toolResult,
                 .unknown, .clipped, .malformed: return true
            case .reasoning: continue
            }
        }
        return false
    }

    public static func project(_ envelope: TranscriptPartsEnvelope,
                               toolCalls: [ToolCall]) -> [OrderedTranscriptRun] {
        var counts: [String: Int] = [:]
        for call in toolCalls {
            if let id = call.gatewayToolID, !id.isEmpty { counts[id, default: 0] += 1 }
        }
        let exact: [String: ToolCall] = Dictionary(
            uniqueKeysWithValues: toolCalls.compactMap { call -> (String, ToolCall)? in
            guard let id = call.gatewayToolID, counts[id] == 1 else { return nil }
            return (id, call)
        })
        var emittedToolIDs = Set<String>()
        var emittedCallIDs = Set<String>()
        var runs: [OrderedTranscriptRun] = []
        runs.reserveCapacity(envelope.parts.count)

        func appendText(_ text: String, reasoning: Bool) {
            guard !text.isEmpty else { return }
            if let last = runs.last {
                switch (last, reasoning) {
                case (.text(let prior), false): runs[runs.count - 1] = .text(prior + text); return
                case (.reasoning(let prior), true):
                    runs[runs.count - 1] = .reasoning(prior + text); return
                default: break
                }
            }
            runs.append(reasoning ? .reasoning(text) : .text(text))
        }

        for part in envelope.parts {
            switch part.kind {
            case .text:
                appendText(part.text ?? "", reasoning: false)
            case .reasoning:
                appendText(part.text ?? "", reasoning: true)
            case .image, .audio, .file:
                runs.append(.attachment(kind: part.kind, ref: part.ref,
                                        mimeType: part.mimeType, clipped: part.isClipped))
            case .toolCall, .toolResult:
                guard let id = part.id, let call = exact[id] else {
                    runs.append(.evidence(part.kind == .toolCall
                        ? "Unpaired tool invocation retained"
                        : "Unpaired tool result retained"))
                    continue
                }
                // The result enriches the invocation's existing ToolCall. It
                // never emits a second chip for the same exact execution id.
                guard emittedToolIDs.insert(id).inserted else { continue }
                emittedCallIDs.insert(call.id)
                runs.append(.tools([call]))
            case .clipped:
                runs.append(.evidence("Ordered transcript detail clipped"))
            case .malformed:
                runs.append(.evidence("Malformed ordered transcript detail retained"))
            case .unknown:
                let label = part.sourceKind?.isEmpty == false ? part.sourceKind! : "unknown"
                runs.append(.evidence("Unsupported transcript part: \(label)"))
            }
        }
        let remaining = toolCalls.filter { !emittedCallIDs.contains($0.id) }
        if !remaining.isEmpty { runs.append(.tools(remaining)) }
        return runs
    }
}

public enum OrderedTranscriptInteractionPolicy {
    /// Ordered attachment references are presentation evidence only. Existing
    /// generated-media cards keep their separate exact source authority.
    public static func allowsAttachmentInteraction(archived: Bool) -> Bool { false }

    public static func allowsToolInteraction(archived: Bool) -> Bool { !archived }
}
