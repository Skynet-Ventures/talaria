import SwiftUI
import TalariaKit
import TalariaTheme

// Onboarding — 4 paged steps with progress dots and Skip, ported from
// Talaria.dc.html `data-screen-label="Onboarding"`:
//   0  three bouncing avatars · Talaria / "Your agents, in your pocket."
//   1  gateway mode chips (Tailscale/LAN vs Hermes Cloud) + URL field
//   2  sign-in, driven by AuthController against the entered URL
//   3  found-bots avatar row · theme picker · notifications card · CTA
// Skip and "Explore with demo data" both enter demo mode and finish.

public struct OnboardingView: View {
    private let model: AppModel

    @State private var auth = AuthController()
    @State private var choseDemoData = false
    @State private var step = 0
    @State private var gatewayMode: GatewayModeChoice = .tailscale
    @State private var urlString = ""
    @State private var notifGranted = false
    /// Set once the sign-in finished and the gateway was registered.
    @State private var lostLink = false

    /// The demo tailnet address from the prototype (`state.obUrl`), used as
    /// the URL field's placeholder.
    static let placeholderURL = "http://100.84.12.9:9119"

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(step)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.ignoresSafeArea())
        .animation(.easeOut(duration: 0.3), value: step)
        .onChange(of: auth.phase) { _, phase in
            if phase == .done, step == 2 { advanceAfterAuth() }
        }
    }

    // MARK: - Top bar: progress dots + Skip

    private var topBar: some View {
        HStack {
            if step > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) { step -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
            }
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(step == i ? theme.accent : theme.line)
                        .frame(width: 16, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: step)
                }
            }
            Spacer()
            Button(action: skipOnboarding) {
                skipLabel
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }

    @ViewBuilder private var skipLabel: some View {
        switch theme.id {
        case .soft:
            Text(copy.obSkip)
                .font(theme.body(14, weight: .semibold))
                .foregroundStyle(theme.accent)
        case .control:
            Text(copy.obSkip)
                .font(theme.mono(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(theme.sub)
        case .ink:
            Text(copy.obSkip)
                .font(theme.body(14, weight: .semibold).smallCaps())
                .tracking(1)
                .foregroundStyle(theme.ink.opacity(0.55))
        }
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case 0: step0
        case 1: step1
        case 2: step2
        default: step3
        }
    }

    // MARK: - Step 0 · hero

    private var step0: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 10) {
                    BounceAvatar(shape: .squircle, hue: .amber, size: 44, delay: 0, theme: theme)
                    BounceAvatar(shape: .hexagon, hue: .violet, size: 60, delay: 0.3, theme: theme)
                    BounceAvatar(shape: .diamond, hue: .pink, size: 38, delay: 0.6, theme: theme)
                }
                .padding(.bottom, 26)

                // The prototype shows this kicker in every theme (no
                // kickerDisplay gate); the string is not part of CopyPack.
                Text(verbatim: "FOR HERMES AGENT")
                    .font(theme.mono(9.5, weight: .semibold))
                    .tracking(theme.id == .control ? 2.5 : 2)
                    .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                    .padding(.bottom, 8)

                titleText(copy.obTitle0)

                Text(copy.obSub0)
                    .font(apTitleFont)
                    .foregroundStyle(theme.ink)
                    .padding(.top, 6)

                Text(copy.obBody0)
                    .font(theme.body(theme.id == .ink ? 14.5 : (theme.id == .control ? 12.5 : 13)))
                    .foregroundStyle(theme.sub)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 290)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 36)
            Spacer()
            VStack(spacing: 9) {
                GatewayFlowButton(theme: theme, label: copy.obCta0, role: .primary) {
                    withAnimation(.easeOut(duration: 0.3)) { step = 1 }
                }
                GatewayFlowButton(theme: theme, label: copy.obAlt0, role: .secondary) {
                    enterDemoWorld()
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder private func titleText(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            Text(text).font(theme.body(31, weight: .heavy)).tracking(-0.6).foregroundStyle(theme.ink)
        case .control:
            Text(text).font(theme.body(27, weight: .heavy)).tracking(-0.4).foregroundStyle(theme.ink)
        case .ink:
            Text(text).font(theme.display(28).smallCaps()).tracking(0.5).foregroundStyle(theme.ink)
        }
    }

    private var apTitleFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .bold)
        case .control: theme.body(14, weight: .bold)
        case .ink: theme.body(17, weight: .bold)
        }
    }

    // MARK: - Step 1 · point at your gateway

    private var step1: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                subtitleText(copy.obTitle1)

                HStack(spacing: 7) {
                    ForEach(GatewayModeChoice.allCases, id: \.self) { mode in
                        GatewayModeChip(theme: theme, label: mode.label,
                                        isOn: gatewayMode == mode) {
                            withAnimation(.easeInOut(duration: 0.2)) { gatewayMode = mode }
                        }
                    }
                }

                // Both modes take a URL: tailscale/LAN gateways directly, and
                // Hermes Cloud agents via their dashboard URL (they are the
                // same gated gateway underneath; in-app discovery is future).
                TextField(gatewayMode == .tailscale ? Self.placeholderURL : copy.cloudURLPlaceholder,
                          text: $urlString)
                    .gatewayFieldTraits()
                    .modifier(GatewayFlowInputChrome(theme: theme))

                GatewayFootnote(theme: theme,
                                text: gatewayMode == .tailscale ? copy.obNote1 : copy.cloudURLHint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 34)

            Spacer()

            GatewayFlowButton(theme: theme, label: copy.obCta1, role: .primary) {
                continueFromStep1()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 40)
        }
    }

    private func continueFromStep1() {
        withAnimation(.easeOut(duration: 0.3)) { step = 2 }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Task { await auth.probe(trimmed) }
        } else {
            // Nothing to probe: step 2 offers only the explicit demo path.
            auth.reset()
        }
    }

    // MARK: - Step 2 · sign in

    private var step2: some View {
        VStack(alignment: .leading, spacing: 13) {
            subtitleText(copy.obTitle2)

            GatewayAuthPhasePanel(
                auth: auth, theme: theme, copy: copy,
                onRetry: {
                    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { await auth.probe(trimmed) }
                },
                onDemoSelect: {
                    // Explicit demo choice; finish() honors it after step 3.
                    choseDemoData = true
                    withAnimation(.easeOut(duration: 0.3)) { step = 3 }
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.top, 34)
    }

    private func advanceAfterAuth() {
        guard let base = auth.baseURL, let credential = auth.credential else { return }
        let kindHint: ConnectionKind? = gatewayMode == .cloud ? .cloud : nil
        let saved = ConnectionRegistry.shared.upsert(
            urlString: base.absoluteString, kind: kindHint, credential: credential)
        withAnimation(.easeOut(duration: 0.3)) { step = 3 }
        Task { @MainActor in
            do {
                try await model.runManagedCloudBootEpisode(
                    sourceURL: base,
                    gatewayID: saved?.id ?? "pending-gateway"
                ) {
                    try await model.connectGateway(baseURL: base, credential: credential)
                }
                ConnectionRegistry.shared.noteBotCount(model.bots.count, forURL: base)
                if let saved { await ConnectionRegistry.shared.probe(saved) }
                model.connections = ConnectionRegistry.shared.rows
            } catch {
                // The registry keeps the credentialed gateway for later; the
                // in-memory state stays demo-capable so step 3 is never empty.
                lostLink = true
            }
        }
    }

    // MARK: - Step 3 · roster preview, look, notifications

    /// Bots found on the gateway once live; the demo roster otherwise, exactly
    /// like the prototype's `obBots: bots.slice(0, 6)`.
    private var foundBots: [Bot] {
        let source = model.bots.isEmpty ? DemoData.bots : model.bots
        return Array(source.prefix(6))
    }

    private var step3: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    subtitleText(copy.obTitle3)

                    HStack(spacing: 9) {
                        ForEach(Array(foundBots.enumerated()), id: \.element.id) { index, bot in
                            AvatarView(shape: bot.shape, hue: bot.hue, size: 40, theme: theme)
                                .modifier(OnboardRowEntrance(delay: Double(index) * 0.07))
                        }
                    }

                    GatewaySectionLabel(theme: theme, text: copy.obLook)
                        .padding(.top, 2)

                    HStack(spacing: 8) {
                        ForEach(ThemeID.allCases, id: \.self) { id in
                            ThemeSwatchCard(id: id, current: theme, showsTagline: false) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    model.theme.themeID = id
                                }
                            }
                        }
                    }

                    notificationsCard

                    if lostLink {
                        Text(copy.offline)
                            .font(theme.id == .control ? theme.mono(9.5) : theme.body(theme.id == .ink ? 13 : 11.5))
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 30)
            }

            GatewayFlowButton(theme: theme, label: copy.obCta3, role: .primary) {
                finish()
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private var notificationsCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.obNotifT)
                    .font(prefNameFont)
                    .foregroundStyle(theme.ink)
                Text(copy.obNotifS)
                    .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GatewayFlowButton(theme: theme,
                              label: notifGranted ? copy.obAllowed : copy.obAllow,
                              role: notifGranted ? .secondary : .primary,
                              fullWidth: false) {
                allowNotifications()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 13)
        .modifier(GatewayCardChrome(theme: theme))
    }

    private var prefNameFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.body(13.5, weight: .semibold)
        case .ink: theme.body(16, weight: .semibold)
        }
    }

    private func allowNotifications() {
        guard !notifGranted else { return }
        Task { @MainActor in
            #if os(iOS)
            notifGranted = await PushCoordinator.shared.requestAuthorization()
            #else
            // macOS is a compile-check target; mirror the prototype's demo toggle.
            notifGranted = true
            #endif
        }
    }

    // MARK: - Finish

    /// Top-bar Skip: out of onboarding onto the real (possibly empty) roster.
    /// Demo data loads only when explicitly chosen.
    private func skipOnboarding() {
        auth.cancelSignIn()
        model.completeOnboarding()
    }

    /// The explicit "Explore with demo data" choice.
    private func enterDemoWorld() {
        auth.cancelSignIn()
        model.enterDemoMode()
        model.completeOnboarding()
    }

    private func finish() {
        // A live link keeps its roster; the demo world loads only if the user
        // explicitly picked it on the way through.
        if choseDemoData, model.client == nil {
            model.enterDemoMode()
        }
        model.completeOnboarding()
    }

    @ViewBuilder private func subtitleText(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            Text(text).font(theme.body(20, weight: .heavy)).tracking(-0.3).foregroundStyle(theme.ink)
        case .control:
            Text(text).font(theme.body(18, weight: .heavy)).foregroundStyle(theme.ink)
        case .ink:
            Text(text).font(theme.display(22, weight: .bold).smallCaps()).tracking(0.5).foregroundStyle(theme.ink)
        }
    }
}

