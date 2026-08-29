import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

// The model layer behind Settings (roadmap Phase 2).
//
// Desktop ships 202 discrete settings controls. The settled decision is that
// mobile does NOT port raw config/env editing — "an agent can be asked to make
// config changes, that doesn't need to live on device" — so what lives here is
// only what a phone-first operator reaches for:
//
//   * device preferences the app itself owns (text size, motion), persisted
//     next to the theme in UserDefaults;
//   * the diagnostics a support conversation actually needs — gateway version,
//     `desktop_contract`, auth mode, link state — captured from surfaces that
//     already exist rather than invented;
//   * a truthful inventory of what Talaria has written to this device, and the
//     three destructive verbs that undo it.
//
// Nothing here fabricates a list: the Keychain rows are probed, the preference
// rows come from `UserDefaults.dictionaryRepresentation()`, and the cache rows
// are measured. A gateway that cannot answer simply contributes nothing.

// MARK: - Device preferences

/// Appearance/accessibility preferences the app owns. `AppModel`'s stored
/// properties live in AppModel.swift (another owner) and extensions cannot add
/// storage, so these ride a MainActor observable singleton — the same shape
/// `LiveRuntime` and `ConnectionSupervisor` use.
@MainActor
@Observable
public final class TalariaSettingsStore {
    public static let shared = TalariaSettingsStore(defaults: .standard)

    private let defaults: UserDefaults

    /// Namespaced like every other Talaria default, so the privacy inventory
    /// and "delete local data" find them by prefix without a hardcoded list.
    public static let textSizeKey = "talaria.settings.text-size"
    public static let motionKey = "talaria.settings.motion"
    public static let transcriptDetailKey = "talaria.settings.transcript-detail"

    /// App-level Dynamic Type override. `.system` means "whatever iOS says",
    /// which is the default and the only setting most people should need.
    public enum TextSize: String, CaseIterable, Sendable, Identifiable {
        case system, small, medium, large, larger, largest

        public var id: String { rawValue }

        /// nil = inherit the environment (the system setting).
        public var dynamicTypeSize: DynamicTypeSize? {
            switch self {
            case .system: nil
            case .small: .small
            case .medium: .medium
            case .large: .large
            case .larger: .xLarge
            case .largest: .accessibility1
            }
        }
    }

    /// Reduce-motion, tri-state. `.system` honors the accessibility setting;
    /// the two overrides exist because a phone on a train and a phone on a desk
    /// are different rooms, and iOS only has one switch.
    public enum MotionPreference: String, CaseIterable, Sendable, Identifiable {
        case system, reduced, full
        public var id: String { rawValue }
    }

    public var textSize: TextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Self.textSizeKey) }
    }

    public var motion: MotionPreference {
        didSet { defaults.set(motion.rawValue, forKey: Self.motionKey) }
    }

    /// How much execution detail Talaria paints. The underlying transcript is
    /// never filtered or rewritten; this is a local, reversible view choice.
    public var transcriptDetail: TranscriptPresentationPolicy.Detail {
        didSet { defaults.set(transcriptDetail.rawValue, forKey: Self.transcriptDetailKey) }
    }

    /// One store per process: `AppModel.settings` hands out `shared`, and a
    /// second instance would drift from the one every view is reading.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        textSize = defaults.string(forKey: Self.textSizeKey)
            .flatMap(TextSize.init(rawValue:)) ?? .system
        motion = defaults.string(forKey: Self.motionKey)
            .flatMap(MotionPreference.init(rawValue:)) ?? .system
        transcriptDetail = defaults.string(forKey: Self.transcriptDetailKey)
            .flatMap(TranscriptPresentationPolicy.Detail.init(rawValue:)) ?? .quiet
    }

    /// Back to shipped defaults — used by "delete local data", which has just
    /// removed the keys underneath us.
    func resetToDefaults() {
        textSize = .system
        motion = .system
        transcriptDetail = .quiet
    }

    /// Whether motion should be damped, given what the system currently says.
    /// Views pass `@Environment(\.accessibilityReduceMotion)`.
    public func prefersReducedMotion(system: Bool) -> Bool {
        switch motion {
        case .system: system
        case .reduced: true
        case .full: false
        }
    }
}

// MARK: - Diagnostics side table

/// What About & diagnostics reports, gathered from surfaces that already exist:
/// the public `GET /api/status` probe and the `session.info` event.
@MainActor
final class SettingsRuntime {
    static let shared = SettingsRuntime()

