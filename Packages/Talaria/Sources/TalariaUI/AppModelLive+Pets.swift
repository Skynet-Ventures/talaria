import Foundation
import TalariaKit
import TalariaTheme

// Bot Mode pets — the live half of the petdex mascot surface.
//
// The RPCs are wrapped in GatewayClient+Pets.swift; the wire models live in
// TalariaKit/PetModels.swift. What this file owns is the *policy* around them,
// and there are only three rules worth remembering:
//
// 1. **The sheet is the expensive thing.** A 1536×1872 atlas is several
//    megabytes on the wire and ~11 MB decoded. So the refresh path is always
//    `pet.info.meta` first (five fields, one stat) and the revision it reports
//    is the cache key. A revision whose bitmap is already in memory — this
//    profile's, or another profile wearing the same pet — never reaches
//    `pet.info` at all. When it does, `knownRevision` rides along so an
//    unchanged sheet comes back as `spritesheetUnchanged` with no bytes.
//    Decoding happens off the main actor; the decoded sheet is shared by every
//    `PetSpriteView` on screen (PetSpriteSheet is a reference type for exactly
//    this reason).
//
// 2. **Silence means gone.** Every read-side pet RPC fails open server-side:
//    no pet engine, no configured pet or a decode hiccup all answer
//    `{"enabled": false}`, and a gateway that predates the surface answers
//    -32601. Both mean "there are no pets here", and both leave the UI exactly
//    as it would be without this file — no sprite, no gallery row, no notice.
//    The one distinction worth drawing is between "no pets exist" and "pets
//    exist but the display is switched off": the second still deserves a
//    picker (that is how you turn them back on), so `probePets` asks
//    `pet.gallery localOnly` before hiding the entry point.
//
// 3. **Reads and cosmetic writes are profile-scoped; generation is not.**
//    `display.pet.*` lives in each profile's config.yaml and sprites install
//    under its `pets/` dir, so every read/write here carries `profile`. The
//    generate/hatch RPCs stage into a gateway-global temp root and only touch
//    a profile when the hatched pet is adopted with `pet.select` — so the run
//    is tracked once, gateway-wide, and its progress events are routed to the
//    surface that started it.
//
// Demo mode has no spritesheet to draw and no gateway to ask, so the whole
// surface is simply absent there rather than faked.

// MARK: - Per-profile state

struct PetTarget: Hashable, Sendable {
    var gatewayID: String
    var profile: String?

    var stateKey: String {
        if let profile { return "pet:\(gatewayID.count):\(gatewayID)\(profile)" }
        return "pet-launch:\(gatewayID.count):\(gatewayID)"
    }
}

/// One profile's pet surface: the active mascot, the picker's gallery, and the
/// generate → hatch flow. `AppModel`'s stored properties live in AppModel.swift
/// (another owner) and extensions cannot add storage, so these hang off a
/// MainActor side table, the same shape `CapabilityState` uses.
@MainActor
@Observable
public final class PetSurfaceState {
    /// Profile (bot id) this pet belongs to. Empty = the gateway's launch profile.
    public internal(set) var profile: String = ""
    @ObservationIgnored var target: PetTarget?

    /// False once the gateway has answered -32601 for the pet surface: it is
    /// older than pets, and nothing pet-shaped is ever shown again.
    public internal(set) var supported = true
    /// `display.pet.enabled` with an installed, renderable pet behind it.
    public internal(set) var enabled = false
    /// The active pet's identity + geometry (no pixels).
    public internal(set) var pet: Pet?
    /// The decoded atlas, shared with every sprite view drawing this pet.
    public internal(set) var sheet: PetSpriteSheet?

    /// The picker's list — petdex merged with local install state.
    public internal(set) var gallery = PetGallerySnapshot()
    /// slug → cropped idle-frame PNG (`pet.thumb`), kilobytes each.
    public internal(set) var thumbnails: [String: Data] = [:]

    /// The generate → choose → hatch → adopt flow, start to finish.
    public var generation = PetGenerationState()
    /// The freshly hatched pet's preview — installed but not adopted, so it is
    /// deliberately kept apart from `pet`/`sheet` until `pet.select` runs.
    public internal(set) var hatchedPet: Pet?
    public internal(set) var hatchedSheet: PetSpriteSheet?

    public internal(set) var isLoading = false
    /// True once a probe has settled, so the surface isn't judged empty first.
    public internal(set) var hasLoaded = false
    /// The gateway's own words for the last failure; nil when all is well.
    /// Screens prefix it with their themed lead.
    public internal(set) var notice: String?
    /// Rows with an action in flight, keyed "<verb>:<slug>".
    public internal(set) var busy: Set<String> = []

    public init() {}

    public func isBusy(_ key: String) -> Bool { busy.contains(key) }

    /// A drawable mascot right now.
    public var isRenderable: Bool {
        supported && enabled && pet != nil && sheet != nil
    }

    /// Any pet installed or adoptable on this gateway.
    public var hasPets: Bool { !gallery.pets.isEmpty }

    /// Worth offering an entry point at all: something to show, something to
    /// adopt, or an image backend that could hatch one.
    public var hasSurface: Bool {
        supported && (enabled || hasPets || generation.available)
    }

    // MARK: Mutations (the model drives these; screens read)

    func apply(pet: Pet, sheet: PetSpriteSheet) {
        self.pet = pet
        self.sheet = sheet
        enabled = true
        supported = true
        notice = nil
    }

