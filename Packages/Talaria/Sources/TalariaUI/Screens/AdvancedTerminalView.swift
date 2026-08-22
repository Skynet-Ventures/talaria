import SwiftUI
import TalariaTheme

struct AdvancedTerminalView: View {
    let model: AppModel
    @Binding var sourceBinding: AdvancedTerminalSourceBinding
    @Environment(\.openURL) private var openURL
    private var coordinator: AdvancedTerminalCoordinator { .shared }
    private var workspace: WorkspaceRuntime { .shared }
    private var theme: ThemePack { model.theme.pack }

    var body: some View {
        VStack(spacing: 0) {
            header
            if coordinator.requiresResumeDecision {
                expiryChoice
            } else if coordinator.state == .idle, !coordinator.message.isEmpty {
                unavailable
            } else {
                GatewayTerminalView(
                    receivedChunks: coordinator.chunks,
                    theme: GatewayTerminalTheme(theme: theme),
                    onInput: coordinator.send,
                    onResize: coordinator.resize,
                    onOpenLink: { openURL($0) },
                    onConsume: coordinator.consume
                )
                .id(coordinator.rendererGeneration)
                if !coordinator.message.isEmpty { statusMessage }
            }
        }
        .background(theme.inset)
        .task(id: "\(workspace.gatewayID ?? "")|\(workspace.profile ?? "")|\(workspace.generation)|\(workspace.profiles.map(\.profile).joined(separator: "\u{1f}"))|\(sourceBinding.taskIdentity)") {
            guard let request = sourceBinding.request(
                workspaceGatewayID: workspace.gatewayID,
                workspaceProfile: workspace.profile,
                knownProfiles: workspace.profiles.map(\.profile)
            ) else {
                coordinator.waitForRequestedSource()
                return
            }
            coordinator.startFromWorkspace(request)
        }
        .onDisappear { coordinator.stop(clearTranscript: true) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced Terminal").font(.headline)
                Text("\(coordinator.gatewayName) · @\(coordinator.profile)")
                    .font(.caption.monospaced()).foregroundStyle(theme.sub)
            }
            Spacer()
            if showsConnectionActivity { ProgressView().controlSize(.small) }
            Button("New session") { coordinator.startNewSession(&sourceBinding) }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(theme.bg)
    }

    private var showsConnectionActivity: Bool {
        switch coordinator.state {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var expiryChoice: some View {
        ContentUnavailableView {
            Label("Detached session may have expired", systemImage: "terminal.fill")
        } description: {
            Text(coordinator.message)
        } actions: {
            Button("Try previous session") { coordinator.reattachAfterExpiry() }
            Button("Start new session") { coordinator.startNewSession(&sourceBinding) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var unavailable: some View {
        ContentUnavailableView("Terminal unavailable", systemImage: "terminal",
                               description: Text(coordinator.message))
            .padding()
    }

    private var statusMessage: some View {
        Text(coordinator.message)
            .font(.caption).foregroundStyle(theme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(theme.bg)
    }
}
