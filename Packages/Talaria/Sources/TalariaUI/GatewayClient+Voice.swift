import Foundation
import TalariaKit

// The gateway's audio surface, as used by the phone.
//
// Desktop's voice loop is *client-side*: the GUI records, POSTs the clip to
// /api/audio/transcribe, submits the transcript as an ordinary prompt, and
// speaks the reply from /api/audio/speak. Talaria does the same from iOS. The
// WebSocket `voice.*` RPCs are deliberately NOT the transport here — they drive
// the microphone and speakers of the gateway HOST machine, which is the wrong
// pair of ears when the user is holding a phone.
//
// Verified upstream contract (hermes-agent-upstream):
//   POST /api/audio/transcribe {data_url, mime_type} [?profile=]
//        → {ok, transcript, provider}                (web_server.py:4974)
//        `data_url` must be `data:<audio/…>;base64,…`; 25 MB cap; a *successful*
//        empty transcript means "no speech detected" and the caller is expected
//        to re-listen rather than surface an error (web_server.py:4966-4975).
//   POST /api/audio/speak {text} [?profile=]
//        → {ok, data_url, mime_type, provider}       (web_server.py:5181)
//   voice.toggle {action:"status"}
//        → {enabled, record_key, tts, available, audio_available,
//           stt_available, details}                  (server.py:14862)
//   voice.tts {text} → speaks on the HOST            (server.py:15130)
//
// Both REST calls are profile-scoped exactly like desktop (hermes.ts:1894-1928):
// STT/TTS provider config and API keys resolve from the addressed profile, so a
// bot with its own ElevenLabs key sounds like itself.

/// Audio returned by POST /api/audio/speak, already decoded from its data URL.
public struct SpokenAudio: Sendable {
    public var data: Data
    public var mimeType: String
    public var provider: String?

    public init(data: Data, mimeType: String, provider: String?) {
        self.data = data; self.mimeType = mimeType; self.provider = provider
    }
}

/// Projection of `voice.toggle {action:"status"}`.
///
/// The distinction that matters for a phone: `speechToText` is a *server-side*
/// provider (Whisper/Groq/ElevenLabs/… reachable from the gateway) and is the
/// only flag transcription needs, while `hostAudio` reports whether the gateway
/// machine has a working sound device — irrelevant to us, since the microphone
/// is on this device. `available` is the AND of both and would wrongly hide
/// voice on a headless server, so it is kept for diagnostics only.
public struct VoiceCapabilities: Sendable, Equatable {
    /// Host-side voice *mode* (HERMES_VOICE), not an availability signal.
    public var hostVoiceEnabled: Bool
    /// Host speaks replies through its own speakers.
    public var hostTTSEnabled: Bool
    /// Gateway machine has a usable sound device (sounddevice/Termux).
    public var hostAudio: Bool
    /// A transcription provider is configured and reachable from the gateway.
    public var speechToText: Bool
    /// Upstream's own AND of host audio + STT + environment.
    public var hostVoiceUsable: Bool
    /// Human-readable provider matrix ("STT provider: MISSING …").
    public var details: String
    /// False until a gateway actually answered — an un-probed gateway must not
    /// be reported as "voice unavailable".
    public var probed: Bool

    public init(_ v: JSONValue?) {
        hostVoiceEnabled = v?["enabled"]?.boolValue ?? false
        hostTTSEnabled = v?["tts"]?.boolValue ?? false
        hostAudio = v?["audio_available"]?.boolValue ?? false
        speechToText = v?["stt_available"]?.boolValue ?? false
        hostVoiceUsable = v?["available"]?.boolValue ?? false
        details = v?["details"]?.stringValue ?? ""
        probed = true
    }

    private init() {
        hostVoiceEnabled = false; hostTTSEnabled = false; hostAudio = false
        speechToText = false; hostVoiceUsable = false; details = ""; probed = false
    }

    /// Nothing known yet (demo mode, or the probe has not returned).
    public static let unknown = VoiceCapabilities()

    /// Older gateways answer `voice.toggle status` without the requirements
    /// probe (it is wrapped in a try upstream). Treat a probed-but-silent
    /// gateway as capable and let the transcribe call be the real test —
    /// refusing to record on a missing hint would be worse than a clean error.
    public var canTranscribe: Bool {
        !probed || speechToText || details.isEmpty
    }
}

/// Profile-scoped transcription readiness from GET /api/config. The gateway's
/// `voice.toggle status` probe is process/default-profile scoped, while the
/// phone audio endpoint resolves the selected profile. Unknown remains distinct
/// from disabled so a failed config read never becomes a false green light.
public struct ProfileSTTReadiness: Sendable, Equatable {
    public var enabled: Bool
    public var provider: String
    public var probed: Bool

    public init(config: JSONValue) {
        let stt = config["stt"]
        // Hermes defaults stt.enabled to true. GET /api/config returns merged
        // config, but retain that upstream default for older gateways that omit
        // the leaf while still returning a valid stt section.
        enabled = stt?["enabled"]?.boolValue ?? true
        provider = stt?["provider"]?.stringValue ?? ""
        probed = true
    }

    private init() { enabled = false; provider = ""; probed = false }
    public static let unknown = ProfileSTTReadiness()
    public var canTranscribe: Bool { probed && enabled && !provider.isEmpty }
}

extension GatewayClient {

    /// Whole-response cap for the JSON data URL returned by Hermes. The
    /// decoded mobile audio ceiling below is smaller; this outer bound stops a
    /// hostile base64 body while it is still crossing the wire.
    static let maximumSpeechResponseBytes = 14_000_000
    static let maximumDecodedSpeechBytes = 10_000_000

