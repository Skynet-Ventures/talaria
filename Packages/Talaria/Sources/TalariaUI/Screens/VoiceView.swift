import SwiftUI
import TalariaKit
import TalariaTheme

// Voice — the full-screen overlay reached from the chat composer's mic.
// Two counter-rotating rings (solid + dashed; ink adds astrolabe crosshairs)
// around a breathing bot-avatar orb, a 12-bar waveform, the spoken line, and
// hush / write side buttons around the red end button.
// Ported from Talaria.dc.html `data-screen-label="Voice"`.
//
// Live mode runs a real conversation on this device: AVAudioRecorder captures
// until voice activity stops, the clip goes to POST /api/audio/transcribe, the
// transcript is submitted as an ordinary prompt, and the reply comes back from
// POST /api/audio/speak and plays through AVAudioPlayer — then it listens
// again. The waveform is the microphone (and, while the bot talks, the player's
// own meter), not a timer. Demo mode keeps the canned copy and the scripted
// animation and never touches the microphone.
//
// The gateway's own `voice.*` events still route through `attachVoiceRouter()`:
// they belong to a host-side listener, but a stop phrase or a barge-in spoken
// there must end this turn too.
//
// Liveness: this screen is the loudest place to lie about the link. Every other
// surface degrades to stale-but-readable; a voice overlay that keeps spinning
// its rings and holding the microphone open over a dead socket is asking the
// user to talk to nobody. So the conversation is gated on `AppModel.voiceLink`
// at every step — a drop releases the microphone and the speaker, freezes the
// stage where it stands, names the state in the theme's own voice, and the loop
// parks until the reconnect lands and picks the conversation back up.

public struct VoiceView: View {
    private let model: AppModel
    private let botID: String
    @Binding private var isPresented: Bool

    @State private var session = VoiceSession()