    /// Rebuild from cheap metadata plus a sheet we already hold — the path that
    /// costs one small RPC and zero bitmap bytes.
    func apply(meta: PetMeta, sheet: PetSpriteSheet) {
        apply(pet: Pet(slug: meta.slug, displayName: meta.displayName,
                       revision: meta.revision.isEmpty ? sheet.revision : meta.revision,
                       scale: meta.scale, geometry: sheet.geometry),
              sheet: sheet)
    }

    /// `{"enabled": false}` — no pet renders anywhere. The gallery survives:
    /// pets can be installed with the display switched off, and the picker is
    /// how it gets switched back on.
    func clearActive() {
        enabled = false
        pet = nil
        sheet = nil
    }

    /// -32601 — this gateway has no pet surface at all.
    func markUnsupported() {
        supported = false
        clearActive()
        gallery = PetGallerySnapshot()
        thumbnails.removeAll()
        generation = PetGenerationState()
        notice = nil
    }

    /// Local-only scale change, for a slider that must not RPC per pixel.
    func setScale(_ value: Double) {
        pet?.scale = value
    }

    func clearHatched() {
        hatchedPet = nil
        hatchedSheet = nil
    }

    func resetForDetach() {
        clearActive()
        gallery = PetGallerySnapshot()
        thumbnails.removeAll()
        generation = PetGenerationState()
        clearHatched()
        isLoading = false
        hasLoaded = false
        notice = nil
        busy.removeAll()
    }
}

// MARK: - Runtime (side table)

/// Gateway-wide pet book-keeping: the per-profile stores, the shared bitmap
/// cache, the event handler and the single in-flight generation run.
@MainActor
final class PetRuntime {
    static let shared = PetRuntime()

    var states: [String: PetSurfaceState] = [:]

    /// Gateways that answered -32601 once: only that source stops probing.
    var unsupportedGateways: Set<String> = []

    /// Decoded atlases keyed by a length-prefixed gateway id plus revision. Two gateways can both
    /// serve a pet whose revision string ("<mtime_ns>:<size>") happens to
    /// match, and one must never wear the other's sprite.
    private var sheets: [String: PetSpriteSheet] = [:]
    /// Least-recently-used first.
    private var recency: [String] = []
    /// A decoded sheet is ~11 MB. Three covers the honest working set: the
    /// active pet, a hatch preview, and the one just replaced.
    static let sheetCacheLimit = 3

    weak var attachedClient: GatewayClient?
    var attachedGatewayID: String?
    var handlerID: UUID?
    var routerTask: Task<Void, Never>?
    /// Debounce for each gateway's `pet.changed` broadcast. One noisy source
    /// must not cancel another source's refresh.
    var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Per-profile refreshes, so a roster of six working bots collapses onto
    /// one call each rather than one per row repaint.
    var loads: [String: Task<Void, Never>] = [:]
    /// Generation token for each load slot. A cancelled task from an old
    /// connection must not clear a replacement connection's in-flight load.
    var loadIDs: [String: UUID] = [:]

    /// Each gateway permits one global generate/hatch run, but independent
    /// gateways must never block or cancel one another.
    var generatingProfiles: [String: String] = [:]
    var runTasks: [String: Task<Void, Never>] = [:]
    var runIDs: [String: UUID] = [:]
    /// Gateways where the user pressed Stop: the RPC's "cancelled" error is an
    /// outcome, not a failure, and must not raise a notice.
    var cancelledGateways: Set<String> = []

    private func key(gatewayID: String, revision: String) -> String {
        "pet-sheet:\(gatewayID.count):\(gatewayID)\(revision)"
    }

    func sheet(gatewayID: String, revision: String) -> PetSpriteSheet? {
        guard !revision.isEmpty else { return nil }
        let id = key(gatewayID: gatewayID, revision: revision)
        guard let hit = sheets[id] else { return nil }
        touch(id)
        return hit
    }

    func store(_ sheet: PetSpriteSheet, gatewayID: String) {
        guard !sheet.revision.isEmpty else { return }
        let id = key(gatewayID: gatewayID, revision: sheet.revision)
        sheets[id] = sheet
        touch(id)
        while recency.count > Self.sheetCacheLimit, let oldest = recency.first {
            recency.removeFirst()
            sheets.removeValue(forKey: oldest)
        }
    }

    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    /// A different gateway's pets are not ours — and ~11 MB of bitmaps has no
    /// business outliving the connection that produced it.
    func reset() {
        states.removeAll()
        sheets.removeAll()
        recency.removeAll()
        unsupportedGateways.removeAll()
        generatingProfiles.removeAll()
        attachedGatewayID = nil
        cancelledGateways.removeAll()
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        for task in runTasks.values { task.cancel() }
        runTasks.removeAll()
        runIDs.removeAll()
        for task in loads.values { task.cancel() }
        loads.removeAll()
        loadIDs.removeAll()
    }

