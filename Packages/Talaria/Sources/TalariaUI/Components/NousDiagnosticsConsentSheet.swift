import SwiftUI
import TalariaKit
import TalariaTheme

/// Static disclosure and presentation policy for the private Nous diagnostics
/// flow. Upload ownership remains in AppModel; displaying this sheet performs
/// no work and cannot start a request.
public enum NousDiagnosticsConsentPolicy {
    public static let controlHitTarget: CGFloat = 44
    public static let title = "Send private diagnostics?"
    public static let githubIssuesURL = URL(
        string: "https://github.com/NousResearch/hermes-agent/issues")!
    public static let portalHelpURL = URL(
        string: "https://portal.nousresearch.com/help")!
    public static let discordURL = URL(
        string: "https://discord.gg/NousResearch")!
    public static let disclosure = """
    Hermes will store this upload privately inside Nous. It includes the gateway host’s OS, software versions, provider, and which API keys are configured—never the key values. It also includes up to 512 KB each of the full agent.log, gateway.log, and desktop.log available on the gateway host. Those logs may contain conversation content, tool output, and file paths. Secrets are redacted.

    Nous staff and allowlisted Discord moderators can access the upload. It is automatically deleted after 14 days.
    """
    public static let mobileBoundary = """
    Talaria sends only the bounded error context for this failed turn. It does not upload log files from this iPhone or another local device. The backend bundle may still include desktop.log from the gateway host.
    """

    public static func failureMessage(_ failure: PrivateDiagnosticsShareFailure) -> String {
        switch failure {
        case .unsupported:
            return "This Hermes gateway does not support private Nous diagnostics uploads."
        case .rejected(let message), .connection(let message):
            return bounded(message)
        case .malformedResponse:
            return "The gateway returned a diagnostics receipt that could not be verified. No link was opened."
        }
    }

    public static func successReference(_ receipt: NousDiagnosticsShareReceipt) -> String {
        if let uploadID = receipt.uploadID, !uploadID.isEmpty {
            return "Upload ID: \(bounded(uploadID, maximumScalars: 256))"
        }
        if let host = receipt.viewURL?.host, !host.isEmpty {
            return "Private receipt: \(bounded(host, maximumScalars: 256))"
        }
        return "Private diagnostics uploaded."
    }

    public static func accessibilityStatus(for phase: PrivateDiagnosticsSharePhase) -> String {
        switch phase {
        case .consent: return "Review consent before uploading private diagnostics."
        case .uploading: return "Uploading private diagnostics to Nous."
        case .failure(let failure): return "Diagnostics upload failed. \(failureMessage(failure))"
        case .success(let receipt): return "Diagnostics upload complete. \(successReference(receipt))"
        }
    }

    public static func failureTitle(_ failure: PrivateDiagnosticsShareFailure) -> String {
        if case .unsupported = failure { return "Not supported" }
        return "Upload failed"
    }

    private static func bounded(_ source: String, maximumScalars: Int = 512) -> String {
        let maximumWorkScalars = max(maximumScalars, 2_048)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(maximumScalars)
        var inspected = 0
        var clipped = false
        for scalar in source.unicodeScalars {
            inspected += 1
            if inspected > maximumWorkScalars {
                clipped = true
                break
            }
            let value = scalar.value
            let unsafe = (value < 0x20 && value != 0x09 && value != 0x0A)
                || (0x7F...0x9F).contains(value)
                || bidiControls.contains(value)
            guard !unsafe else { continue }
            if output.count == maximumScalars {
                clipped = true
                break
            }
            output.append(scalar)
        }
        var result = String(output)
        if clipped { result += "…" }
        return result
    }

    private static let bidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
}