    public init(model: AppModel, botID: String, isPresented: Binding<Bool>) {
        self.model = model
        self.botID = botID
        self._isPresented = isPresented
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var bot: Bot? { model.bot(botID) }

    /// The 12 bars' full-cycle durations + stagger, lifted from the prototype.
    private static let waveDurations: [Double] = [0.9, 1.4, 0.7, 1.1, 1.6, 0.8,
                                                  1.2, 0.6, 1.5, 1.0, 1.3, 0.75]

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 40)
                ringStage
                    .padding(.top, 42)
                waveform
                    .padding(.top, 36)
                quote
                    .padding(.top, 28)
                    .padding(.horizontal, 44)
                Spacer(minLength: 12)
                if session.showsSpeakToggle { speakToggle.padding(.bottom, 18) }
                controls
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { session.begin(model: model, botID: botID) }
        .onDisappear {
            session.end(model: model)
        }
        // A stop phrase heard by a host-side listener ends the turn here too.
        .onChange(of: model.voice.stopPhrases) { _, _ in dismissToChat() }
        // Barge-in: the host says the user spoke over the reply — cut playback.
        .onChange(of: model.voice.interruptions) { _, _ in session.interrupt() }
        // The loop polls the link too, but it can be parked inside a wait the
        // recorder owns; this is what unblocks it the instant the socket goes.
        .onChange(of: model.voiceLink) { _, link in
            // The synchronous primary-link signal is relevant only to a bot
            // owned by that primary gateway. Foreign voice is watched by the
            // session's source-qualified pool monitor below.
            if model.profileRoute(for: botID)?.gatewayID == model.activeGatewayID {
                session.linkChanged(to: link)
            }
        }
    }

    // MARK: Background (the voiceBgCss token, derived from pack colors)

    @ViewBuilder
    private var background: some View {
        switch theme.id {
        case .soft:
            // linear 180deg: warm paper fading into lavender.
            theme.bg.overlay(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0),
                            .init(color: theme.accent.opacity(0.10), location: 0.55),
                            .init(color: theme.accent.opacity(0.20), location: 1)],
                    startPoint: .top, endPoint: .bottom))
        case .control:
            // radial phosphor bloom behind the orb (circle at 50% 38%).
            theme.bg.overlay(
                RadialGradient(colors: [theme.accent.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.5, y: 0.38),
                               startRadius: 0, endRadius: 320))
        case .ink:
            theme.bg
        }
    }

    // MARK: Header

    private var header: some View {
        Text(verbatim: "\(copy.voiceHead) \(TalariaVoice.plainUpper(for: model.identity(botID)))")
            .font(headFont)
            .tracking(theme.id == .soft ? 0 : 2.5)
            .foregroundStyle(headColor)
            .lineLimit(1)
    }

    private var headFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    private var headColor: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.5)
        case .control: theme.accent
        case .ink: theme.ink.opacity(0.55)
        }
    }

    // MARK: Ring stage — 234pt: rings, orb, crosshairs, avatar

    private var ringStage: some View {
        // Every moving part on this stage stops together on a state where
        // nothing more is going to happen — a socket that dropped, a refused
        // microphone, a gateway that cannot hear. Motion is the screen's only
        // claim that the conversation is alive, so it has to be earned.
        let still = !session.isLive
        return ZStack {
            // Outer solid ring, 9s clockwise; control tips it with a bright arc.
            ZStack {
                Circle().strokeBorder(theme.voiceRing1, lineWidth: 1)
                Circle()
                    .trim(from: 0.62, to: 0.88)
                    .stroke(theme.voiceRing1Top, lineWidth: 1)
                    .padding(0.5)
            }
            .frame(width: 234, height: 234)
            .modifier(Spinning(duration: 9, paused: still))

            // Inner dashed ring, 13s counter-clockwise.
            Circle()
                .strokeBorder(theme.voiceRing2, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                .frame(width: 194, height: 194)
                .modifier(Spinning(duration: 13, reverse: true, paused: still))

            // Breathing orb glow (soft/control; ink keeps the plate bare). Live
            // audio swells it past the idle breath so the orb reads as level.
            if let orbStops = theme.voiceOrb {
                Circle()
                    .fill(RadialGradient(colors: [orbStops.center, orbStops.edge],
                                         center: UnitPoint(x: 0.37, y: 0.31),
                                         startRadius: 0, endRadius: 105))
                    .frame(width: 150, height: 150)
                    .modifier(Breathing(paused: still))
                    .scaleEffect(1 + session.level * 0.16)
                    .animation(.easeOut(duration: 0.12), value: session.level)
            }

            // Ink's astrolabe crosshairs, over the rings, under the face.
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(width: 250, height: 1)
                Rectangle().fill(theme.line).frame(width: 1, height: 250)
            }

            AvatarView(shape: bot?.shape ?? .circle, hue: bot?.hue ?? .teal,
                       size: 90, isWorking: !still, theme: theme)
                .modifier(Breathing(paused: still))
        }
        .frame(width: 234, height: 234)
        .opacity(still ? 0.55 : 1)
        .animation(.easeOut(duration: 0.35), value: still)
        .contentShape(Circle())
        // Tapping the orb while the bot talks is the local barge-in.
        .onTapGesture { session.interrupt() }
        .accessibilityLabel(Text(session.stateLabel(copy, theme.id)))
    }

    // MARK: Waveform

    @ViewBuilder
    private var waveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            if session.showsMeteredWave {
                // Live mode: the rolling level history, oldest → newest.
                ForEach(Array(session.levels.enumerated()), id: \.offset) { index, level in
                    MeteredBar(color: theme.voiceWave,
                               glow: theme.voiceWaveGlow,
                               cornerRadius: theme.voiceBarRadius,
                               level: level * Self.barWeight(index))
                }
            } else {
                // Demo copy, and the "busy" phases where no audio is flowing.
                ForEach(Array(Self.waveDurations.enumerated()), id: \.offset) { index, duration in
                    WaveBar(color: theme.voiceWave,
                            glow: theme.voiceWaveGlow,
                            cornerRadius: theme.voiceBarRadius,
                            duration: duration,
                            delay: Double(index) * 0.09,
                            idle: !session.showsAnimatedWave || session.isMuted)
                }
            }
        }
        .frame(height: 33)
        .accessibilityHidden(true)
    }

    /// Taper the ends so a flat level still reads as a waveform, not a fence.
    private static func barWeight(_ index: Int) -> Double {
        let center = Double(AudioRecorder.barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        return 1 - distance * 0.35
    }

    // MARK: Quote

    private var quote: some View {
        Text(quoteText)
            .font(quoteFont)
            .italic(theme.id == .ink)
            .lineSpacing(theme.id == .control ? 4.5 : 4)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.id == .control ? theme.ink.opacity(0.9) : theme.ink)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: quoteText)
    }

    /// Demo: the canned themed quote. Live: what was just said or answered,
    /// falling back to the state line (and to a host-side voice.status when the
    /// gateway is driving its own listener).
    private var quoteText: String {
        if model.mode == .demo { return copy.voiceQuote }
        // A stopped conversation says why. The last thing spoken — and a
        // host-side "listening" from a desk machine that is still fine — would
        // both bury the one line the user needs.
        if !session.isLive { return session.stateLabel(copy, theme.id) }
        if let line = session.line, !line.isEmpty { return line }
        if let hostState = model.voice.hostState, let spoken = hostLine(hostState) { return spoken }
        return session.stateLabel(copy, theme.id)
    }

    /// A host-side listener's `voice.status` said in this pack's voice.
    ///
    /// Upstream emits exactly "listening" / "transcribing" / "idle"
    /// (hermes_cli/voice.py:456, 526, 569, 659 → `voice.status {state}`), so
    /// the two that mean something here are mapped and everything else falls
    /// through. Rendering the raw token would put a lowercase English word
    /// under the orb in a pack that speaks in small caps — or in none of the
    /// three voices at all.
    private func hostLine(_ state: String) -> String? {
        switch state {
        case "listening": copy.voiceListening(theme.id)
        case "transcribing": copy.voiceTranscribing(theme.id)
        default: nil
        }
    }

    private var quoteFont: Font {
        switch theme.id {
        case .soft: theme.body(16, weight: .medium)
        case .control: theme.body(15)
        case .ink: theme.body(18)
        }
    }

    // MARK: Auto-TTS toggle (desktop's voice.auto_tts)

    private var speakToggle: some View {
        Button {
            model.voice.autoSpeak.toggle()
            if !model.voice.autoSpeak { session.interrupt() }
        } label: {
            Text(model.voice.autoSpeak ? copy.voiceSpeakOn(theme.id) : copy.voiceSpeakOff(theme.id))
                .font(theme.id == .control ? theme.mono(9, weight: .bold) : theme.body(11, weight: .semibold))
                .tracking(theme.id == .soft ? 0 : 1)
                .foregroundStyle(model.voice.autoSpeak ? theme.accent : theme.ink.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 20 : 6, style: .continuous)
                        .strokeBorder(model.voice.autoSpeak
                                      ? theme.accent.opacity(0.5) : theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.voice.autoSpeak ? [.isSelected] : [])
    }

    // MARK: Controls — mute · end · text

    private var controls: some View {
        HStack(spacing: 15) {
            if session.showsMute {
                sideButton(copy.mute, active: session.isMuted) {
                    session.toggleMute()
                }
            }
            endButton
            sideButton(copy.textBtn) {
                dismissToChat()
            }
        }
    }

    private var endButton: some View {
        Button(action: dismissToChat) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.voiceEndGlyph)
                .frame(width: 19, height: 19)
                .frame(width: 63, height: 63)
                .background(theme.danger)
                .clipShape(RoundedRectangle(cornerRadius: theme.id == .control ? 12 : 31.5,
                                            style: .continuous))
                .shadow(color: theme.danger.opacity(theme.id == .control ? 0.45 : 0.38),
                        radius: theme.id == .control ? 13 : 11,
                        y: theme.id == .control ? 0 : 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copy.cancel))
    }

    private func sideButton(_ label: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(sideLabel(label))
                .font(sideFont)
                .tracking(theme.id == .control ? 1 : 0)
                .foregroundStyle(active ? theme.accent : sideColor)
                .frame(width: 52, height: 52)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(sideShape)
                .overlay(sideShape.strokeBorder(
                    active ? theme.accent.opacity(0.6) : sideBorder, lineWidth: 1))
                .contentShape(sideShape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// Ink renders its lowercase verbs in small caps via the font; soft and
    /// control ship their labels pre-cased in the copy pack.
    private func sideLabel(_ label: String) -> String { label }

    private var sideShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 10 : 26, style: .continuous)
    }

    private var sideFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .heavy)
        case .control: theme.mono(9, weight: .bold)
        case .ink: theme.body(12, weight: .bold).smallCaps()
        }
    }

    private var sideColor: Color {
        theme.ink.opacity(theme.id == .ink ? 0.6 : 0.55)
    }

    private var sideBorder: Color {
        switch theme.id {
        case .soft: theme.line
        case .control: theme.lineStrong.opacity(0.8)
        case .ink: theme.lineStrong
        }
    }

    // MARK: Routing

    private func dismissToChat() {
        session.end(model: model)
        isPresented = false
    }
}