    func drop(gatewayID: String) {
        let stateKeys = states.compactMap { key, state in
            state.target?.gatewayID == gatewayID ? key : nil
        }
        if generatingProfiles[gatewayID] != nil {
            runTasks[gatewayID]?.cancel()
            runTasks.removeValue(forKey: gatewayID)
            runIDs.removeValue(forKey: gatewayID)
            generatingProfiles.removeValue(forKey: gatewayID)
            cancelledGateways.insert(gatewayID)
        }
        for key in stateKeys {
            states[key]?.resetForDetach()
            states.removeValue(forKey: key)
            loads[key]?.cancel()
            loads.removeValue(forKey: key)
            loadIDs.removeValue(forKey: key)
        }
        refreshTasks[gatewayID]?.cancel()
        refreshTasks.removeValue(forKey: gatewayID)
        let sheetPrefix = "pet-sheet:\(gatewayID.count):\(gatewayID)"
        sheets = sheets.filter { !$0.key.hasPrefix(sheetPrefix) }
        recency.removeAll { $0.hasPrefix(sheetPrefix) }
        unsupportedGateways.remove(gatewayID)
    }
}

// MARK: - Model API

extension AppModel {

    internal func petTarget(profileID: String?) -> PetTarget? {
        if let profileID, let route = GatewayBotRoute(qualifiedID: profileID) {
            return PetTarget(gatewayID: route.gatewayID, profile: route.profile)
        }
        guard let gatewayID = LiveRuntime.shared.gatewayID else { return nil }
        let profile = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetTarget(gatewayID: gatewayID,
                         profile: profile?.isEmpty == false ? profile : nil)
    }

    private func petContext(profileID: String?, state: PetSurfaceState) async
        -> (target: PetTarget, client: GatewayClient)? {
        guard let target = state.target,
              petTarget(profileID: profileID) == target,
              PetRuntime.shared.states[target.stateKey] === state,
              !PetRuntime.shared.unsupportedGateways.contains(target.gatewayID) else {
            return nil
        }
        guard let client = try? await routedClient(gatewayID: target.gatewayID) else {
            return nil
        }
        await attachRoutedEventsIfNeeded(client: client, gatewayID: target.gatewayID,
                                         preserveStateOnReplacement: true)
        guard petStateIsCurrent(state, profileID: profileID, target: target) else {
            return nil
        }
        return (target, client)
    }

    private func petStateIsCurrent(_ state: PetSurfaceState, profileID: String?,
                                   target: PetTarget) -> Bool {
        petTarget(profileID: profileID) == target
            && PetRuntime.shared.states[target.stateKey] === state
    }

    private func petProfileID(for target: PetTarget) -> String? {
        target.profile.map {
            GatewayBotRoute(gatewayID: target.gatewayID, profile: $0).qualifiedID
        }
    }

    internal func dropPetScope(gatewayID: String) {
        PetRuntime.shared.drop(gatewayID: gatewayID)
    }

    /// The (memoized) pet store for a profile. Pass nil for the gateway's
    /// launch profile.
    public func pets(for profile: String?) -> PetSurfaceState {
        let target = petTarget(profileID: profile)
        let key = target?.stateKey ?? "pet-demo:\(profile ?? "")"
        if let existing = PetRuntime.shared.states[key] { return existing }
        let fresh = PetSurfaceState()
        fresh.profile = target?.profile ?? profile ?? ""
        fresh.target = target
        if let target,
           PetRuntime.shared.unsupportedGateways.contains(target.gatewayID) {
            fresh.supported = false
        }
        PetRuntime.shared.states[key] = fresh
        return fresh
    }

    /// The mascot to draw for a bot right now, or nil. Pure read — it never
    /// starts a fetch, so it is safe to call from a view body on every repaint;
    /// `ensurePet(for:)` is what loads.
    public func activePet(for botID: String) -> (pet: Pet, sheet: PetSpriteSheet)? {
        let state = pets(for: botID)
        guard state.isRenderable, let pet = state.pet, let sheet = state.sheet else { return nil }
        return (pet, sheet)
    }

    /// Load a bot's pet the first time it matters — a roster row that starts
    /// working. One cheap `pet.info.meta` per profile per connection; the
    /// `pet.changed` broadcast keeps it fresh after that.
    public func ensurePet(for botID: String) async {
        let state = pets(for: botID)
        guard mode == .live, state.supported, !state.hasLoaded else { return }
        guard let target = state.target else { return }
        await refreshPet(profile: petProfileID(for: target))
    }

    /// Which animation row a bot's live state maps to (`derive_pet_state`).
    public func petState(for bot: Bot) -> PetState {
        PetState.derive(busy: bot.status == .working,
                        awaitingInput: bot.status == .approval,
                        toolRunning: bot.status == .working && bot.task != nil)
    }

    // MARK: - Event router

    /// Register the pet surface's event handler on the live client: the
    /// `pet.changed` broadcast plus the generate/hatch progress streams. The
    /// main pump in AppModelLive drops all three. Idempotent per client; call
    /// after every connect.
    public func attachPetEventRouter() {
        guard mode == .live, let client,
              let gatewayID = LiveRuntime.shared.gatewayID else { return }
        let runtime = PetRuntime.shared
        if runtime.routerTask != nil, runtime.attachedClient === client { return }
        detachPetEventRouter()
        runtime.attachedClient = client
        runtime.attachedGatewayID = gatewayID
        // One AsyncStream so MainActor delivery preserves wire order: a draft
        // must never land before the token-only event that keys it.
        let (stream, continuation) = AsyncStream.makeStream(
            of: GatewayEpochEventDelivery.self)
        runtime.routerTask = Task { @MainActor [weak self] in
            for await delivery in stream {
                guard PetRuntime.shared.attachedClient === client,
                      PetRuntime.shared.attachedGatewayID == gatewayID,
                      await client.isCurrentReadyTransport(
                        epoch: delivery.transportEpoch) else { continue }
                self?.routePetEvent(delivery.event, sourceGatewayID: gatewayID)
            }
        }
        Task { @MainActor in
            let id = await client.addEpochEventHandler { event, transportEpoch in
                continuation.yield(GatewayEpochEventDelivery(
                    event: event, transportEpoch: transportEpoch))
            }
            guard PetRuntime.shared.attachedClient === client,
                  PetRuntime.shared.attachedGatewayID == gatewayID else {
                await client.removeEventHandler(id)
                return
            }
            PetRuntime.shared.handlerID = id
        }
    }