// MARK: - Bouncing hero avatar (prototype `petU`)

private struct BounceAvatar: View {
    let shape: AvatarShape
    let hue: AvatarHue
    let size: CGFloat
    let delay: Double
    let theme: ThemePack

    @State private var up = false

    var body: some View {
        AvatarView(shape: shape, hue: hue, size: size, theme: theme)
            .offset(y: up ? -7 : 0)
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(delay),
                       value: up)
            .onAppear { up = true }
    }
}

// MARK: - Sign-in phase panel (shared with Connections' add-gateway sheet)

/// The AuthController-driven section of a sign-in screen. Renders whatever
/// the current phase needs: provider buttons for a gated gateway, the pasted
/// session-token path for an open one, progress while the system browser or
/// token exchange is in flight, and errors with a retry.
struct GatewayAuthPhasePanel: View {
    var auth: AuthController
    var theme: ThemePack
    var copy: CopyPack
    /// Re-runs the probe after a failure. nil hides the retry button.
    var onRetry: (() -> Void)?
    /// Without a probed gateway the panel shows the prototype's two static
    /// buttons; tapping either calls this (the demo path). nil hides them.
    var onDemoSelect: (() -> Void)?

    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            switch auth.phase {
            case .probing:
                progressRow(label: auth.baseURL?.host() ?? "")
            case .waitingForBrowser:
                waitingSection
            case .exchanging:
                progressRow(label: "")
            case .done:
                doneRow
            case .failed(let message):
                failedSection(message)
            case .idle:
                idleSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WebAuthPresenter(auth: auth, theme: theme))
    }

    // MARK: idle — the actionable states

    @ViewBuilder private var idleSection: some View {
        if auth.wantsSessionToken {
            sessionTokenSection
        } else if auth.isGated {
            providerSection
        } else if let onDemoSelect {
            // Nothing probed — be honest: there is no gateway to sign in to,
            // so the only real offer here is the demo world.
            GatewayFlowButton(theme: theme, label: copy.obAlt0, role: .primary) { onDemoSelect() }
            GatewayFootnote(theme: theme, text: copy.noGatewayNote)
        } else {
            GatewayFootnote(theme: theme, text: copy.obNote2)
        }
    }

    private var providerSection: some View {
        Group {
            ForEach(Array(auth.orderedProviders.enumerated()), id: \.element.name) { _, provider in
                GatewayFlowButton(theme: theme,
                                  label: providerLabel(provider),
                                  role: provider.supportsPassword ? .secondary : .primary) {
                    auth.signIn(provider: provider)
                }
            }
            GatewayFootnote(theme: theme, text: gatedNote)
        }
    }

    private func providerLabel(_ provider: AuthProviderInfo) -> String {
        if !provider.displayName.isEmpty { return provider.displayName }
        return provider.supportsPassword ? copy.obBasic : copy.obOauth
    }

    /// obNote2 plus the broker caveat: password providers ride the same
    /// system-browser flow (the gateway serves its /login form there).
    private var gatedNote: String {
        var note = copy.obNote2
        if auth.hasPasswordProvider {
            note += " Every sign-in opens your system browser — password providers use the gateway's own login page."
        }
        return note
    }

    private var sessionTokenSection: some View {
        Group {
            TextField("session token", text: $token)
                .gatewayFieldTraits()
                .modifier(GatewayFlowInputChrome(theme: theme))
            GatewayFlowButton(theme: theme, label: copy.obCta1, role: .primary) {
                Task { await auth.submitSessionToken(token) }
            }
            GatewayFootnote(theme: theme,
                            text: "Open gateway — paste the session token printed by hermes serve.")
        }
    }

    // MARK: transient / terminal states

    private func progressRow(label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.accent)
            if !label.isEmpty {
                Text(label)
                    .font(theme.id == .soft ? theme.body(13) : theme.mono(11))
                    .foregroundStyle(theme.sub)
            }
        }
        .padding(.vertical, 13)
    }

    private var waitingSection: some View {
        Group {
            progressRow(label: "Finish signing in with your browser…")
            GatewayFlowButton(theme: theme, label: copy.cancel, role: .secondary) {
                auth.cancelSignIn()
            }
        }
    }

    private var doneRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: "✓")
                .font(theme.body(15, weight: .heavy))
                .foregroundStyle(theme.ok)
            Text(auth.baseURL?.host() ?? "")
                .font(theme.id == .soft ? theme.body(13, weight: .semibold) : theme.mono(11, weight: .semibold))
                .foregroundStyle(theme.ok)
        }
        .padding(.vertical, 13)
    }

    private func failedSection(_ message: String) -> some View {
        Group {
            Text(message)
                .font(theme.id == .control ? theme.mono(10.5) : theme.body(theme.id == .ink ? 14 : 13))
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                GatewayFlowButton(theme: theme, label: "Try again", role: .secondary) {
                    onRetry()
                }
            }
        }
    }
}