    /// Last successful `/api/status` for the *live* gateway.
    var status: GatewayStatus?
    var statusCheckedAt: Date?
    var statusError: String?

    /// `desktop_contract` from the most recent `session.info`. There is no
    /// read-only RPC that reports it (tui_gateway/server.py:5593 and
    /// methods_session.py:156 both fold it into the session info payload), so
    /// it is captured as it flies past rather than asked for.
    var desktopContract: Int?
    var runtimeModel: String?
    var runtimeProfile: String?

    weak var attachedClient: GatewayClient?
    var handlerID: UUID?
    var routerTask: Task<Void, Never>?

    func reset() {
        status = nil
        statusCheckedAt = nil
        statusError = nil
        desktopContract = nil
        runtimeModel = nil
        runtimeProfile = nil
    }
}

// MARK: - On-device storage inventory

/// One measured thing Talaria has put on this device. Deliberately factual
/// rather than themed: these are the words a person repeats to support.
public struct StorageItem: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var detail: String
    /// nil when the size is genuinely unknowable rather than zero.
    public var bytes: Int64?

    public init(id: String, title: String, detail: String, bytes: Int64?) {
        self.id = id; self.title = title; self.detail = detail; self.bytes = bytes
    }
}

/// A measured group of storage items. `kind` picks the themed heading; the
/// contents are always enumerated, never assumed.
public struct StorageGroup: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case keychain, preferences, appData, caches }

    public var kind: Kind
    public var items: [StorageItem]

    public var id: String { kind.rawValue }
    public var bytes: Int64 { items.reduce(0) { $0 + ($1.bytes ?? 0) } }
    public var isEmpty: Bool { items.isEmpty }

    public init(kind: Kind, items: [StorageItem]) {
        self.kind = kind; self.items = items
    }
}

/// The whole picture, plus the moment it was taken.
public struct StorageInventory: Sendable, Equatable {
    public var groups: [StorageGroup]
    public var measuredAt: Date

    public init(groups: [StorageGroup] = [], measuredAt: Date = .distantPast) {
        self.groups = groups; self.measuredAt = measuredAt
    }

    public var isMeasured: Bool { measuredAt != .distantPast }
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }

    public func group(_ kind: StorageGroup.Kind) -> StorageGroup? {
        groups.first { $0.kind == kind }
    }
}

// MARK: - Model API

extension AppModel {

    /// Device preferences (text size, motion). Observable: reading from a view
    /// body subscribes to changes.
    public var settings: TalariaSettingsStore { TalariaSettingsStore.shared }

    // MARK: Navigation

    /// Ask whoever owns the screen graph to push Settings. Same shape as
    /// `requestCapabilities` — the roster header and Connections both need it
    /// and neither owns the presentation.
    public func requestSettings() {
        NotificationCenter.default.post(name: .talariaOpenSettings, object: nil)
    }

    // MARK: Diagnostics

    /// Gateway version / release date / component health for About, or nil
    /// before the first probe.
    public var gatewayStatus: GatewayStatus? { SettingsRuntime.shared.status }

    /// The backend contract the connected gateway speaks, once a session has
    /// reported one. nil is honest: it means nothing has said yet.
    public var gatewayDesktopContract: Int? { SettingsRuntime.shared.desktopContract }

    /// Diagnostics for the gateway the socket is actually bound to.
    public var liveGatewayDiagnostics: GatewayDiagnostics? {
        guard let base = LiveRuntime.shared.baseURL,
              let saved = ConnectionRegistry.shared.gateway(forURL: base) else { return nil }
        return diagnostics(forGatewayID: saved.id)
    }

    public var liveGateway: SavedGateway? {
        guard let base = LiveRuntime.shared.baseURL else { return nil }
        return ConnectionRegistry.shared.gateway(forURL: base)
    }