// MARK: - The voice conversation

/// Drives one voice conversation: capability probe → mic permission → listen →
/// transcribe → prompt → speak → listen again, until the user ends it.
///
/// Every await is inside one cancellable task, so dismissing the overlay (or
/// muting) unwinds the loop at whatever step it reached; the recorder and the
/// player are torn down in `end()` rather than by each step.
@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case starting
        /// Demo mode: canned copy, scripted animation, no microphone.
        case demo
        case listening, transcribing, thinking, speaking, muted
        /// The socket dropped; the reconnect loop is dialing and the
        /// conversation is parked, not over.
        case linkLost
        /// The link needs the user before it can come back (sign-in expired,
        /// or the gateway was disconnected).
        case linkGone
        /// The user refused the microphone.
        case denied
        /// The gateway has no transcription provider.
        case unavailable
        /// No microphone on this platform (the macOS build).
        case unsupported
        /// The microphone would not start.
        case captureFailed(RecorderFailure?)
        /// The gateway refused a step of the loop; carries its own message.
        case gatewayFailed(String)
    }

    /// How one listen→answer turn ended.
    private enum TurnOutcome {
        /// Listen again.
        case next
        /// The socket went; park on the link and resume when it returns.
        case linkLost
        /// The conversation is over — `phase` already says why.
        case stop
    }

    private(set) var phase: Phase = .starting
    /// The rolling line under the orb: what you said, then what came back.
    private(set) var line: String?
    private(set) var isMuted = false

    let recorder = AudioRecorder()
    let player = VoicePlayer()

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var linkMonitor: Task<Void, Never>?
    @ObservationIgnored private var segment: CheckedContinuation<SegmentEnd?, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var voiceLease: UUID?
    @ObservationIgnored private var audioOwnership: MobileAudioOwnership.Lease?

    // MARK: Lifecycle

    func begin(model: AppModel, botID: String) {
        guard !started else { return }
        started = true
        line = nil
        isMuted = false

        guard model.mode == .live else {
            phase = .demo
            return
        }
        guard let audioOwnership = model.acquireVoiceAudioOwnership() else {
            phase = .gatewayFailed("Audio is already in use.")
            return
        }
        self.audioOwnership = audioOwnership
        model.voice.resetConversation()
        loop = Task { [weak self] in
            let lease = await model.acquireVoiceRouter(for: botID)
            guard !Task.isCancelled else {
                if let lease { model.releaseVoiceRouter(lease) }
                return
            }
            self?.voiceLease = lease
            await self?.run(model: model, botID: botID)
        }
        linkMonitor = Task { [weak self] in
            var previous = VoiceLinkState.up
            while !Task.isCancelled {
                let next = await model.voiceLink(for: botID)
                if next != previous { self?.linkChanged(to: next) }
                previous = next
                if next == .needsSignIn { break }
                // A foreign offline gateway may require a real pooled redial;
                // do not hammer DNS/auth every animation tick while it sleeps.
                try? await Task.sleep(for: next == .up ? .milliseconds(250) : .seconds(1))
            }
        }
    }

    func end(model: AppModel) {
        loop?.cancel()
        loop = nil
        linkMonitor?.cancel()
        linkMonitor = nil
        finishSegment(nil)
        recorder.cancel()
        player.stop()
        VoiceAudioSession.deactivate()
        if let voiceLease {
            model.releaseVoiceRouter(voiceLease)
            self.voiceLease = nil
        }
        if let audioOwnership {
            model.releaseVoiceAudioOwnership(audioOwnership)
            self.audioOwnership = nil
        }
        started = false
        phase = .starting
        line = nil
    }

    /// Barge-in / skip: stop the reply mid-sentence and go back to listening.
    func interrupt() {
        guard phase == .speaking else { return }
        player.stop()
    }

    /// The link changed under a running conversation.
    ///
    /// The loop checks `voiceLink` at every step of its own accord, but it can
    /// be parked inside the recorder's voice-activity wait — which only ends
    /// when somebody speaks. This is what releases the microphone the moment
    /// the socket does, and hands the loop back control so it can park.
    /// `isLive` is part of the guard: a screen that already reached a dead end
    /// — a refused microphone, a gateway with no scribe — keeps saying so. The
    /// loop has stopped, and overwriting that with "reconnecting" would replace
    /// a fixable problem with a misleading one.
    func linkChanged(to link: VoiceLinkState) {
        guard started, phase != .demo, isLive else { return }
        guard link != .up else { return }     // the loop's own gate resumes it
        releaseAudio()
        finishSegment(nil)
        // Said now rather than at the loop's next poll: the microphone is
        // already closed, and a quarter-second of a listening ring over a dead
        // socket is exactly the lie this screen exists to avoid.
        phase = link == .needsSignIn ? .linkGone : .linkLost
    }

    /// Hand the microphone, the speaker and the audio session back. Held
    /// hardware over a dead link is the failure this screen exists to avoid,
    /// and a `.playAndRecord` session left active keeps ducking everything else
    /// on the phone while we wait.
    private func releaseAudio() {
        recorder.cancel()
        player.stop()
        VoiceAudioSession.deactivate()
    }

    func toggleMute() {
        isMuted.toggle()
        // Demo has no microphone to mute — it only pins the waveform, as the
        // prototype did.
        guard phase != .demo else { return }
        if isMuted {
            // Mute stops *this device's* capture. It deliberately does not
            // touch `voice.toggle`, which would mute the gateway host instead.
            recorder.cancel()
            player.stop()
            finishSegment(nil)
            phase = .muted
        }
        // Unmuting is picked up by the loop, which returns to .listening.
    }

    // MARK: State for the view

    /// Current 0…1 level, from whichever side of the conversation is audible.
    var level: Double {
        switch phase {
        case .listening: recorder.level
        case .speaking: player.level
        default: 0
        }
    }

    var levels: [Double] {
        switch phase {
        case .listening: recorder.levels
        case .speaking: player.levels
        default: Array(repeating: 0, count: AudioRecorder.barCount)
        }
    }

    /// Metered bars while audio flows either way.
    var showsMeteredWave: Bool {
        phase == .listening || phase == .speaking
    }

    /// The scripted animation stands in for "busy but silent".
    var showsAnimatedWave: Bool {
        phase == .demo || phase == .starting || phase == .transcribing || phase == .thinking
    }

    /// Whether the screen may still claim to be alive: rings turning, orb
    /// breathing, avatar scanning. False on every state where the next thing
    /// that happens is the user's move, not the conversation's.
    var isLive: Bool {
        switch phase {
        case .linkLost, .linkGone, .denied, .unavailable, .unsupported,
             .captureFailed, .gatewayFailed: false
        default: true
        }
    }

    /// Nothing to mute once the conversation cannot run.
    var showsMute: Bool { isLive }

    var showsSpeakToggle: Bool {
        phase != .demo && isLive
    }

    func stateLabel(_ copy: CopyPack, _ theme: ThemeID) -> String {
        switch phase {
        case .starting: copy.voiceConnecting(theme)
        case .demo: copy.voiceQuote
        case .listening: copy.voiceListening(theme)
        case .transcribing: copy.voiceTranscribing(theme)
        case .thinking: copy.voiceThinking(theme)
        case .speaking: copy.voiceSpeaking(theme)
        case .muted: copy.voiceMuted(theme)
        case .linkLost: copy.voiceLinkLost(theme)
        case .linkGone: copy.voiceLinkGone(theme)
        case .denied: copy.voiceMicDenied(theme)
        case .unavailable: copy.voiceNoTranscription(theme)
        case .unsupported: copy.voiceNeedsPhone(theme)
        case .captureFailed(let failure):
            if case .engine(let detail)? = failure { detail } else { copy.voiceMicBusy(theme) }
        case .gatewayFailed(let message): message
        }
    }

    // MARK: The loop

    private func run(model: AppModel, botID: String) async {
        phase = .starting
        // Outer lap = one link. A reconnect re-enters it, so the probe and the
        // permission check are redone against the socket that will actually
        // carry the conversation.
        while !Task.isCancelled {
            guard await awaitLink(model, botID: botID) else { return }
            guard await prepare(model, botID: botID) else { return }

            var linkAlive = true
            while !Task.isCancelled, linkAlive {
                // Mute parks the loop here — but a link that drops while muted
                // is still a link that has to be waited out, so this releases
                // on either. The phase is re-asserted because a reconnect that
                // lands while muted comes back through `prepare`, which leaves
                // it on `.starting`.
                if isMuted { phase = .muted }
                while isMuted, !Task.isCancelled,
                      await model.voiceLink(for: botID) == .up {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard !Task.isCancelled else { return }
                guard await model.voiceLink(for: botID) == .up else { break }

                switch await listenAndAnswer(model: model, botID: botID) {
                case .next: continue
                case .linkLost: linkAlive = false
                case .stop: return
                }
            }
        }
    }

    /// Park until the gateway link is usable. Returns false when the
    /// conversation is over — cancelled, or the link cannot come back without
    /// the user.
    private func awaitLink(_ model: AppModel, botID: String) async -> Bool {
        guard await model.voiceLink(for: botID) != .up else { return true }
        // Whatever this device was holding, it is holding it for nothing now.
        releaseAudio()
        while !Task.isCancelled {
            switch await model.voiceLink(for: botID) {
            case .up: return true
            case .reconnecting: phase = .linkLost
            case .needsSignIn: phase = .linkGone; return false
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Capability probe + microphone, run once per link. Returns false only on
    /// a dead end the user has to resolve; a link that drops mid-probe returns
    /// true so the outer lap parks on it again instead of giving up.
    private func prepare(_ model: AppModel, botID: String) async -> Bool {
        phase = .starting
        // Probe first: a gateway with no STT provider can never hear us, and
        // asking for the microphone before saying so would be rude. Re-probed
        // per link because the answer belongs to the socket that gave it — and
        // the round trip doubles as proof the new socket really answers.
        let capabilities = await model.voiceCapabilities(for: botID)
        guard !Task.isCancelled else { return false }
        guard await model.voiceLink(for: botID) == .up else { return true }
        guard capabilities.canTranscribe else {
            phase = .unavailable
            return false
        }
        guard recorder.isSupported else {
            phase = .unsupported
            return false
        }
        guard await recorder.ensurePermission() == .granted else {
            phase = .denied
            return false
        }
        return true
    }

    /// One listen → transcribe → answer → speak turn.
    private func listenAndAnswer(model: AppModel, botID: String) async -> TurnOutcome {
        phase = .listening
        recorder.start()
        guard recorder.isRecording else {
            phase = .captureFailed(recorder.failure)
            return .stop
        }

        let ending = await awaitSegment()
        guard !Task.isCancelled else { return .stop }
        // The wait may have been cut short by the link itself (linkChanged).
        guard await model.voiceLink(for: botID) == .up else {
            recorder.cancel()
            return .linkLost
        }
        guard let ending else {
            recorder.cancel()
            return .next                      // muted or dismissed mid-listen
        }
        guard ending != .silence, let clip = recorder.stop() else {
            // Room tone only — drop it and listen again rather than burning a
            // provider call on silence.
            recorder.cancel()
            return .next
        }

        phase = .transcribing
        let heard: String
        do {
            heard = try await model.transcribe(clip, for: botID)
        } catch {
            // A failure whose real cause is the socket is recoverable and the
            // words are worth re-listening for; anything else is the gateway
            // refusing, and repeating it would only churn the provider.
            guard await model.voiceLink(for: botID) == .up else { return .linkLost }
            phase = .gatewayFailed(Self.reason(for: error))
            return .stop
        }
        guard !Task.isCancelled else { return .stop }
        // Upstream returns an empty transcript for "no speech detected".
        guard !heard.isEmpty else { return .next }

        line = heard
        phase = .thinking
        let reply = await model.submitVoicePrompt(heard, to: botID)
        guard !Task.isCancelled else { return .stop }
        // awaitReply gives up the moment the link does, so a nil reply here can
        // mean "socket went" as easily as "nothing came back".
        guard await model.voiceLink(for: botID) == .up else { return .linkLost }
        guard let reply, !reply.isEmpty else { return .next }
        line = reply

        if model.voice.autoSpeak, !isMuted {
            if let audio = await model.synthesizeReply(reply, for: botID) {
                guard !Task.isCancelled else { return .stop }
                guard await model.voiceLink(for: botID) == .up else { return .linkLost }
                phase = .speaking
                await player.play(audio)
            } else if await model.voiceLink(for: botID) != .up {
                return .linkLost
            } else if let failure = model.voice.speechFailure {
                // No TTS provider: say so once, keep the conversation going in
                // text — the transcript line still updates.
                model.voice.autoSpeak = false
                line = failure
            }
        }
        return Task.isCancelled ? .stop : .next
    }

    /// The sentence a failed hop should show. Gateway errors already carry a
    /// user-facing message; anything else falls back to the system's.
    private static func reason(for error: Error) -> String {
        (error as? GatewayError)?.message ?? error.localizedDescription
    }

    /// Await the recorder's voice-activity verdict; nil when the wait was cut
    /// short (mute, dismissal).
    private func awaitSegment() async -> SegmentEnd? {
        await withCheckedContinuation { (continuation: CheckedContinuation<SegmentEnd?, Never>) in
            segment = continuation
            recorder.onSegmentEnd = { [weak self] ending in
                self?.finishSegment(ending)
            }
        }
    }

    private func finishSegment(_ ending: SegmentEnd?) {
        guard let continuation = segment else { return }
        segment = nil
        recorder.onSegmentEnd = nil
        continuation.resume(returning: ending)
    }
}

// MARK: - Voice copy (three voices, same states)

/// The prototype's copy pack predates on-device voice, so the conversation
/// states carry their own strings — same three voices as everything else.
public extension CopyPack {
    func voiceConnecting(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Opening the mic…"
        case .control: "OPENING VOICE LINK…"
        case .ink: "the audience is being prepared…"
        }
    }

    func voiceListening(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Listening…"
        case .control: "LISTENING — SPEAK"
        case .ink: "it attends. speak."
        }
    }

    func voiceTranscribing(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Getting that down…"
        case .control: "TRANSCRIBING"
        case .ink: "your words are being set down…"
        }
    }

    func voiceThinking(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Thinking…"
        case .control: "WORKING"
        case .ink: "it considers…"
        }
    }

    func voiceSpeaking(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Speaking — tap the orb to cut in"
        case .control: "PLAYBACK — TAP ORB TO CUT"
        case .ink: "it answers — touch the orb to stay it"
        }
    }

    func voiceMuted(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Muted — tap MUTE to speak again"
        case .control: "MIC MUTED"
        case .ink: "hushed — touch hush again to speak"
        }
    }

    /// The socket dropped mid-conversation and something is dialing. Says the
    /// conversation is paused, not lost — because it isn't.
    func voiceLinkLost(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Lost the gateway — reconnecting. We'll pick this up."
        case .control: "LINK DOWN — REDIALING, HOLD"
        case .ink: "the line is broken. it is being redrawn — wait a moment."
        }
    }

    /// Offline with nobody dialing: the sign-in expired, or the gateway was
    /// disconnected. Names the one place the user can fix it.
    func voiceLinkGone(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "The gateway needs you to sign in again — open Connections."
        case .control: "LINK CLOSED — RE-AUTH IN CONNECTIONS"
        case .ink: "the compact has lapsed. renew it in Connections."
        }
    }

    func voiceMicDenied(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Microphone access is off. Turn it on in Settings › Talaria › Microphone."
        case .control: "MIC DENIED — ENABLE IN SETTINGS › TALARIA › MICROPHONE"
        case .ink: "the ear is stopped. grant it in Settings › Talaria › Microphone."
        }
    }

    func voiceNoTranscription(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "This gateway has no transcription provider, so it cannot hear you. Set one up in Hermes settings → Voice."
        case .control: "NO STT PROVIDER ON THIS GATEWAY — CONFIGURE HERMES VOICE"
        case .ink: "no scribe attends this gateway. appoint one in its voice settings."
        }
    }

    func voiceMicBusy(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Something else is using the microphone. Close it and try again."
        case .control: "MIC HELD BY ANOTHER APP"
        case .ink: "another hand holds the ear. release it and return."
        }
    }

    func voiceNeedsPhone(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Voice needs a device with a microphone."
        case .control: "NO CAPTURE DEVICE"
        case .ink: "this vessel has no ear"
        }
    }

    func voiceSpeakOn(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Replies spoken"
        case .control: "REPLIES SPOKEN"
        case .ink: "it speaks aloud"
        }
    }

    func voiceSpeakOff(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Replies silent"
        case .control: "REPLIES SILENT"
        case .ink: "it answers in silence"
        }
    }
}