    /// Drop the pet handler (gateway swap / sign-out) and everything it cached.
    public func detachPetEventRouter() {
        let runtime = PetRuntime.shared
        runtime.routerTask?.cancel()
        runtime.routerTask = nil
        if let id = runtime.handlerID, let target = runtime.attachedClient {
            Task { await target.removeEventHandler(id) }
        }
        runtime.handlerID = nil
        runtime.attachedClient = nil
        if let gatewayID = runtime.attachedGatewayID {
            runtime.drop(gatewayID: gatewayID)
        }
        runtime.attachedGatewayID = nil
    }

    internal func routePetEvent(_ event: GatewayEvent, sourceGatewayID: String) {
        switch event.type {
        case "pet.changed":
            // The payload is meta-shaped but speaks for the gateway's launch
            // profile only, so it is treated as a nudge: every profile whose
            // pet is on screen re-reads its own cheap meta. Debounced — the
            // watcher floors it at 2 s but a select + scale lands twice.
            let runtime = PetRuntime.shared
            runtime.refreshTasks[sourceGatewayID]?.cancel()
            runtime.refreshTasks[sourceGatewayID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                let targets = PetRuntime.shared.states.values.compactMap { state -> PetTarget? in
                    guard state.hasLoaded,
                          state.target?.gatewayID == sourceGatewayID else { return nil }
                    return state.target
                }
                for target in targets {
                    let profileID = target.profile.map {
                        GatewayBotRoute(gatewayID: sourceGatewayID, profile: $0).qualifiedID
                    }
                    await self.refreshPet(profile: profileID)
                }
            }

        case "pet.generate.progress":
            ingestDraft(event.payload, sourceGatewayID: sourceGatewayID)

        case "pet.hatch.progress":
            generatingSurface(sourceGatewayID: sourceGatewayID)?
                .generation.progress = PetHatchProgress(event.payload)

        default:
            break
        }
    }

    /// The surface that started the in-flight run, if it is still hatching or
    /// drafting. Progress for a run nobody is watching is dropped.
    private func generatingSurface(sourceGatewayID: String) -> PetSurfaceState? {
        guard let key = PetRuntime.shared.generatingProfiles[sourceGatewayID],
              let state = PetRuntime.shared.states[key],
              state.target?.gatewayID == sourceGatewayID,
              state.generation.isBusy else { return nil }
        return state
    }

    /// One `pet.generate.progress` beat: `{token, count}` on its own for the
    /// init event, then `{token, index, dataUri, count}` per draft.
    private func ingestDraft(_ payload: JSONValue?, sourceGatewayID: String) {
        guard let state = generatingSurface(sourceGatewayID: sourceGatewayID) else { return }
        if let token = payload?["token"]?.stringValue, !token.isEmpty {
            state.generation.token = token
        }
        if let count = payload?["count"]?.intValue, count > 0 {
            state.generation.expectedDrafts = count
        }
        guard let uri = payload?["dataUri"]?.stringValue, !uri.isEmpty else { return }
        let index = payload?["index"]?.intValue ?? state.generation.drafts.count
        if let hit = state.generation.drafts.firstIndex(where: { $0.index == index }) {
            state.generation.drafts[hit] = PetDraft(index: index, dataURI: uri)
        } else {
            state.generation.drafts.append(PetDraft(index: index, dataURI: uri))
            state.generation.drafts.sort { $0.index < $1.index }
        }
    }

    // MARK: - Reading the active pet

    /// Open a pet surface for a profile: the active pet, whether the gateway
    /// has any pets at all, and whether it could generate one.
    ///
    /// The gallery probe is what separates "this gateway has no pets" (hide
    /// everything) from "this profile's display is switched off" (still offer
    /// the picker, since that is where it gets switched back on).
    public func probePets(profile: String?) async {
        let state = pets(for: profile)
        guard let target = state.target else { return }
        let pinnedProfile = petProfileID(for: target)
        await refreshPet(profile: pinnedProfile)
        guard petStateIsCurrent(state, profileID: profile, target: target),
              state.supported else { return }
        if !state.enabled, state.gallery.pets.isEmpty {
            await loadPetGallery(profile: pinnedProfile, localOnly: true)
        }
        if !state.generation.available {
            await refreshPetGenerateStatus(profile: pinnedProfile)
        }
    }

