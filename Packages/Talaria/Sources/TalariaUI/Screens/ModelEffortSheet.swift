import SwiftUI
import TalariaKit
import TalariaTheme

// The model picker, rebuilt to Hermes Desktop's shape: models are GROUPED
// UNDER THEIR PROVIDER, so you can always see where a model comes from.
// Reference: apps/desktop/src/app/shell/model-catalog-menu.tsx — a search field
// pinned at the top, one small-caps header per provider, rows that read
// "<name> <status>" with a checkmark on the active one, a MoA presets section,
// and the Refresh Models / Edit Models… footer. The `-fast` sibling of a model
// collapses into its base row (one row, one toggle), matching
// store/model-visibility.ts `collapseModelFamilies`.
//
// The controls the desktop hides behind a per-row hover submenu live in a
// section of their own here — a phone has no hover, and the reasoning scale is
// the second reason anyone opens this sheet.
//
// Everything the picker knows about the gateway is in AppModelLive+Models.swift
// (state, switching, presets, visibility) and GatewayClient+Models.swift (the
// typed `model.options` payload and the label derivation). This file only
// renders and dispatches.

public struct ModelEffortSheet: View {
    @Environment(\.dismiss) private var dismiss
    var model: AppModel
    var botID: String

    @State private var query = ""
    /// "Edit Models…" flips the list into visibility-toggle mode. A nested
    /// sheet would stack two modals over a chat; one surface, two modes.
    @State private var editing = false
    @State private var didPinCurrent = false