    // MARK: - Capability probe

    /// Typed `voice.toggle {action:"status"}`. Never throws for a gateway that
    /// simply lacks the method — an unknown capability set degrades to
    /// "try it and see" rather than hiding the feature.
    public func voiceCapabilities() async -> VoiceCapabilities {
        do {
            return VoiceCapabilities(try await rpc("voice.toggle", ["action": "status"], timeout: 20))
        } catch {
            return .unknown
        }
    }

    /// Read the selected profile's actual STT gate. This intentionally does not
    /// borrow the process-wide voice.toggle status response.
    public func profileSTTReadiness(profile: String? = nil) async -> ProfileSTTReadiness {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query = [URLQueryItem(name: "profile", value: profile)]
        }
        guard let config = try? await restJSON(path: "api/config", query: query, timeout: 20)
        else { return .unknown }
        return ProfileSTTReadiness(config: config)
    }

    // MARK: - Speech → text

    /// POST /api/audio/transcribe. Returns the transcript, which is `""` when
    /// the provider heard no speech — a normal outcome the caller should treat
    /// as "re-listen", not as an error.
    public func transcribeAudio(dataURL: String, mimeType: String,
                                profile: String? = nil) async throws -> String {
        // Provider round-trips are slow and scale with clip length; desktop
        // budgets 180-600 s for the same call (hermes.ts:88-134).
        let payload = try await audioPOST(path: "api/audio/transcribe", profile: profile,
                                          body: ["data_url": .string(dataURL),
                                                 "mime_type": .string(mimeType)],
                                          timeout: 240)
        return payload["transcript"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Text → speech

    /// POST /api/audio/speak — whole-file synthesis, returned as a data URL.
    /// (The streaming sibling, /api/audio/speak-stream, is a WebSocket that
    /// emits raw int16 PCM frames, not a REST route; see notes.)
    public func synthesizeSpeech(text: String, profile: String? = nil) async throws -> SpokenAudio {
        let payload = try await boundedAudioPOST(
            path: "api/audio/speak", profile: profile,
            body: ["text": .string(text)], timeout: 240,
            maximumResponseBytes: Self.maximumSpeechResponseBytes)
        guard let dataURL = payload["data_url"]?.stringValue,
              let decoded = Self.decodeDataURL(
                dataURL, maximumDecodedBytes: Self.maximumDecodedSpeechBytes) else {
            throw GatewayError(code: -11, message: "speak returned no audio")
        }
        let declared = payload["mime_type"]?.stringValue
            .map(Self.canonicalAudioMIME)
        guard declared == nil || declared == decoded.mimeType else {
            throw GatewayError(code: -11, message: "speak returned inconsistent audio")
        }
        return SpokenAudio(data: decoded.data,
                           mimeType: declared ?? decoded.mimeType,
                           provider: payload["provider"]?.stringValue)
    }

    /// `voice.tts` — speaks on the gateway HOST's speakers. Kept for surface
    /// completeness (and for a gateway sitting next to the user, e.g. a desk
    /// machine); the phone's own playback path is `synthesizeSpeech`.
    public func speakOnHost(text: String) async throws {
        try await rpc("voice.tts", ["text": .string(text)], timeout: 30)
    }

    // MARK: - REST plumbing

    /// One authorized JSON POST against the audio routes.
    private func audioPOST(path: String, profile: String?, body: JSONValue,
                           timeout: TimeInterval) async throws -> JSONValue {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query = [URLQueryItem(name: "profile", value: profile)]
        }
        // Use the actor's shared REST transport so lifecycle admission is held
        // from immediately before dispatch through the complete provider wait.
        return try await restJSON(path: path, method: "POST", query: query,
                                  body: body, timeout: timeout)
    }

    /// Sensitive TTS responses are both bounded and redirect-free so an HTTP
    /// redirect can never replay the gateway credential to another origin.
    private func boundedAudioPOST(path: String, profile: String?, body: JSONValue,
                                  timeout: TimeInterval,
                                  maximumResponseBytes: Int) async throws -> JSONValue {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query = [URLQueryItem(name: "profile", value: profile)]
        }
        return try await restJSONBoundedNoRedirect(
            path: path, method: "POST", query: query, body: body,
            timeout: timeout, maximumResponseBytes: maximumResponseBytes)
    }

    /// Split `data:<mime>;base64,<payload>` into bytes + mime.
    static func decodeDataURL(_ dataURL: String,
                              maximumDecodedBytes: Int = maximumDecodedSpeechBytes)
        -> (data: Data, mimeType: String)? {
        guard maximumDecodedBytes > 0, dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let headerParts = header.split(separator: ";", omittingEmptySubsequences: false)
        guard headerParts.count == 2, headerParts[1].lowercased() == "base64" else { return nil }
        let mime = canonicalAudioMIME(String(headerParts[0]))
        guard allowedSpeechMIMEs.contains(mime) else { return nil }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        // Base64 expands by 4/3. Reject before allocating decoded bytes, then
        // validate the exact result as a second boundary.
        let maximumEncoded = ((maximumDecodedBytes + 2) / 3) * 4
        guard !encoded.isEmpty, encoded.utf8.count <= maximumEncoded,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty, data.count <= maximumDecodedBytes else { return nil }
        return (data, mime)
    }

    private static let allowedSpeechMIMEs: Set<String> = [
        "audio/aac", "audio/flac", "audio/m4a", "audio/mp4", "audio/mpeg",
        "audio/ogg", "audio/opus", "audio/wav", "audio/webm", "audio/x-m4a",
        "audio/x-wav",
    ]

    private static func canonicalAudioMIME(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}