// MARK: - Motion (ringU / breatheU / waveU keyframes)

/// Continuous rotation; `reverse` spins counter-clockwise, `paused` freezes the
/// ring exactly where it stands and resumes from there.
///
/// Driven off a timeline rather than a `repeatForever` animation precisely so
/// it *can* stop. A repeating implicit animation only ends when the property is
/// written again, which snaps the ring back to zero and reads as a glitch —
/// and the whole point of pausing here is that the screen has just told the
/// user something went wrong.
private struct Spinning: ViewModifier {
    let duration: Double
    var reverse: Bool = false
    var paused: Bool = false

    /// Where the sweep is measured from. Shifted forward on resume by exactly
    /// as long as the ring stood still, so it continues from the angle it
    /// froze at rather than jumping to wherever wall-clock time got to while
    /// the socket was down.
    @State private var anchor = Date()
    /// The instant the freeze began, while it lasts.
    @State private var pausedAt: Date?

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: paused)) { context in
            content.rotationEffect(.degrees(angle(at: context.date)))
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                pausedAt = Date()
            } else if let pausedAt {
                anchor += Date().timeIntervalSince(pausedAt)
                self.pausedAt = nil
            }
        }
    }

    /// Clamped at the pause instant. A paused schedule already stops handing
    /// out fresh dates, but the clamp makes the angle independent of whether
    /// this body or the `onChange` above runs first — either order draws the
    /// same frozen ring.
    private func angle(at date: Date) -> Double {
        let effective = pausedAt.map { min($0, date) } ?? date
        return (reverse ? -360 : 360) * effective.timeIntervalSince(anchor) / duration
    }
}