    /// Watch `session.info` so About can report `desktop_contract` without
    /// creating a session to ask. Idempotent per client, and detaches itself
    /// when the gateway is swapped.
    public func attachSettingsDiagnostics() {
        guard mode == .live, let client else { return }
        let runtime = SettingsRuntime.shared
        if runtime.routerTask != nil, runtime.attachedClient === client { return }
        detachSettingsDiagnostics()
        runtime.attachedClient = client
        let (stream, continuation) = AsyncStream.makeStream(
            of: GatewayEpochEventDelivery.self)
        runtime.routerTask = Task { @MainActor in
            for await delivery in stream {
                guard SettingsRuntime.shared.attachedClient === client,
                      await client.isCurrentReadyTransport(
                        epoch: delivery.transportEpoch),
                      case .sessionInfo(let info) = TypedGatewayEvent(delivery.event)
                else { continue }
                let settings = SettingsRuntime.shared
                if info.desktopContract > 0 { settings.desktopContract = info.desktopContract }
                if !info.model.isEmpty { settings.runtimeModel = info.model }
                if !info.profileName.isEmpty { settings.runtimeProfile = info.profileName }
            }
        }
        Task { @MainActor in
            let id = await client.addEpochEventHandler { event, transportEpoch in
                continuation.yield(GatewayEpochEventDelivery(
                    event: event, transportEpoch: transportEpoch))
            }
            // The link was replaced (or dropped) while the registration was in
            // flight. Without this the handler stays on the departed client for
            // the life of the process and `handlerID` names an attachment
            // `detachSettingsDiagnostics` can no longer reach.
            guard SettingsRuntime.shared.attachedClient === client else {
                await client.removeEventHandler(id)
                return
            }
            SettingsRuntime.shared.handlerID = id
        }
    }

    public func detachSettingsDiagnostics() {
        let runtime = SettingsRuntime.shared
        runtime.routerTask?.cancel()
        runtime.routerTask = nil
        if let id = runtime.handlerID, let target = runtime.attachedClient {
            Task { await target.removeEventHandler(id) }
        }
        runtime.handlerID = nil
        runtime.attachedClient = nil
        runtime.reset()
    }

    /// Re-read the live gateway's public status (ws-protocol.md §18 —
    /// `GET /api/status`, unauthenticated). Silent on failure: About shows the
    /// last good answer and the link state says the rest.
    public func refreshGatewayStatus() async {
        let runtime = SettingsRuntime.shared
        guard mode == .live, let base = LiveRuntime.shared.baseURL else {
            runtime.status = nil
            runtime.statusCheckedAt = nil
            return
        }
        do {
            let status = try await GatewayAuthClient(baseURL: base).status()
            runtime.status = status
            runtime.statusError = nil
            runtime.statusCheckedAt = Date()
        } catch {
            runtime.statusError = GatewayDiagnostics.shortMessage(for: error)
            runtime.statusCheckedAt = Date()
        }
    }

    /// The copyable support block. Plain, unthemed, one fact per line — this
    /// text gets pasted into an issue, not read aloud in the app's voice.
    public func diagnosticsSummary() -> String {
        let runtime = SettingsRuntime.shared
        var lines: [String] = []
        lines.append("Talaria \(Self.appVersionString)")
        lines.append("Platform: \(Self.platformString)")
        lines.append("Theme: \(theme.themeID.rawValue)")
        lines.append("Mode: \(mode == .live ? "live" : "demo")")

        if let gateway = liveGateway {
            lines.append("Gateway: \(ConnectionRegistry.address(for: gateway)) (\(gateway.kind.rawValue))")
            lines.append("Link: \(isOffline ? "offline" : "connected")")
        } else {
            lines.append("Gateway: none connected")
        }
        if let diagnostics = liveGatewayDiagnostics {
            if let version = diagnostics.version { lines.append("Gateway version: \(version)") }
            lines.append("Auth mode: \(diagnostics.authMode.rawValue)")
            if let ping = diagnostics.pingMS { lines.append("Ping: \(ping)ms") }
            if let error = diagnostics.lastError { lines.append("Last error: \(error)") }
        }
        if let status = runtime.status {
            lines.append("Gateway health: \(status.overall)")
            if !status.authFlows.isEmpty {
                lines.append("Auth flows: \(status.authFlows.joined(separator: ","))")
            }
            if let released = status.raw?["release_date"]?.stringValue, !released.isEmpty {
                lines.append("Gateway released: \(released)")
            }
            lines.append("Active agents: \(status.activeAgents)")
        }
        lines.append("desktop_contract: \(runtime.desktopContract.map(String.init) ?? "not reported")")
        if let model = runtime.runtimeModel { lines.append("Session model: \(model)") }
        lines.append("Saved gateways: \(ConnectionRegistry.shared.saved.count)")
        lines.append("Bots: \(bots.count) · routines: \(routines.count) · pending approvals: \(pendingApprovalCount())")
        if let reauth = needsReauth { lines.append("Needs re-auth: \(reauth.host() ?? reauth.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    /// "1.4.0 (218)" from the host app's Info.plist; "—" when there is no app
    /// bundle (unit tests, `swift build`).
    public static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "build \(build)"
        default: return "—"
        }
    }

    static var platformString: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if os(iOS)
        return "iOS \(version)"
        #elseif os(macOS)
        return "macOS \(version)"
        #else
        return version
        #endif
    }