// MARK: - Gateway mode (step 1 chips; also the add-gateway sheet)

enum GatewayModeChoice: CaseIterable {
    case tailscale, cloud

    /// Chip labels as in the prototype markup (not themed copy).
    var label: String {
        switch self {
        case .tailscale: "Tailscale / LAN"
        case .cloud: "Hermes Cloud"
        }
    }

    var kindHint: ConnectionKind? {
        self == .cloud ? .cloud : nil
    }
}

/// Selectable chip, prototype `chipSel(on)`.
struct GatewayModeChip: View {
    var theme: ThemePack
    var label: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background)
                .clipShape(shape)
                .overlay(shape.strokeBorder(border, lineWidth: theme.id == .soft ? 1.5 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var shape: some InsettableShape {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var radius: CGFloat {
        switch theme.id {
        case .soft: 999
        case .control: 5
        case .ink: 0
        }
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9.5)
        }
    }

    private var foreground: Color {
        switch theme.id {
        case .soft: isOn ? theme.accent : theme.ink.opacity(0.55)
        case .control: isOn ? theme.accent : theme.sub
        case .ink: isOn ? theme.bg : theme.ink.opacity(0.6)
        }
    }

    private var background: Color {
        switch theme.id {
        case .soft: isOn ? theme.accent.opacity(0.07) : .clear
        case .control: isOn ? theme.accent.opacity(0.06) : .clear
        case .ink: isOn ? theme.ink : .clear
        }
    }

    private var border: Color {
        switch theme.id {
        case .soft: isOn ? theme.accent : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.5) : theme.lineStrong.opacity(0.6)
        case .ink: isOn ? theme.ink : theme.ink.opacity(0.3)
        }
    }
}