    /// Bring one profile's active pet up to date.
    ///
    /// Deliberately meta-first: `pet.info.meta` costs five fields and a stat,
    /// and the revision it reports is the bitmap cache key. A revision already
    /// decoded in memory — this profile's, or another profile wearing the same
    /// pet — is served from cache and no sheet is fetched at all. Only an
    /// unknown revision reaches `pet.info`, and that call still sends the
    /// revision we hold so the gateway can answer `spritesheetUnchanged`
    /// rather than shipping megabytes.
    public func refreshPet(profile: String?) async {
        let state = pets(for: profile)
        let key = state.target?.stateKey ?? "pet-demo:\(profile ?? "")"
        if let inflight = PetRuntime.shared.loads[key] {
            await inflight.value
            return
        }
        let loadID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPetRefresh(profile: profile)
        }
        PetRuntime.shared.loadIDs[key] = loadID
        PetRuntime.shared.loads[key] = task
        await task.value
        if PetRuntime.shared.loadIDs[key] == loadID {
            PetRuntime.shared.loads[key] = nil
            PetRuntime.shared.loadIDs[key] = nil
        }
    }

    private func performPetRefresh(profile: String?) async {
        let state = pets(for: profile)
        guard mode == .live else {
            // Demo mode: no sheet to draw and no gateway to ask. The surface
            // stays absent rather than faked.
            state.markUnsupported()
            state.hasLoaded = true
            return
        }
        guard let context = await petContext(profileID: profile, state: state) else {
            state.hasLoaded = true
            return
        }
        state.isLoading = true
        defer {
            state.isLoading = false
            if petStateIsCurrent(state, profileID: profile, target: context.target) {
                state.hasLoaded = true
            }
        }

        let meta: PetMeta
        let metaProbe = await Self.probe({
            try await context.client.petInfoMeta(profile: context.target.profile)
        })
        guard petStateIsCurrent(state, profileID: profile, target: context.target) else { return }
        switch metaProbe {
        case .value(let value):
            meta = value
        case .unsupported:
            markPetsUnsupported(gatewayID: context.target.gatewayID)
            return
        case .failed(let message):
            state.notice = message
            return
        }

        state.supported = true
        state.notice = nil
        guard meta.enabled, !meta.slug.isEmpty else {
            state.clearActive()
            return
        }
        // Cache hit — the bitmap for this revision is already decoded, so the
        // whole refresh cost one small RPC.
        if let cached = PetRuntime.shared.sheet(gatewayID: context.target.gatewayID,
                                                revision: meta.revision) {
            state.apply(meta: meta, sheet: cached)
            return
        }
        // Cache miss. `knownRevision` is tied to the bitmap actually held, not
        // to the metadata, so "unchanged" always means we can keep drawing.
        let known = state.sheet?.revision ?? ""
        let infoProbe = await Self.probe({
            try await context.client.petInfo(profile: context.target.profile,
                                             knownRevision: known)
        })
        guard petStateIsCurrent(state, profileID: profile, target: context.target) else { return }
        switch infoProbe {
        case .value(let payload):
            await applyPetInfo(payload, to: state, profileID: profile, target: context.target)
        case .unsupported:
            markPetsUnsupported(gatewayID: context.target.gatewayID)
        case .failed(let message):
            state.notice = message
        }
    }

    private func applyPetInfo(_ payload: PetInfoPayload, to state: PetSurfaceState,
                              profileID: String?, target: PetTarget) async {
        guard petStateIsCurrent(state, profileID: profileID, target: target) else { return }
        guard payload.enabled, let pet = payload.pet else {
            state.clearActive()
            return
        }
        if payload.spritesheetUnchanged, let sheet = state.sheet {
            // The gateway confirmed our copy: several megabytes that never
            // left it. Keep the bitmap, take the fresh metadata.
            state.apply(pet: pet, sheet: sheet)
            return
        }
        guard let base64 = payload.spritesheetBase64,
              let sheet = await Self.decodePetSheet(base64: base64, revision: pet.revision,
                                                    geometry: pet.geometry) else {
            // A sheet that will not decode is a corrupt payload, not a pet.
            state.clearActive()
            return
        }
        guard petStateIsCurrent(state, profileID: profileID, target: target) else { return }
        PetRuntime.shared.store(sheet, gatewayID: target.gatewayID)
        state.apply(pet: pet, sheet: sheet)
    }

    /// Decode + slice off the main actor: baking an 11 MB bitmap on it would
    /// drop frames on every surface, and the sliced sheet is immutable
    /// afterwards (`PetSpriteSheet` is `@unchecked Sendable` for this reason).
    static func decodePetSheet(base64: String, revision: String,
                               geometry: PetGeometry) async -> PetSpriteSheet? {
        await Task.detached(priority: .userInitiated) {
            PetSpriteSheet(base64: base64, revision: revision, geometry: geometry)
        }.value
    }

    private func markPetsUnsupported(gatewayID: String) {
        PetRuntime.shared.unsupportedGateways.insert(gatewayID)
        for state in PetRuntime.shared.states.values
            where state.target?.gatewayID == gatewayID {
            state.markUnsupported()
        }
    }

    // MARK: - Gallery

    /// Load the picker's list. `localOnly` skips the (possibly slow, possibly
    /// unreachable) petdex manifest — the screen asks for that first so the
    /// user's own pets render immediately, then re-asks for the full list,
    /// which usually hits the manifest cache the first call warmed.
    public func loadPetGallery(profile: String?, localOnly: Bool = false) async {
        let state = pets(for: profile)
        guard mode == .live, state.supported,
              let context = await petContext(profileID: profile, state: state) else { return }
        let result = await Self.probe({
            try await context.client.petGallery(profile: context.target.profile,
                                                localOnly: localOnly)
        })
        guard petStateIsCurrent(state, profileID: profile, target: context.target) else { return }
        switch result {
        case .value(let snapshot):
            // A local-only pass must not blank a fuller list already on screen.
            guard !localOnly || snapshot.pets.count >= state.gallery.pets.count
                    || state.gallery.pets.isEmpty else {
                state.gallery.enabled = snapshot.enabled
                state.gallery.activeSlug = snapshot.activeSlug
                return
            }
            state.gallery = snapshot
            state.notice = nil
        case .unsupported:
            markPetsUnsupported(gatewayID: context.target.gatewayID)
        case .failed(let message):
            state.notice = message
        }
    }

    /// Both passes, in the order that paints fastest.
    public func loadPetGalleryProgressively(profile: String?) async {
        let state = pets(for: profile)
        guard let target = state.target else { return }
        let pinnedProfile = petProfileID(for: target)
        await loadPetGallery(profile: pinnedProfile, localOnly: true)
        await loadPetGallery(profile: pinnedProfile, localOnly: false)
    }

    /// A cropped idle-frame PNG for one gallery row, memoized per slug. The
    /// gateway crops and caches these, so a thumbnail costs kilobytes where the
    /// spritesheet costs megabytes — a grid must never be drawn from sheets.
    @discardableResult
    public func loadPetThumbnail(_ entry: PetGalleryEntry, profile: String?) async -> Data? {
        let state = pets(for: profile)
        if let cached = state.thumbnails[entry.slug] { return cached }
        guard mode == .live, state.supported,
              let context = await petContext(profileID: profile, state: state) else { return nil }
        let key = "thumb:\(entry.slug)"
        guard state.busy.insert(key).inserted else { return nil }
        defer { state.busy.remove(key) }
        // `url` is only meaningful for a pet that isn't installed yet: the
        // gateway fetches the manifest sheet so the phone never talks to the CDN.
        let data = try? await context.client.petThumbnail(
            slug: entry.slug,
            url: entry.installed ? "" : entry.spritesheetURL,
            profile: context.target.profile)
        guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
            return nil
        }
        guard let data else { return nil }
        state.thumbnails[entry.slug] = data
        return data
    }

    // MARK: - Adopt / rename / remove / disable / scale

    /// Adopt a pet: install it if needed, make it active, re-read everything.
    @discardableResult
    public func selectPet(slug: String, profile: String?) async -> Bool {
        let state = pets(for: profile)
        guard mode == .live, !slug.isEmpty,
              let context = await petContext(profileID: profile, state: state) else { return false }
        let key = "select:\(slug)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            let mutation = try await context.client.petSelect(
                slug: slug, profile: context.target.profile)
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return false
            }
            guard mutation.ok else {
                // The handler errors on a real failure, so this is the odd
                // "installed nothing, said nothing" case — still not silence.
                state.notice = "pet.select returned ok:false for \(slug)"
                return false
            }
            state.notice = nil
            let pinnedProfile = petProfileID(for: context.target)
            await refreshPet(profile: pinnedProfile)
            await loadPetGallery(profile: pinnedProfile, localOnly: true)
            return true
        } catch {
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return false
            }
            state.notice = Self.shortMessage(error)
            return false
        }
    }

    /// Rename a pet. The gateway realigns the slug to the new name, so the
    /// answer's slug may differ from the one sent — callers adopt it.
    @discardableResult
    public func renamePet(slug: String, to name: String, profile: String?) async -> String? {
        let state = pets(for: profile)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .live, !slug.isEmpty, !trimmed.isEmpty,
              let context = await petContext(profileID: profile, state: state) else { return nil }
        let key = "rename:\(slug)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            let mutation = try await context.client.petRename(
                slug: slug, name: trimmed, profile: context.target.profile)
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return nil
            }
            guard mutation.ok else {
                state.notice = "pet.rename returned ok:false for \(slug)"
                return nil
            }
            state.notice = nil
            let pinnedProfile = petProfileID(for: context.target)
            await refreshPet(profile: pinnedProfile)
            await loadPetGallery(profile: pinnedProfile, localOnly: true)
            return mutation.slug.isEmpty ? slug : mutation.slug
        } catch {
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return nil
            }
            state.notice = Self.shortMessage(error)
            return nil
        }
    }

    /// Delete a pet's on-disk directory. Removing the active one also switches
    /// the display off server-side, so nothing renders a missing sprite.
    public func removePet(slug: String, profile: String?) async {
        let state = pets(for: profile)
        guard mode == .live, !slug.isEmpty,
              let context = await petContext(profileID: profile, state: state) else { return }
        let key = "remove:\(slug)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            try await context.client.petRemove(slug: slug, profile: context.target.profile)
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return
            }
            state.thumbnails.removeValue(forKey: slug)
            state.notice = nil
            if state.pet?.slug == slug { state.clearActive() }
            let pinnedProfile = petProfileID(for: context.target)
            await refreshPet(profile: pinnedProfile)
            await loadPetGallery(profile: pinnedProfile, localOnly: true)
        } catch {
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return
            }
            state.notice = Self.shortMessage(error)
        }
    }

    /// `display.pet.enabled = false`. Installed pets survive; nothing renders.
    public func disablePets(profile: String?) async {
        let state = pets(for: profile)
        guard mode == .live,
              let context = await petContext(profileID: profile, state: state) else { return }
        state.busy.insert("disable")
        defer { state.busy.remove("disable") }
        do {
            try await context.client.petDisable(profile: context.target.profile)
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return
            }
            state.clearActive()
            state.gallery.enabled = false
            state.notice = nil
        } catch {
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return
            }
            state.notice = Self.shortMessage(error)
        }
    }

    /// Local-only scale, for a slider that must not RPC per pixel.
    public func previewPetScale(_ value: Double, profile: String?) {
        pets(for: profile).setScale(Pet.clampScale(value))
    }

    /// Persist `display.pet.scale`. The gateway clamps and returns what it
    /// stored, so the slider follows the truth rather than its own optimism.
    public func commitPetScale(_ value: Double, profile: String?) async {
        let state = pets(for: profile)
        let clamped = Pet.clampScale(value)
        state.setScale(clamped)
        guard mode == .live,
              let context = await petContext(profileID: profile, state: state) else { return }
        state.busy.insert("scale")
        defer { state.busy.remove("scale") }
        do {
            let applied = try await context.client.petScale(
                clamped, profile: context.target.profile)
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return
            }
            state.setScale(Pet.clampScale(applied))
            state.notice = nil
        } catch {
            guard petStateIsCurrent(state, profileID: profile, target: context.target) else {
                return
            }
            state.notice = Self.shortMessage(error)
        }
    }

    // MARK: - Generation

    /// Whether this gateway has a reference-capable image backend at all.
    /// False means offer setup, not a dead prompt box.
    public func refreshPetGenerateStatus(profile: String?) async {
        let state = pets(for: profile)
        guard mode == .live, state.supported,
              let context = await petContext(profileID: profile, state: state) else { return }
        let result = await Self.probe({ try await context.client.petGenerateStatus() })
        guard petStateIsCurrent(state, profileID: profile, target: context.target) else { return }
        switch result {
        case .value(let capability):
            state.generation.available = capability.available
            state.generation.providers = capability.providers
            if state.generation.provider.isEmpty {
                state.generation.provider = capability.providers.first(where: \.isDefault)?.name ?? ""
            }
        case .unsupported, .failed:
            state.generation.available = false
            state.generation.providers = []
        }
    }

    /// Start `pet.generate`. Drafts stream in over `pet.generate.progress` and
    /// this call's return value is the settled truth — minutes, not seconds.
    public func startPetGeneration(profile: String?) {
        let state = pets(for: profile)
        let prompt = state.generation.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = PetRuntime.shared
        guard mode == .live, let target = state.target,
              !PetRuntime.shared.unsupportedGateways.contains(target.gatewayID),
              runtime.runTasks[target.gatewayID] == nil,
              !state.generation.isBusy, !prompt.isEmpty else { return }

        state.generation.phase = .drafting
        state.generation.drafts = []
        state.generation.selectedDraft = nil
        state.generation.token = ""
        state.generation.error = nil
        state.generation.expectedDrafts = state.generation.count
        let count = state.generation.count
        let provider = state.generation.provider

        runtime.generatingProfiles[target.gatewayID] = target.stateKey
        runtime.cancelledGateways.remove(target.gatewayID)
        let runID = UUID()
        runtime.runIDs[target.gatewayID] = runID
        runtime.runTasks[target.gatewayID] = Task { @MainActor [weak self] in
            defer {
                if PetRuntime.shared.runIDs[target.gatewayID] == runID {
                    PetRuntime.shared.cancelledGateways.remove(target.gatewayID)
                    PetRuntime.shared.runTasks.removeValue(forKey: target.gatewayID)
                    PetRuntime.shared.runIDs.removeValue(forKey: target.gatewayID)
                    PetRuntime.shared.generatingProfiles.removeValue(forKey: target.gatewayID)
                }
            }
            guard let self else { return }
            do {
                let client = try await self.routedClient(gatewayID: target.gatewayID)
                await self.attachRoutedEventsIfNeeded(client: client,
                                                      gatewayID: target.gatewayID,
                                                      preserveStateOnReplacement: true)
                guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                      self.petStateIsCurrent(state, profileID: profile, target: target) else {
                    return
                }
                let result = try await client.petGenerate(prompt: prompt, count: count,
                                                          provider: provider)
                guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                      self.petStateIsCurrent(state, profileID: profile, target: target) else {
                    return
                }
                if !result.token.isEmpty { state.generation.token = result.token }
                if !result.drafts.isEmpty { state.generation.drafts = result.drafts }
                if state.generation.drafts.isEmpty {
                    state.generation.phase = .idle
                } else {
                    state.generation.phase = .choosing
                    state.generation.selectedDraft = state.generation.drafts.first?.index
                }
            } catch {
                guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                      self.petStateIsCurrent(state, profileID: profile, target: target) else {
                    return
                }
                state.generation.phase = .idle
                state.generation.drafts = []
                if !PetRuntime.shared.cancelledGateways.contains(target.gatewayID) {
                    state.generation.error = Self.shortMessage(error)
                }
            }
        }
    }

    /// Turn the chosen draft into a full pet: every animation row generated and
    /// rastered into a sheet, then installed — but NOT made active. The reply
    /// carries the renderer payload so the preview plays before the user
    /// commits.
    public func hatchPet(profile: String?) {
        let state = pets(for: profile)
        let name = state.generation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = PetRuntime.shared
        guard mode == .live, let target = state.target,
              !PetRuntime.shared.unsupportedGateways.contains(target.gatewayID),
              runtime.runTasks[target.gatewayID] == nil,
              !state.generation.isBusy,
              let index = state.generation.selectedDraft,
              !state.generation.token.isEmpty, !name.isEmpty else { return }

        // A fresh cancel key, never the generation token: `pet.generate` is
        // still releasing that one and would wipe the arm this hatch registers.
        let cancelToken = "hatch-" + String(UUID().uuidString.prefix(8))
        let token = state.generation.token
        let prompt = state.generation.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = state.generation.provider

        state.generation.hatchToken = cancelToken
        state.generation.phase = .hatching
        state.generation.progress = nil
        state.generation.warnings = []
        state.generation.error = nil
        state.clearHatched()

        runtime.generatingProfiles[target.gatewayID] = target.stateKey
        runtime.cancelledGateways.remove(target.gatewayID)
        let runID = UUID()
        runtime.runIDs[target.gatewayID] = runID
        runtime.runTasks[target.gatewayID] = Task { @MainActor [weak self] in
            defer {
                if PetRuntime.shared.runIDs[target.gatewayID] == runID {
                    PetRuntime.shared.cancelledGateways.remove(target.gatewayID)
                    PetRuntime.shared.runTasks.removeValue(forKey: target.gatewayID)
                    PetRuntime.shared.runIDs.removeValue(forKey: target.gatewayID)
                    PetRuntime.shared.generatingProfiles.removeValue(forKey: target.gatewayID)
                }
            }
            guard let self else { return }
            do {
                let client = try await self.routedClient(gatewayID: target.gatewayID)
                await self.attachRoutedEventsIfNeeded(client: client,
                                                      gatewayID: target.gatewayID,
                                                      preserveStateOnReplacement: true)
                guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                      self.petStateIsCurrent(state, profileID: profile, target: target) else {
                    return
                }
                let result = try await client.petHatch(token: token, index: index, name: name,
                                                       prompt: prompt, cancelToken: cancelToken,
                                                       provider: provider)
                guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                      self.petStateIsCurrent(state, profileID: profile, target: target) else {
                    return
                }
                state.generation.hatched = result
                state.generation.warnings = result.warnings
                if let pet = result.payload.pet, let base64 = result.payload.spritesheetBase64,
                   let sheet = await Self.decodePetSheet(base64: base64, revision: pet.revision,
                                                         geometry: pet.geometry) {
                    guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                          self.petStateIsCurrent(state, profileID: profile, target: target) else {
                        return
                    }
                    PetRuntime.shared.store(sheet, gatewayID: target.gatewayID)
                    state.hatchedPet = pet
                    state.hatchedSheet = sheet
                }
                state.generation.phase = .preview
            } catch {
                guard PetRuntime.shared.runIDs[target.gatewayID] == runID,
                      self.petStateIsCurrent(state, profileID: profile, target: target) else {
                    return
                }
                // The drafts are still staged, so this lands back on the
                // chooser rather than throwing the whole run away.
                state.generation.phase = .choosing
                if !PetRuntime.shared.cancelledGateways.contains(target.gatewayID) {
                    state.generation.error = Self.shortMessage(error)
                }
            }
        }
    }

    /// Ask an in-flight generate/hatch to stop. Best-effort and idempotent; the
    /// RPC rides off the gateway's worker pool so it lands while the heavy run
    /// occupies it.
    public func cancelPetRun(profile: String?) {
        let state = pets(for: profile)
        let runtime = PetRuntime.shared
        guard state.generation.isBusy, mode == .live, let target = state.target,
              runtime.generatingProfiles[target.gatewayID] == target.stateKey,
              runtime.runTasks[target.gatewayID] != nil else { return }
        runtime.cancelledGateways.insert(target.gatewayID)
        let tokens = [state.generation.hatchToken, state.generation.token]
            .filter { !$0.isEmpty }
        Task { [weak self] in
            guard let self,
                  let client = try? await self.routedClient(gatewayID: target.gatewayID) else {
                return
            }
            for token in tokens { await client.petCancel(token: token) }
        }
    }

    /// Adopt the hatched pet — the only step that touches a profile, since
    /// generation stages gateway-globally.
    public func adoptHatchedPet(profile: String?) async {
        let state = pets(for: profile)
        guard let hatched = state.generation.hatched,
              let target = state.target else { return }
        let adopted = await selectPet(slug: hatched.slug,
                                      profile: petProfileID(for: target))
        guard adopted else { return }
        state.generation.reset()
        state.clearHatched()
    }

    /// Throw the hatched pet away: it is installed on disk, so discarding means
    /// deleting it, not just forgetting it.
    public func discardHatchedPet(profile: String?) async {
        let state = pets(for: profile)
        let target = state.target
        if let hatched = state.generation.hatched, mode == .live,
           let context = await petContext(profileID: profile, state: state) {
            _ = try? await context.client.petRemove(
                slug: hatched.slug, profile: context.target.profile)
        }
        state.generation.reset()
        state.clearHatched()
        if let target {
            await loadPetGallery(profile: petProfileID(for: target), localOnly: true)
        }
    }

    /// Back to the prompt form, keeping what the gateway told us about itself.
    public func resetPetGeneration(profile: String?) {
        let state = pets(for: profile)
        state.generation.reset()
        state.clearHatched()
    }
}