    public init(model: AppModel, botID: String) {
        self.model = model
        self.botID = botID
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var state: ModelPickerState { model.modelPicker(for: botID) }
    private var visibility: ModelVisibilityStore { ModelVisibilityStore.shared }

    // MARK: - Current selection

    /// The pair the picker marks current. Port of `currentPickerSelection`:
    /// a complete local pair wins, otherwise the catalog's own report; fields
    /// are never mixed, so a model is never shown under a foreign provider.
    private var current: (model: String, provider: String) {
        state.catalog.currentSelection(localModel: model.bot(botID)?.pinnedModel ?? "",
                                       localProvider: "")
    }

    private var currentRow: ModelProviderRow? {
        state.catalog.row(owning: current.provider)
    }

    private var currentCapabilities: ModelOptionCapabilities {
        currentRow?.capabilities(for: current.model)
            ?? ModelOptionCapabilities(fast: false, reasoning: true)
    }

    private var currentEffort: String {
        model.chats[botID]?.reasoningEffort ?? ""
    }

    private var currentFastControl: ModelFastControl {
        ModelLabels.fastControl(model: current.model,
                                providerModels: currentRow?.models ?? [],
                                paramSupported: currentCapabilities.fast,
                                fastMode: state.fastMode)
    }

    // MARK: - Grouping

    private struct ProviderGroup: Identifiable {
        var id: String { provider.slug }
        var provider: ModelProviderRow
        var families: [ModelFamily]
    }

    private func rowID(_ providerSlug: String, _ modelID: String) -> String {
        "\(providerSlug)::\(modelID)"
    }

    /// Search spans provider name/slug, the wire id, its `-fast` sibling, the
    /// display name and the alias table — `model-search-text.ts` semantics, so
    /// "kimi" still finds the model whose id is literally `k3`.
    private func matches(_ family: ModelFamily, in provider: ModelProviderRow,
                         query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        let haystack = [
            ModelLabels.searchText(family.id),
            family.fastID ?? "",
            provider.name,
            provider.slug,
            ModelLabels.displayName(family.id),
        ].joined(separator: " ").lowercased()
        return haystack.contains(q)
    }

    /// Collapsed we show the curated/chosen shortlist; typing spans every model
    /// so anything stays reachable past the cut. Order inside a group is the
    /// backend's curated order, never re-sorted; only the groups are ordered,
    /// alphabetically, so switching models cannot reshuffle the list.
    private var groups: [ProviderGroup] {
        let q = ModelLabels.normalize(query)
        let providers = state.catalog.modelProviders
        let visible = visibility.visibleKeys(providers: providers)
        let selection = current

        var out: [ProviderGroup] = []
        for provider in providers {
            let all = ModelLabels.collapseFamilies(provider.models)
            if all.isEmpty { continue }

            let shown: Set<String>
            if q.isEmpty {
                shown = Set(all.filter {
                    visible.contains(ModelVisibilityStore.key(provider: provider.slug, model: $0.id))
                }.map(\.id))
            } else {
                shown = Set(all.filter { matches($0, in: provider, query: q) }.map(\.id))
            }

            // The active model is always present — but in its curated position.
            // While SEARCHING the pin is skipped: a query means "show matches".
            var activeID: String?
            if q.isEmpty, provider.owns(provider: selection.provider), !selection.model.isEmpty {
                activeID = all.first {
                    $0.id == selection.model || $0.fastID == selection.model
                }?.id
            }

            let families = all.filter { shown.contains($0.id) || $0.id == activeID }
            if !families.isEmpty {
                out.append(ProviderGroup(provider: provider, families: families))
            }
        }
        return out.sorted {
            $0.provider.name.localizedCaseInsensitiveCompare($1.provider.name) == .orderedAscending
        }
    }

    /// Presets are searchable rows like everything else.
    private var moaPresets: [String] {
        let q = ModelLabels.normalize(query)
        let presets = state.catalog.moaPresets
        guard !q.isEmpty else { return presets }
        return presets.filter { "moa \($0)".lowercased().contains(q) }
    }

    private var currentRowID: String? {
        let selection = current
        guard !selection.model.isEmpty else { return nil }
        for group in groups {
            guard group.provider.owns(provider: selection.provider) else { continue }
            if let family = group.families.first(where: {
                $0.id == selection.model || $0.fastID == selection.model
            }) {
                return rowID(group.provider.slug, family.id)
            }
        }
        return nil
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            if !editing { searchField }
            content
            footer
        }
        .background(theme.bg)
        .presentationDetents([.large])
        .presentationBackground(theme.bg)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: theme.id == .control ? 3 : 1) {
                if theme.showsKicker {
                    Text(editing ? copy.modelsEditKicker(theme.id) : copy.modelsKicker(theme.id))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(theme.id == .control ? 2.5 : 2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                titleText
                if !editing {
                    Text(currentLine)
                        .font(theme.mono(10))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(editing ? copy.modelsDone(theme.id) : copy.modelsClose(theme.id)) {
                if editing { editing = false } else { dismiss() }
            }
            .font(theme.id == .control ? theme.mono(11, weight: .bold)
                                       : theme.body(13, weight: .semibold))
            .foregroundStyle(theme.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var titleText: some View {
        let text = editing ? copy.modelsEditTitle(theme.id) : copy.modelsTitle(theme.id)
        switch theme.id {
        case .soft:
            Text(text).font(theme.body(26, weight: .heavy)).tracking(-0.5)
                .foregroundStyle(theme.ink)
        case .control:
            Text(text).font(theme.body(23, weight: .heavy)).tracking(-0.3)
                .foregroundStyle(theme.ink)
        case .ink:
            Text(text).font(theme.display(25).smallCaps()).tracking(0.5)
                .foregroundStyle(theme.ink)
        }
    }

    /// "Opus 4.8 · Fast Med — anthropic" — the same derivation the chat strip
    /// and the desktop status bar use.
    private var currentLine: String {
        let selection = current
        guard !selection.model.isEmpty else { return copy.modelsNoCurrent(theme.id) }
        let label = ModelLabels.statusLabel(model: selection.model,
                                            reasoningEffort: currentEffort,
                                            fastMode: currentFastControl.isOn)
        return selection.provider.isEmpty ? label : "\(label) — \(selection.provider)"
    }

    private var searchField: some View {
        TextField("", text: $query,
                  prompt: Text(copy.modelsSearchPlaceholder(theme.id)).foregroundStyle(theme.faint))
            .textFieldStyle(.plain)
            .font(inputFont)
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(.horizontal, 15)
            .frame(height: 42)
            .background(inputShape.fill(theme.panel))
            .overlay(inputShape.strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line,
                                             lineWidth: 1))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(theme.inputRadius, 21), style: .continuous)
    }

    private var inputFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5)
        case .control: theme.mono(13)
        case .ink: theme.body(15)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if editing {
            editList
        } else if !state.hasLoaded {
            // Before the first read completes there is nothing honest to say
            // about this gateway's providers — so say we're still reading,
            // never "no providers".
            statusBlock {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(copy.modelsLoading(theme.id))
                        .font(theme.mono(11))
                        .foregroundStyle(theme.faint)
                }
            }
        } else if let error = state.loadError, !state.catalog.hasSelectableModels {
            statusBlock {
                VStack(spacing: 12) {
                    Text(copy.modelsLoadFailed(theme.id))
                        .font(theme.body(theme.id == .ink ? 15 : 13.5))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.sub)
                        .multilineTextAlignment(.center)
                    Text(error)
                        .font(theme.mono(10))
                        .foregroundStyle(theme.faint)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    ThemedPrimaryButton(theme: theme, title: copy.modelsRetry(theme.id),
                                        compact: true) {
                        Task { await model.loadModelCatalog(botID: botID, refresh: true) }
                    }
                    .frame(maxWidth: 220)
                }
            }
        } else if groups.isEmpty, moaPresets.isEmpty {
            statusBlock {
                VStack(spacing: 12) {
                    Text(emptyStateText)
                        .font(theme.body(theme.id == .ink ? 15 : 13.5))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.faint)
                        .multilineTextAlignment(.center)
                    // Hiding every model is a state the user made and can undo;
                    // "no models" would be a lie about the gateway.
                    if state.catalog.hasSelectableModels, query.isEmpty {
                        ThemedPrimaryButton(theme: theme, title: copy.modelsEdit(theme.id),
                                            compact: true) { editing = true }
                            .frame(maxWidth: 220)
                    }
                }
            }
        } else {
            catalogList
        }
    }

    /// Three different "nothing here" states, and they are not the same thing:
    /// the gateway has no providers, the query matched nothing, or the user
    /// hid every model in Edit Models.
    private var emptyStateText: String {
        guard state.catalog.hasSelectableModels else { return copy.modelsNoProviders(theme.id) }
        return query.isEmpty ? copy.modelsAllHidden(theme.id) : copy.modelsNoMatch(theme.id)
    }

    private func statusBlock<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack {
            Spacer(minLength: 24)
            inner()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.bottom, 40)
        .task { await loadIfNeeded() }
    }

    private var catalogList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.rowStyle == .ledger ? 0 : 6) {
                    if let pending = state.pendingConfirmation { confirmBanner(pending) }
                    if let notice = state.notice { noticeBanner(notice) }

                    ForEach(groups) { group in
                        sectionHeader(group.provider.name,
                                      detail: "\(group.provider.slug) · \(group.provider.totalModels)")
                        if !group.provider.warning.isEmpty {
                            providerWarning(group.provider.warning)
                        }
                        ForEach(group.families) { family in
                            modelRow(family, in: group.provider)
                                .id(rowID(group.provider.slug, family.id))
                        }
                        if !group.provider.unavailableModels.isEmpty {
                            Text(copy.modelsProNote(theme.id))
                                .font(theme.mono(9))
                                .foregroundStyle(theme.faint)
                                .padding(.top, 2)
                        }
                        if theme.rowStyle != .ledger { Color.clear.frame(height: 4) }
                    }

                    if !moaPresets.isEmpty { moaSection }

                    reasoningSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                await loadIfNeeded()
                await pinCurrentRow(proxy)
            }
        }
    }

    // MARK: Sections

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(theme.id == .soft ? title : title.uppercased())
                .font(theme.mono(theme.id == .soft ? 10 : 9.5, weight: .bold))
                .tracking(theme.id == .soft ? 1.2 : 2)
                .foregroundStyle(theme.id == .control ? theme.accent : theme.faint)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(theme.mono(9))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            if theme.id == .ink {
                Rectangle().fill(theme.lineStrong).frame(height: 1)
            }
        }
        .padding(.top, theme.rowStyle == .ledger ? 16 : 12)
        .padding(.bottom, theme.rowStyle == .ledger ? 6 : 2)
    }

    private func providerWarning(_ text: String) -> some View {
        Text(text)
            .font(theme.mono(9.5))
            .foregroundStyle(theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.warn.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 8))
            .padding(.bottom, 3)
    }

    private var moaSection: some View {
        Group {
            sectionHeader(copy.modelsMoASection(theme.id))
            ForEach(moaPresets, id: \.self) { preset in
                let isCurrent = current.provider == "moa" && current.model == preset
                Button {
                    Task { await select(provider: "moa", model: preset) }
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: "MoA: \(preset)")
                            .font(rowNameFont)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if isCurrent { checkmark }
                    }
                    .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ModelRowChrome(theme: theme, selected: isCurrent))
            }
        }
    }

    // MARK: Model row

    private func modelRow(_ family: ModelFamily, in provider: ModelProviderRow) -> some View {
        let selection = current
        // The active id may be the base or its `-fast` sibling; either way this
        // one family row represents both.
        let isCurrent = provider.owns(provider: selection.provider)
            && (selection.model == family.id || selection.model == family.fastID)
        let parts = ModelLabels.displayParts(family.id)
        let caps = provider.capabilities(for: family.id)
        let preset = ModelPresetStore.shared.preset(provider: provider.slug, model: family.id)

        // Effective settings for this row: the live choice when it's the active
        // model, otherwise its remembered preset — so the label and the control
        // below can never disagree.
        let effort = isCurrent ? currentEffort : (preset.effort ?? "")
        let fast = isCurrent ? currentFastControl.isOn : (preset.fast ?? false)
        let fastControl = ModelLabels.fastControl(model: isCurrent ? selection.model : family.id,
                                                  providerModels: provider.models,
                                                  paramSupported: caps.fast,
                                                  fastMode: fast)
        let status = ModelLabels.rowStatusLabel(fastOn: fastControl.isOffered && fastControl.isOn,
                                                reasoningSupported: caps.reasoning,
                                                effort: effort)
        let locked = provider.unavailableModels.contains(family.id)
        let price = provider.pricing[family.id]
        let busy = state.busyRow == rowID(provider.slug, family.id)

        return Button {
            guard !locked else { return }
            Task { await selectFamily(family, in: provider) }
        } label: {
            HStack(spacing: 8) {
                Text(parts.name)
                    .font(rowNameFont)
                    .foregroundStyle(locked ? theme.faint : theme.ink)
                    .lineLimit(1)
                if !parts.tag.isEmpty {
                    Text(parts.tag)
                        .font(theme.mono(9, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(theme.mono(9.5))
                        .foregroundStyle(theme.faint)
                }
                Spacer(minLength: 6)
                if let price, !price.isEmpty {
                    ModelPricePresentation(price: price, theme: theme, copy: copy)
                }
                if locked {
                    Text(copy.modelsProBadge(theme.id))
                        .font(theme.mono(8.5, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.faint)
                }
                if busy {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    checkmark
                }
            }
            .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .modifier(ModelRowChrome(theme: theme, selected: isCurrent))
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.accent)
    }

    private var rowNameFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.mono(12.5, weight: .semibold)
        case .ink: theme.mono(12, weight: .semibold)
        }
    }

    // MARK: Reasoning + fast

    /// The controls the desktop hides in a per-row hover submenu. They act on
    /// the ACTIVE model, gated by its capabilities row — a knob the backend
    /// would reject is not offered.
    @ViewBuilder private var reasoningSection: some View {
        if currentCapabilities.reasoning || currentFastControl.isOffered {
            sectionHeader(copy.modelsReasoningSection(theme.id))

            if currentCapabilities.reasoning {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 7)],
                          alignment: .leading, spacing: 7) {
                    effortChip("none")
                    ForEach(ModelLabels.reasoningEfforts, id: \.self) { effortChip($0) }
                }
                .padding(.top, 2)
            }

            if currentFastControl.isOffered { fastRow }

            Text(copy.modelsDeferHint(theme.id))
                .font(theme.body(11))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    /// Which chip reads as selected: `none` when thinking is off, otherwise the
    /// resolved level (empty inherits the profile default).
    private var selectedEffort: String {
        ModelLabels.isThinkingEnabled(currentEffort)
            ? ModelLabels.resolveEffort(currentEffort)
            : "none"
    }

    private func effortChip(_ effort: String) -> some View {
        let on = selectedEffort == effort
        return Button {
            Task {
                await model.setReasoningEffortWithFeedback(
                    botID: botID, effort: effort,
                    provider: current.provider, model: current.model)
            }
        } label: {
            Text(ModelLabels.effortLabel(effort))
                .font(theme.mono(10.5, weight: .semibold))
                .foregroundStyle(on ? theme.accentFg : theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.inset),
                            in: RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999
                                                                                   : theme.buttonRadius))
                .overlay {
                    if !on {
                        RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999 : theme.buttonRadius)
                            .stroke(theme.line, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Fast is two different mechanisms: the `speed=fast` request parameter, or
    /// a separate `…-fast` model id. The toggle hides that split.
    @ViewBuilder private var fastRow: some View {
        let control = currentFastControl
        HStack(spacing: 8) {
            Text(copy.modelsFast(theme.id))
                .font(theme.mono(11, weight: .semibold))
                .foregroundStyle(theme.ink)
            if case .variant = control {
                Text(copy.modelsFastVariant(theme.id))
                    .font(theme.mono(9))
                    .foregroundStyle(theme.faint)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { control.isOn },
                                     set: { enabled in Task { await setFast(enabled, control) } }))
                .labelsHidden()
                .tint(theme.accent)
        }
        .padding(.top, 10)
    }

    // MARK: Banners

    private func confirmBanner(_ pending: PendingModelConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(copy.modelsConfirmTitle(theme.id))
                .font(theme.mono(9.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.warn)
            Text(pending.message.isEmpty ? copy.modelsConfirmFallback(theme.id, model: pending.model)
                                         : pending.message)
                .font(theme.body(12.5))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ThemedPrimaryButton(theme: theme, title: copy.modelsConfirmGo(theme.id),
                                    compact: true) {
                    Task {
                        // Narrated: the user has answered the guard, so this
                        // switch is allowed an ending in the ledger too.
                        let result = await model.confirmModelSwitchWithFeedback(botID: botID)
                        announce(result)
                    }
                }
                ThemedSecondaryButton(theme: theme, title: copy.modelsConfirmStop(theme.id),
                                      compact: true) {
                    model.cancelPendingModel(botID: botID)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warn.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 10))
        .overlay(RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 10)
            .strokeBorder(theme.warn.opacity(0.45), lineWidth: 1))
        .padding(.top, 6)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(theme.mono(10))
                .foregroundStyle(state.noticeIsWarning ? theme.warn : theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button {
                state.clearNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((state.noticeIsWarning ? theme.warn : theme.accent).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 8))
        .padding(.top, 6)
    }

    // MARK: - Edit Models

    private var editList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.rowStyle == .ledger ? 0 : 6) {
                Text(copy.modelsEditHint(theme.id))
                    .font(theme.body(11.5))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                ForEach(state.catalog.modelProviders) { provider in
                    let families = ModelLabels.collapseFamilies(provider.models)
                    if !families.isEmpty {
                        editProviderHeader(provider, families: families)
                        ForEach(families) { family in
                            editRow(family, in: provider)
                        }
                        if theme.rowStyle != .ledger { Color.clear.frame(height: 4) }
                    }
                }

                Button {
                    visibility.reset()
                } label: {
                    Text(copy.modelsEditReset(theme.id))
                        .font(theme.mono(10, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 26)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func editProviderHeader(_ provider: ModelProviderRow,
                                    families: [ModelFamily]) -> some View {
        let visible = visibility.visibleKeys(providers: state.catalog.modelProviders)
        let allOn = families.allSatisfy {
            visible.contains(ModelVisibilityStore.key(provider: provider.slug, model: $0.id))
        }
        return HStack(spacing: 8) {
            Text(theme.id == .soft ? provider.name : provider.name.uppercased())
                .font(theme.mono(theme.id == .soft ? 10 : 9.5, weight: .bold))
                .tracking(theme.id == .soft ? 1.2 : 2)
                .foregroundStyle(theme.id == .control ? theme.accent : theme.faint)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                visibility.setProvider(state.catalog.modelProviders,
                                       provider: provider.slug, visible: !allOn)
            } label: {
                Text(allOn ? copy.modelsEditNone(theme.id) : copy.modelsEditAll(theme.id))
                    .font(theme.mono(9, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, theme.rowStyle == .ledger ? 16 : 12)
        .padding(.bottom, 2)
    }

    private func editRow(_ family: ModelFamily, in provider: ModelProviderRow) -> some View {
        let key = ModelVisibilityStore.key(provider: provider.slug, model: family.id)
        let on = visibility.visibleKeys(providers: state.catalog.modelProviders).contains(key)
        let parts = ModelLabels.displayParts(family.id)
        return Button {
            visibility.toggle(state.catalog.modelProviders,
                              provider: provider.slug, model: family.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? theme.accent : theme.faint)
                Text(parts.name)
                    .font(rowNameFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                if family.fastID != nil {
                    Text(copy.modelsFast(theme.id))
                        .font(theme.mono(9, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                Spacer(minLength: 6)
                Text(family.id)
                    .font(theme.mono(8.5))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ModelRowChrome(theme: theme, selected: false))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 6) {
                    if state.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(copy.modelsRefresh(theme.id))
                        .font(theme.mono(10, weight: .semibold))
                }
                .foregroundStyle(state.isRefreshing ? theme.faint : theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(state.isRefreshing)

            Spacer(minLength: 8)

            Button {
                query = ""
                editing.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .bold))
                    Text(editing ? copy.modelsDone(theme.id) : copy.modelsEdit(theme.id))
                        .font(theme.mono(10, weight: .semibold))
                }
                .foregroundStyle(theme.sub)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() async {
        guard !state.hasLoaded, !state.isLoading else { return }
        await model.loadModelCatalog(botID: botID)
    }

    private func refresh() async {
        await model.loadModelCatalog(botID: botID, refresh: true)
        if let error = state.loadError {
            state.note(error, warning: true)
        } else {
            state.note(copy.modelsRefreshed(theme.id, count: state.catalog.modelProviders.count))
        }
    }

    /// Open on the active model rather than the top of a long catalog.
    private func pinCurrentRow(_ proxy: ScrollViewProxy) async {
        guard !didPinCurrent, query.isEmpty, let target = currentRowID else { return }
        didPinCurrent = true
        // One frame for the rows to exist before we can scroll to one.
        try? await Task.sleep(for: .milliseconds(80))
        proxy.scrollTo(target, anchor: .center)
    }

    private func selectFamily(_ family: ModelFamily, in provider: ModelProviderRow) async {
        let result = await model.switchModelFamilyWithFeedback(
            botID: botID, provider: provider, family: family)
        announce(result)
    }

    private func select(provider: String, model modelID: String) async {
        // The wrapper adds the toast pair and the Activity row; `announce` keeps
        // the in-sheet line, which is the one visible over a sheet.
        let result = await model.switchModelWithFeedback(botID: botID, provider: provider,
                                                         model: modelID)
        announce(result)
    }

    private func setFast(_ enabled: Bool, _ control: ModelFastControl) async {
        switch control {
        case .none:
            return
        case .param:
            await model.applyFastMode(botID: botID, enabled: enabled,
                                      provider: current.provider, model: current.model)
        case .variant(let baseID, let fastID, _):
            // Fast is a separate model id here — swap to the sibling, and
            // remember the choice against the BASE model so re-selecting it
            // later restores the same tier.
            ModelPresetStore.shared.merge(provider: current.provider, model: baseID, fast: enabled)
            await select(provider: current.provider, model: enabled ? fastID : baseID)
        }
    }

    /// Turn a switch outcome into the one line the user needs. The deferred and
    /// confirm-required cases are the whole reason this exists: the previous
    /// picker dropped both on the floor and looked like it had worked.
    private func announce(_ result: ModelSelectionResult) {
        switch result {
        case .applied(let warning):
            if warning.isEmpty {
                state.clearNotice()
            } else {
                state.note(warning, warning: true)
            }
        case .deferred(let modelID):
            state.note(copy.modelsDeferred(theme.id, model: ModelLabels.displayName(modelID)))
        case .needsConfirmation:
            break   // the banner carries it
        case .failed(let detail):
            state.note(detail, warning: true)
        }
    }
}

/// Price and sale chrome are deliberately a vertical trailing group. A sale
/// must add context without replacing the provider, effort, price, lock, or
/// current-selection state already carried by the row.
struct ModelPricePresentation: View {
    let price: ModelPriceTag
    let theme: ThemePack
    let copy: CopyPack

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(price.compact)
                .font(theme.mono(9))
                .foregroundStyle(price.free ? theme.ok : theme.faint)
                .monospacedDigit()
            if let percent = price.boundedDiscountPercent {
                Text(copy.modelsDiscountBadge(theme.id, percent: percent))
                    .font(theme.mono(8.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.warn)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(theme.warn.opacity(0.1), in: Capsule())
                    .accessibilityLabel(Text(
                        copy.modelsDiscountAccessibility(theme.id, percent: percent)))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Row chrome

/// Floating card in soft, bordered terminal panel in control, ruled ledger line
/// in ink — the same three-way split every list in the app uses.
private struct ModelRowChrome: ViewModifier {
    let theme: ThemePack
    let selected: Bool

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .background(selected ? AnyShapeStyle(theme.accent.opacity(0.08))
                                     : AnyShapeStyle(theme.panel))
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(selected ? theme.accentFaint : theme.line, lineWidth: 1))
        case .terminal:
            content
                .background(selected ? AnyShapeStyle(theme.accent.opacity(0.12))
                                     : AnyShapeStyle(theme.panel))
                .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius)
                    .strokeBorder(selected ? theme.accent.opacity(0.7)
                                           : theme.lineStrong.opacity(0.8), lineWidth: 1))
        case .ledger:
            content
                .background(selected ? AnyShapeStyle(theme.accent.opacity(0.07))
                                     : AnyShapeStyle(Color.clear))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
        }
    }
}

// MARK: - Themed copy

/// Voice for the model picker. Gateway text (a provider's own `warning`, a
/// confirm message, an RPC error) is passed through verbatim — only what
/// Talaria itself says is themed.
public extension CopyPack {

    func modelsKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "MODEL PICKER"
        case .control: "MODEL BUS"
        case .ink: "THE HANDS AVAILABLE"
        }
    }

    func modelsTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Models"
        case .control: "Models"
        case .ink: "Hands"
        }
    }

    func modelsClose(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Done"
        case .control: "CLOSE"
        case .ink: "enough"
        }
    }

    func modelsDone(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Done"
        case .control: "DONE"
        case .ink: "so be it"
        }
    }

    func modelsSearchPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search models & providers…"
        case .control: "FILTER — provider, model, alias…"
        case .ink: "seek a hand…"
        }
    }

    func modelsNoCurrent(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No model chosen yet"
        case .control: "NO MODEL PINNED"
        case .ink: "no hand is engaged"
        }
    }

    func modelsLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reading the catalog…"
        case .control: "model.options…"
        case .ink: "counting the hands…"
        }
    }

    func modelsLoadFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway didn’t return a model catalog."
        case .control: "CATALOG UNAVAILABLE — model.options REFUSED."
        case .ink: "The gateway keeps no register of hands."
        }
    }

    func modelsRetry(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Try again"
        case .control: "RETRY"
        case .ink: "ask again"
        }
    }

    func modelsNoMatch(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No model matches."
        case .control: "NO MATCH."
        case .ink: "No hand answers to that name."
        }
    }

    /// The gateway has models; the user's own Edit Models set hid them all.
    func modelsAllHidden(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Every model is hidden. Edit your list to bring some back."
        case .control: "VISIBLE SET IS EMPTY — EDIT MODELS TO RESTORE."
        case .ink: "You have struck every hand from the roll."
        }
    }

    func modelsNoProviders(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No provider is configured on this gateway yet. Add one from the desktop app or `hermes model`."
        case .control: "NO AUTHENTICATED PROVIDERS — CONFIGURE VIA `hermes model`."
        case .ink: "No house has yet been engaged. Arrange it at the desk, or with `hermes model`."
        }
    }

    func modelsMoASection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "MoA presets"
        case .control: "MOA PRESETS"
        case .ink: "CONCLAVES"
        }
    }

    func modelsReasoningSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reasoning"
        case .control: "REASONING"
        case .ink: "DELIBERATION"
        }
    }

    func modelsFast(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Fast"
        case .control: "FAST"
        case .ink: "haste"
        }
    }

    /// Marks a fast toggle that swaps model ids rather than setting a param.
    func modelsFastVariant(_ t: ThemeID) -> String {
        switch t {
        case .soft: "separate model"
        case .control: "VARIANT ID"
        case .ink: "another hand"
        }
    }

    func modelsProBadge(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pro"
        case .control: "PRO"
        case .ink: "sealed"
        }
    }

    /// Compact visual sale marker. The fuller VoiceOver label below keeps a
    /// percent glyph from being read as an ambiguous piece of model identity.
    func modelsDiscountBadge(_ t: ThemeID, percent: Int) -> String {
        switch t {
        case .soft: "−\(percent)%"
        case .control: "−\(percent)%"
        case .ink: "−\(percent)%"
        }
    }

    func modelsDiscountAccessibility(_ t: ThemeID, percent: Int) -> String {
        switch t {
        case .soft: "\(percent) percent off list price"
        case .control: "\(percent) PERCENT OFF LIST PRICE"
        case .ink: "\(percent) percent below the listed price"
        }
    }

    func modelsProNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Dimmed models need a paid subscription with this provider."
        case .control: "DIMMED ROWS REQUIRE A PAID TIER."
        case .ink: "The sealed hands answer only to a subscription."
        }
    }

    func modelsRefresh(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Refresh models"
        case .control: "REFRESH MODELS"
        case .ink: "call the roll"
        }
    }

    func modelsRefreshed(_ t: ThemeID, count: Int) -> String {
        switch t {
        case .soft: "Catalog refreshed — \(count) provider\(count == 1 ? "" : "s")."
        case .control: "CATALOG REFRESHED — \(count) PROVIDER(S)."
        case .ink: "The roll is called: \(count) house\(count == 1 ? "" : "s") answer."
        }
    }

    func modelsEdit(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Edit models…"
        case .control: "EDIT MODELS…"
        case .ink: "choose the roll…"
        }
    }

    func modelsEditKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "VISIBLE MODELS"
        case .control: "CATALOG FILTER"
        case .ink: "THE CHOSEN ROLL"
        }
    }

    func modelsEditTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Edit models"
        case .control: "Edit Models"
        case .ink: "The roll"
        }
    }

    func modelsEditHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pick which models the list shows. Search still reaches every model, chosen or not."
        case .control: "SELECT THE VISIBLE SET. SEARCH STILL SPANS THE FULL CATALOG."
        case .ink: "Mark the hands you would see. A search still reaches them all."
        }
    }

    func modelsEditAll(_ t: ThemeID) -> String {
        switch t {
        case .soft: "All"
        case .control: "ALL"
        case .ink: "every one"
        }
    }

    func modelsEditNone(_ t: ThemeID) -> String {
        switch t {
        case .soft: "None"
        case .control: "NONE"
        case .ink: "none"
        }
    }

    func modelsEditReset(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reset to the suggested models"
        case .control: "RESET TO DEFAULTS"
        case .ink: "restore the customary roll"
        }
    }

    /// The gateway stashed a mid-turn switch: it applies at the next turn.
    func modelsDeferred(_ t: ThemeID, model: String) -> String {
        switch t {
        case .soft: "\(model) applies when this turn settles — the running turn keeps its model."
        case .control: "SWITCH DEFERRED — \(model.uppercased()) APPLIES AT NEXT TURN START."
        case .ink: "\(model) takes the work when this turn is done; the present one runs on."
        }
    }

    func modelsConfirmTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "CONFIRM THIS MODEL"
        case .control: "CONFIRM REQUIRED"
        case .ink: "A WORD BEFORE YOU DO"
        }
    }

    func modelsConfirmFallback(_ t: ThemeID, model: String) -> String {
        switch t {
        case .soft: "\(model) is an expensive model. Switch anyway?"
        case .control: "\(model.uppercased()) — COST GUARD. PROCEED?"
        case .ink: "\(model) does not come cheap. Engage it?"
        }
    }

    func modelsConfirmGo(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Switch anyway"
        case .control: "PROCEED"
        case .ink: "engage it"
        }
    }

    func modelsConfirmStop(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Keep current"
        case .control: "ABORT"
        case .ink: "leave it be"
        }
    }

    func modelsDeferHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reasoning and fast apply to the next turn. A model switch made mid-turn is held until the running turn settles."
        case .control: "REASONING/FAST APPLY NEXT TURN. MID-TURN MODEL SWITCHES ARE HELD UNTIL THE TURN SETTLES."
        case .ink: "Deliberation and haste take effect with the next turn; a change of hands mid-work waits for the work to end."
        }
    }
}