// MARK: - Flow atoms shared by Onboarding and Connections

/// btnPriCss / btnSecCss — the full-width action buttons of the flow.
struct GatewayFlowButton: View {
    enum Role { case primary, secondary }

    var theme: ThemePack
    var label: String
    var role: Role
    var fullWidth: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            text
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.vertical, fullWidth ? 13 : 8)
                .padding(.horizontal, fullWidth ? 12 : 14)
                .background(background)
                .clipShape(shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .shadow(color: shadowColor, radius: shadowRadius, y: theme.id == .soft ? 4 : 0)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
    }

    @ViewBuilder private var text: some View {
        switch theme.id {
        case .soft:
            Text(label).font(theme.body(13.5, weight: .bold)).foregroundStyle(foreground)
        case .control:
            Text(label).font(theme.mono(11, weight: .bold)).tracking(1.5).foregroundStyle(foreground)
        case .ink:
            Text(label).font(theme.body(15, weight: .bold).smallCaps()).tracking(role == .primary ? 1.5 : 1)
                .foregroundStyle(foreground)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary:
            return theme.accentFg
        case .secondary:
            switch theme.id {
            case .soft: return theme.ink
            case .control: return theme.danger
            case .ink: return theme.accent
            }
        }
    }

    private var background: Color {
        switch role {
        case .primary:
            // Ink's primary is the ink-black plate, not the vermilion accent.
            return theme.id == .ink ? theme.ink : theme.accent
        case .secondary:
            return theme.id == .soft ? theme.ink.opacity(0.05) : .clear
        }
    }

    private var border: Color {
        guard role == .secondary else { return .clear }
        switch theme.id {
        case .soft: return .clear
        case .control: return theme.danger.opacity(0.4)
        case .ink: return theme.accent.opacity(0.6)
        }
    }

    private var shadowColor: Color {
        guard role == .primary else { return .clear }
        switch theme.id {
        case .soft: return theme.accent.opacity(0.28)
        case .control: return theme.accent.opacity(0.22)
        case .ink: return .clear
        }
    }

    private var shadowRadius: CGFloat {
        switch theme.id {
        case .soft: 10
        case .control: 16
        case .ink: 0
        }
    }
}