    // MARK: Storage inventory

    /// Everything Talaria has put on this device, measured. Three groups:
    ///
    /// * **Keychain** — one probe per saved gateway plus the Portal token, so
    ///   a row only appears when a credential really is there.
    /// * **Preferences** — whatever `UserDefaults` actually holds under the
    ///   `talaria` namespace. Enumerated, not listed: a key added by a file
    ///   this one does not own still shows up.
    /// * **Caches** — the app's Caches and temporary directories walked on
    ///   disk, the shared URLCache, and the in-memory sprite atlases (a decoded
    ///   1536×1872 sheet is ~11 MB, which is worth showing a person).
    public func localStorageInventory() async -> StorageInventory {
        let saved = ConnectionRegistry.shared.saved
        let keychain = KeychainStore()
        var credentials: [StorageItem] = []
        for gateway in saved {
            guard let base = gateway.baseURL, let credential = keychain.load(for: base) else { continue }
            let kind: String
            var detail = ConnectionRegistry.address(for: gateway)
            switch credential {
            case .sessionToken:
                kind = "session token"
            case .oauth(let tokens):
                kind = "OAuth tokens · \(tokens.provider)"
                detail += " · expires \(Self.storageDate(tokens.expiresAt))"
            }
            credentials.append(StorageItem(id: "keychain.gateway.\(gateway.id)",
                                           title: "\(gateway.name) — \(kind)",
                                           detail: detail,
                                           bytes: nil))
        }
        let portalURL = PortalDirectoryAPI.resolvedPortalURL
        if let tokens = NousPortalTokenStore().load(portalURL: portalURL) {
            credentials.append(StorageItem(
                id: "keychain.portal",
                title: "Nous Portal — OAuth tokens",
                detail: "\(portalURL.host() ?? portalURL.absoluteString) · expires \(Self.storageDate(tokens.expiresAt))",
                bytes: nil))
        }

        var preferences: [StorageItem] = []
        for (key, value) in Self.talariaDefaults() {
            preferences.append(StorageItem(id: "defaults.\(key)",
                                           title: key,
                                           detail: Self.describe(defaultsValue: value),
                                           bytes: Self.plistBytes(value)))
        }
        preferences.sort { $0.title < $1.title }

        var caches = await Self.diskCacheItems()
        caches.append(contentsOf: spriteCacheItems())

        var appData: [StorageItem] = []
        if let usage = try? await RoomStore.shared.storageUsage(), usage.totalBytes > 0 {
            appData.append(StorageItem(
                id: "appdata.rooms",
                title: "Room transcripts and attachments",
                detail: "Protected on this device",
                bytes: usage.totalBytes))
        }

        return StorageInventory(
            groups: [
                StorageGroup(kind: .keychain, items: credentials),
                StorageGroup(kind: .preferences, items: preferences),
                StorageGroup(kind: .appData, items: appData),
                StorageGroup(kind: .caches, items: caches),
            ].filter { !$0.isEmpty },
            measuredAt: Date())
    }

    /// In-memory pet atlases, counted once per distinct revision — the same
    /// decoded sheet is shared by every sprite view drawing that pet, so
    /// counting per profile would multiply 11 MB by the roster.
    private func spriteCacheItems() -> [StorageItem] {
        var sheetBytes: [String: Int64] = [:]
        var thumbnailBytes: Int64 = 0
        var thumbnailCount = 0
        for state in PetRuntime.shared.states.values {
            for sheet in [state.sheet, state.hatchedSheet].compactMap({ $0 }) {
                // The atlas is baked into a premultiplied RGBA bitmap at init
                // (PetModels.swift `bake`), so 4 bytes per pixel is the real
                // resident cost, not an estimate of the PNG.
                let width = Int64(sheet.columns * sheet.geometry.frameWidth)
                let height = Int64(sheet.rows * sheet.geometry.frameHeight)
                sheetBytes[sheet.revision] = width * height * 4
            }
            for data in state.thumbnails.values {
                thumbnailBytes += Int64(data.count)
                thumbnailCount += 1
            }
        }
        var items: [StorageItem] = []
        if !sheetBytes.isEmpty {
            items.append(StorageItem(
                id: "cache.pet-sheets",
                title: "Pet spritesheets (in memory)",
                detail: "\(sheetBytes.count) decoded atlas\(sheetBytes.count == 1 ? "" : "es")",
                bytes: sheetBytes.values.reduce(0, +)))
        }
        if thumbnailCount > 0 {
            items.append(StorageItem(id: "cache.pet-thumbs",
                                     title: "Pet thumbnails (in memory)",
                                     detail: "\(thumbnailCount) images",
                                     bytes: thumbnailBytes))
        }
        return items
    }