/// Consent and receipt presentation for the private Nous-internal upload.
/// The explicit upload closure is the only transition that may start network
/// work. Cancel always delegates invalidation to the controller first.
public struct NousDiagnosticsConsentSheet: View {
    private let state: PrivateDiagnosticsShareState
    private let theme: ThemePack
    private let upload: () -> Void
    private let cancel: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.talariaReducedMotion) private var reducedMotion
    @State private var copiedUploadID = false

    public init(state: PrivateDiagnosticsShareState, theme: ThemePack,
                upload: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.state = state
        self.theme = theme
        self.upload = upload
        self.cancel = cancel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(NousDiagnosticsConsentPolicy.title,
                           systemImage: "lock.shield.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .accessibilityAddTraits(.isHeader)

                    phaseContent
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.bg)
            .safeAreaInset(edge: .bottom) { actionBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelLabel, action: cancel)
                        .frame(minWidth: NousDiagnosticsConsentPolicy.controlHitTarget,
                               minHeight: NousDiagnosticsConsentPolicy.controlHitTarget)
                        .accessibilityHint(cancelHint)
                }
            }
        }
        .interactiveDismissDisabled(false)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(
            NousDiagnosticsConsentPolicy.accessibilityStatus(for: state.phase)))
    }

    private var cancelLabel: String {
        if case .consent = state.phase { return "Cancel" }
        return "Close"
    }

    private var cancelHint: String {
        switch state.phase {
        case .consent:
            return "Closes without starting an upload"
        case .uploading:
            return "Closes immediately. An upload already in progress may still finish on the server"
        case .failure, .success:
            return "Closes this sheet"
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch state.phase {
        case .consent:
            disclosure
        case .uploading:
            disclosure
            HStack(spacing: 12) {
                if reducedMotion {
                    Image(systemName: "arrow.up.circle")
                        .accessibilityHidden(true)
                } else {
                    ProgressView().accessibilityHidden(true)
                }
                Text("Uploading…")
                    .font(.headline)
                    .foregroundStyle(theme.ink)
            }
            .accessibilityElement(children: .combine)
        case .failure(let failure):
            disclosure
            statusCard(title: NousDiagnosticsConsentPolicy.failureTitle(failure),
                       message: NousDiagnosticsConsentPolicy.failureMessage(failure),
                       symbol: "exclamationmark.triangle.fill", color: theme.danger)
        case .success(let receipt):
            statusCard(title: "Diagnostics uploaded",
                       message: NousDiagnosticsConsentPolicy.successReference(receipt),
                       symbol: "checkmark.shield.fill", color: theme.ok)
            if let expires = receipt.expiresAt, !expires.isEmpty {
                Text("Automatic deletion: \(expires)")
                    .font(.footnote)
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Need more help?")
                .font(.headline)
                .foregroundStyle(theme.ink)
            supportLinks
        }
    }

    private var supportLinks: some View {
        VStack(alignment: .leading, spacing: 4) {
            supportButton("GitHub Issues", url: NousDiagnosticsConsentPolicy.githubIssuesURL)
            supportButton("Nous Portal Help", url: NousDiagnosticsConsentPolicy.portalHelpURL)
            supportButton("Nous Discord", url: NousDiagnosticsConsentPolicy.discordURL)
        }
    }

    private func supportButton(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .frame(minHeight: NousDiagnosticsConsentPolicy.controlHitTarget,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .accessibilityHint("Opens an external support page")
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NousDiagnosticsConsentPolicy.disclosure)
                .font(.body)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(NousDiagnosticsConsentPolicy.mobileBoundary)
                .font(.callout.weight(.semibold))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func statusCard(title: String, message: String,
                            symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actionBar: some View {
        VStack(spacing: 8) {
            switch state.phase {
            case .consent:
                primaryButton("Upload", symbol: "arrow.up.circle.fill", action: upload)
            case .uploading:
                EmptyView()
            case .failure:
                primaryButton("Try again", symbol: "arrow.clockwise", action: upload)
            case .success(let receipt):
                if let url = receipt.viewURL {
                    primaryButton("Open Link", symbol: "arrow.up.right.square") {
                        openURL(url)
                    }
                }
                if let uploadID = receipt.uploadID, !uploadID.isEmpty {
                    Button {
                        copyToPasteboard(uploadID)
                        copiedUploadID = true
                    } label: {
                        Label(copiedUploadID ? "Upload ID copied" : "Copy Upload ID",
                              systemImage: copiedUploadID ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity,
                                   minHeight: NousDiagnosticsConsentPolicy.controlHitTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(copiedUploadID ? "Upload ID copied" : "Copy upload ID")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func primaryButton(_ title: String, symbol: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity,
                       minHeight: NousDiagnosticsConsentPolicy.controlHitTarget)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
    }
}