/// inputCss — the 44pt themed text field chrome.
struct GatewayFlowInputChrome: ViewModifier {
    var theme: ThemePack

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .padding(.horizontal, 15)
            .frame(height: 44)
            .background(theme.panel)
            .clipShape(shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(theme.inputRadius, 22), style: .continuous)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(14.5)
        case .control: theme.mono(13)
        case .ink: theme.body(15)
        }
    }

    private var border: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.09)
        case .control: theme.lineStrong.opacity(0.8)
        case .ink: theme.ink.opacity(0.4)
        }
    }
}

/// secLabelCss — uppercase section labels.
struct GatewaySectionLabel: View {
    var theme: ThemePack
    var text: String

    var body: some View {
        Text(text)
            .font(font)
            .tracking(theme.id == .soft ? 1 : 2)
            .textCase(.uppercase)
            .foregroundStyle(theme.id == .ink ? theme.sub : (theme.id == .control ? theme.faint : theme.ink.opacity(0.42)))
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .heavy)
        case .control: theme.mono(9, weight: .bold)
        case .ink: theme.mono(8.5)
        }
    }
}

/// footNoteCss — small explanatory notes.
struct GatewayFootnote: View {
    var theme: ThemePack
    var text: String

    var body: some View {
        Text(text)
            .font(font)
            .italic(theme.id == .ink)
            .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.55) : theme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }
}