    /// Disk-resident caches. The walk happens off the main actor: a Caches
    /// directory with a few thousand URLCache blobs is not a main-thread job.
    private static func diskCacheItems() async -> [StorageItem] {
        let urlCacheDisk = Int64(URLCache.shared.currentDiskUsage)
        let urlCacheMemory = Int64(URLCache.shared.currentMemoryUsage)
        let measured = await Task.detached(priority: .utility) { () -> [(String, String, Int64)] in
            var rows: [(String, String, Int64)] = []
            let manager = FileManager.default
            if let caches = try? manager.url(for: .cachesDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false) {
                let bytes = AppModel.directorySize(caches)
                if bytes > 0 { rows.append(("cache.dir", "Caches directory", bytes)) }
            }
            let temporary = manager.temporaryDirectory
            let temporaryBytes = AppModel.directorySize(temporary, prefix: AppModel.talariaTempPrefix)
            if temporaryBytes > 0 {
                rows.append(("cache.temp", "Temporary files", temporaryBytes))
            }
            return rows
        }.value

        var items: [StorageItem] = measured.map {
            StorageItem(id: $0.0, title: $0.1,
                        detail: $0.0 == "cache.temp" ? "voice clips and staged attachments"
                                                     : "downloaded responses and images",
                        bytes: $0.2)
        }
        if urlCacheDisk + urlCacheMemory > 0 {
            items.append(StorageItem(id: "cache.urlcache",
                                     title: "Network cache",
                                     detail: "\(formattedBytes(urlCacheMemory)) in memory",
                                     bytes: urlCacheDisk))
        }
        return items
    }

    /// Voice clips are written as `talaria-voice-<uuid>.m4a` into the system
    /// temporary directory (Components/AudioRecorder.swift); measuring and
    /// clearing both stay inside that prefix so nothing belonging to another
    /// framework is touched.
    nonisolated static let talariaTempPrefix = "talaria-"