/// The 3.2s scale(1 → 1.07) breathing cycle shared by orb and face. `paused`
/// lets it settle back to rest: writing the same property under a finite
/// animation is what replaces a `repeatForever` one, and a scale easing to 1.0
/// is invisible where a rotation snapping to zero would not be.
private struct Breathing: ViewModifier {
    var paused: Bool = false
    @State private var swollen = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(swollen ? 1.07 : 1.0)
            .onAppear { inhale() }
            .onChange(of: paused) { _, isPaused in
                if isPaused {
                    withAnimation(.easeOut(duration: 0.45)) { swollen = false }
                } else {
                    inhale()
                }
            }
    }

    private func inhale() {
        guard !paused else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            swollen = true
        }
    }
}

/// One 4×29 waveform bar: scaleY .22 ↔ 1 on its own staggered clock; muting
/// pins every bar low. Used for demo copy and the silent "busy" phases.
private struct WaveBar: View {
    let color: Color
    let glow: Color?
    let cornerRadius: CGFloat
    let duration: Double
    let delay: Double
    let idle: Bool

    @State private var tall = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: 4, height: 29)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 4)
            .scaleEffect(y: (tall && !idle) ? 1 : 0.22, anchor: .center)
            .animation(.easeOut(duration: 0.2), value: idle)
            .onAppear {
                withAnimation(.easeInOut(duration: duration / 2)
                    .repeatForever(autoreverses: true)
                    .delay(delay)) {
                    tall = true
                }
            }
    }
}