/// cardCss — the standalone card chrome (notifications card).
struct GatewayCardChrome: ViewModifier {
    var theme: ThemePack

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        content
            .background(theme.panel)
            .clipShape(shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear, radius: 2, y: 1)
    }

    private var borderColor: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.06)
        case .control: theme.line
        case .ink: theme.lineStrong
        }
    }
}

/// One theme's swatch card for the pickers (onboarding step 3 without the
/// tagline, Connections → Appearance with it).
struct ThemeSwatchCard: View {
    var id: ThemeID
    /// The *currently applied* theme pack — drives the card's own chrome.
    var current: ThemePack
    var showsTagline: Bool
    var pick: () -> Void

    private var target: ThemePack { ThemePack.pack(for: id) }
    private var isOn: Bool { current.id == id }

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(target.bg)
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.gray.opacity(0.35), lineWidth: 1))
                    Circle()
                        .fill(target.accent)
                        .frame(width: 8, height: 8)
                }
                Text(id.displayName)
                    .font(nameFont)
                    .foregroundStyle(isOn ? current.accent : current.ink)
                    .padding(.top, 7)
                if showsTagline {
                    Text(id.tagline)
                        .font(current.id == .control ? current.mono(7.5) : current.body(current.id == .ink ? 10 : 9, weight: .medium))
                        .foregroundStyle(current.id == .ink ? current.ink.opacity(0.6) : current.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
            .background(isOn ? selectedFill : .clear)
            .clipShape(shape)
            .overlay(shape.strokeBorder(isOn ? current.accent : current.line,
                                        lineWidth: isOn ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(id.displayName))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: current.id == .ink ? 0 : 12, style: .continuous)
    }

    private var nameFont: Font {
        current.id == .ink
            ? current.body(15, weight: .bold).smallCaps()
            : current.body(12.5, weight: .bold)
    }

    private var selectedFill: Color {
        current.id == .control ? current.accent.opacity(0.05) : current.ink.opacity(0.05)
    }
}

// MARK: - Field traits + entrance

extension View {
    /// URL/token field affordances; the keyboard tweaks exist on iOS only.
    @ViewBuilder func gatewayFieldTraits() -> some View {
        #if os(iOS)
        self
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

private struct OnboardRowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.5).delay(delay)) { shown = true }
            }
    }
}