    nonisolated static func directorySize(_ url: URL, prefix: String? = nil) -> Int64 {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: url,
                                              includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                                           .fileSizeKey],
                                              options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let prefix, !file.lastPathComponent.hasPrefix(prefix) { continue }
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Every UserDefaults entry the app owns. Prefix-matched rather than
    /// enumerated from a list of constants, because the constants live in files
    /// this one does not own — a new preference elsewhere must still be visible
    /// here and removable by "delete local data".
    static func talariaDefaults() -> [(String, Any)] {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.lowercased().hasPrefix("talaria") }
            .map { ($0.key, $0.value) }
    }

    static func describe(defaultsValue value: Any) -> String {
        switch value {
        case let data as Data:
            return "\(formattedBytes(Int64(data.count))) of encoded data"
        case let string as String:
            return string
        case let number as NSNumber:
            // UserDefaults hands booleans back as NSNumber; only the CF type id
            // separates `true` from `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "on" : "off" }
            return number.stringValue
        case let array as [Any]:
            return "\(array.count) entries"
        default:
            return String(describing: type(of: value))
        }
    }

    static func plistBytes(_ value: Any) -> Int64? {
        if let data = value as? Data { return Int64(data.count) }
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
              let encoded = try? PropertyListSerialization.data(fromPropertyList: value,
                                                                format: .binary, options: 0)
        else { return nil }
        return Int64(encoded.count)
    }

    /// Credential expiries, in the device's own date format.
    static func storageDate(_ unixSeconds: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: unixSeconds))
    }

    /// Byte counts in the app's own words — `ByteCountFormatter` so the units
    /// follow the device locale.
    nonisolated static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    // MARK: Destructive verbs

    /// Drop every cache we can drop and report what that freed. Nothing here
    /// touches credentials or preferences: caches are, by definition, things
    /// the app can rebuild from the gateway.
    @discardableResult
    public func clearLocalCaches() async -> Int64 {
        let before = await localStorageInventory().group(.caches)?.bytes ?? 0

        URLCache.shared.removeAllCachedResponses()
        // ~11 MB of atlases and every cached face belong to the gateway that
        // served them; both re-fetch on the next appearance.
        PetRuntime.shared.reset()
        ProfileAssetStore.shared.flush()

        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            if let caches = try? manager.url(for: .cachesDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false),
               let entries = try? manager.contentsOfDirectory(at: caches,
                                                              includingPropertiesForKeys: nil) {
                for entry in entries { try? manager.removeItem(at: entry) }
            }
            let temporary = manager.temporaryDirectory
            if let entries = try? manager.contentsOfDirectory(at: temporary,
                                                              includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent.hasPrefix(AppModel.talariaTempPrefix) {
                    try? manager.removeItem(at: entry)
                }
            }
        }.value

        let after = await localStorageInventory().group(.caches)?.bytes ?? 0
        return max(0, before - after)
    }

    /// Forget every credential on the device: each saved gateway's Keychain
    /// entry and the Portal token. The rows survive so the gateways stay
    /// listed and probeable — signing back in is a tap, not a re-add.
    public func signOutOfEverything() async {
        for gateway in ConnectionRegistry.shared.saved {
            await signOutGateway(gateway)
        }
        await NousPortalClient(portalURL: PortalDirectoryAPI.resolvedPortalURL).signOut()
        connections = ConnectionRegistry.shared.rows
    }

    /// The full reset: credentials, saved gateways, preferences, caches, and
    /// the in-memory world. Bots and their history live on the gateway and are
    /// untouched — this only unmakes what Talaria wrote here.
    public func deleteAllLocalData() async throws {
        AdvancedTerminalCoordinator.shared.stopAndForgetEverything()
        // Device-owned transcripts/blobs are the only part of this reset that
        // can fail durably. Prove their empty index first; otherwise preserve
        // credentials/preferences and surface an actionable partial failure.
        try await deleteAllRoomData()
        await signOutOfEverything()
        if client != nil { await disconnectGateway() }
        for gateway in ConnectionRegistry.shared.saved {
            await removeGateway(gateway)
        }
        _ = await clearLocalCaches()
        detachSettingsDiagnostics()

        // Preferences last, and only after the in-memory stores have been put
        // back to their shipped values — each of those writes through, so
        // resetting after the sweep would leave the keys behind again.
        //
        // Every store that mirrors a `talaria` default has to be named here.
        // Removing a key while its store still holds the old value does not
        // delete the preference, it only postpones it: the next write puts it
        // straight back, and "delete local data" turns into a lie the user
        // discovers a week later.
        settings.resetToDefaults()
        theme.themeID = .soft
        voice.autoSpeak = true
        ModelPresetStore.shared.reset()
        ModelVisibilityStore.shared.reset()
        // Solo's stores AND its directory tree: transcripts, the memory note and
        // the images handed to it have no copy on any gateway, so this is the
        // only thing that unmakes them (AppModelLive+Solo.swift).
        soloForgetEverything()
        // The activity ledger is held in memory and written on every new row,
        // so dropping only the key would restore 200 entries on the next event.
        clearActivityJournal()
        // Same trap for the unread watermarks: the store holds every gateway's
        // marks in memory and persists on each ingest, so removing the key below
        // without this would put the whole blob straight back on the next roster
        // poll (AppModelLive+Unread.swift). Dropping them also resets `seeded`,
        // which is what makes the roster come back as calm as a fresh install's
        // instead of badging the backlog.
        forgetUnreadWatermarks()
        // This preference is observable process state as well as a defaults
        // key. Removing only the key leaves the roster bell enabled until the
        // next launch and lets a later write resurrect the deleted value.
        ActivityToastPref.shared.forget()
        // Cards mid-flight belong to the world being unmade.
        clearToasts()
        let defaults = UserDefaults.standard
        for (key, _) in Self.talariaDefaults() { defaults.removeObject(forKey: key) }

        flushDemoWorld()
        connections = []
        notificationPrefs = []
        resetOnboarding()
    }
}

// MARK: - Cross-screen navigation

public extension Notification.Name {
    /// Push the Settings screen. Posted by `AppModel.requestSettings()` from
    /// the roster header and Connections; whoever owns the screen graph
    /// listens (see `View.talariaSettings(model:)` in SettingsView.swift).
    static let talariaOpenSettings = Notification.Name("bot.talaria.openSettings")
}