/// The same bar, driven by a measured 0…1 level instead of a clock.
private struct MeteredBar: View {
    let color: Color
    let glow: Color?
    let cornerRadius: CGFloat
    let level: Double

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: 4, height: 29)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 4)
            .scaleEffect(y: max(0.22, min(1, 0.22 + level * 0.78)), anchor: .center)
            .animation(.easeOut(duration: 0.09), value: level)
    }
}

// MARK: - Voice tokens (ring1/ring1Top/ring2/orbFill/waveC/… derived per pack)

private extension ThemePack {
    /// Outer solid ring stroke.
    var voiceRing1: Color {
        switch id {
        case .soft: accent.opacity(0.35)
        case .control: accent.opacity(0.30)
        case .ink: ink.opacity(0.40)
        }
    }

    /// The brighter top arc of the outer ring (soft blends it away).
    var voiceRing1Top: Color {
        switch id {
        case .soft: accent.opacity(0.35)
        case .control: accent
        case .ink: ink
        }
    }

    /// Inner dashed ring stroke.
    var voiceRing2: Color {
        switch id {
        case .soft: accent.opacity(0.30)
        case .control: accent.opacity(0.25)
        case .ink: ink.opacity(0.35)
        }
    }

    /// Radial orb fill stops; nil = no orb (ink's bare astrolabe).
    var voiceOrb: (center: Color, edge: Color)? {
        switch id {
        case .soft: (color(for: .violet).opacity(0.50), accent.opacity(0.15))
        case .control: (accent.opacity(0.32), accent.opacity(0.04))
        case .ink: nil
        }
    }

    /// Waveform bar color (waveC).
    var voiceWave: Color {
        id == .ink ? ink : accent
    }

    /// Phosphor bloom behind the bars — control only (waveGlow).
    var voiceWaveGlow: Color? {
        id == .control ? accent.opacity(0.5) : nil
    }

    /// Bar end radius follows the theme's dot language (dotR).
    var voiceBarRadius: CGFloat {
        id == .control ? 1 : 2
    }

    /// The 19pt square inside the red end button (voiceEndGlyph).
    var voiceEndGlyph: Color {
        id == .soft ? panel : bg
    }
}
