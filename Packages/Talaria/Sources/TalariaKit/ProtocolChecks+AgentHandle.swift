import Foundation

// The duplicate-name rule — `@name-device` — minted, and parsed back.
//
// The form is built in apps/desktop/electron/connection-registry.ts
// (`labelSlug` :121-129, `agentHandle` :137-141, `buildAgentRoster` :336-372)
// and consumed in plugin.js (`botHandle` 2406-2412, `resolveRosterMentions`
// 2434-2497). Talaria has to do BOTH ends, and they have to agree: a handle
// this app mints must be a handle this app resolves, or the escape hatch the
// ambiguity refusal points at ("use its @name-device handle") leads nowhere.
//
// So the centrepiece here is a round trip, not a pair of unit checks — build a
// two-gateway roster the way the app builds it, then feed every handle it
// minted back through the resolver and require the SAME row out.
//
// The three that have a wrong version which looks right:
//
//   * The suffix lands on BOTH sides (connection-registry.ts:362-370 stamps
//     every colliding identity, plugin.js:2334 annotates the active-source row
//     with it). Suffixing only the far side leaves the near one answering to a
//     bare name it no longer owns.
//   * The precomputed handle beats the default→hermes alias (2407 returns
//     before 2411). Two gateways with `default` give `@default-macbook` and
//     `@default-homelab`; `@hermes` then addresses NOBODY, and that is correct.
//   * The bare form is registered by every row (2445) — that is what poisons
//     it. Registering the source-qualified key instead would leave the two
//     rows sharing nothing, and `@default` would silently reach whichever
//     gateway happened to be live.

extension ProtocolChecks {

    static func agentHandleRules() throws {
        try labelSlugging()
        try duplicateCounting()
        try nameDeviceRoundTrip()
        try nameDeviceSurfaces()
        try remoteDefaultNaming()
    }

    // MARK: labelSlug (connection-registry.ts:121-129)

    private static func labelSlugging() throws {
        try expect(AgentHandle.labelSlug("MacBook") == "macbook", "lowercased")
        try expect(AgentHandle.labelSlug("Home Lab") == "home-lab", "spaces become one hyphen")
        try expect(AgentHandle.labelSlug("  Mac — Book!!  ") == "mac-book",
                   "every run of non-alphanumerics collapses to ONE hyphen, ends trimmed")
        try expect(AgentHandle.labelSlug("studio_2") == "studio-2",
                   "underscore is not alphanumeric — it slugs to a hyphen")
        try expect(AgentHandle.labelSlug("Café") == "caf",
                   "non-ASCII is not [a-z0-9] — it slugs to a hyphen, which the trim then eats")
        try expect(AgentHandle.labelSlug("Café Mini") == "caf-mini",
                   "…but a hyphen INSIDE the slug survives, so two labels can differ by "
                   + "an accent alone and still mint different handles")

        // Empty is the one case with a literal fallback — never an empty
        // suffix, which would mint the bare name back and un-disambiguate.
        try expect(AgentHandle.labelSlug("") == "connection", "empty label has a name")
        try expect(AgentHandle.labelSlug("!!!") == "connection", "so does an all-punctuation one")
        try expect(AgentHandle.labelSlug("   ") == "connection", "and a whitespace-only one")

        // The 48-char cap is applied LAST — after the hyphen trim, not before
        // — so a long label may end in a hyphen. That is upstream's order
        // (`.slice(0, 48)` is the final call) and it has to be reproduced
        // exactly, because both machines mint the same string or the handle
        // stops round-tripping.
        let long = AgentHandle.labelSlug(String(repeating: "ab ", count: 30))
        try expect(long.count == 48, "slug is capped at 48 chars")
        try expect(long.hasSuffix("-"), "the cap runs AFTER the hyphen trim, not before")
    }

    // MARK: Who is duplicated (connection-registry.ts:341-358)

    private static func duplicateCounting() throws {
        try expect(AgentHandle.duplicatedNames(across: [["default", "ops"], ["default", "ci"]])
                    == ["default"], "a name on two sources is duplicated; unique ones are not")
        try expect(AgentHandle.duplicatedNames(across: [["ops"], ["ci"]]).isEmpty,
                   "no collision, no suffix — the single-gateway phone is untouched")

        // Deduped PER SOURCE first (:341-352). A gateway that reports the same
        // profile twice — or a connection reconciling into the list twice —
        // must not be able to invent a collision and rename a bot nothing else
        // claims.
        try expect(AgentHandle.duplicatedNames(across: [["ops", "ops", "ops"]]).isEmpty,
                   "one source repeating a profile is NOT a duplicate (:341-352)")

        // Nameless rows are the primary profile, not an error (:345).
        try expect(AgentHandle.duplicatedNames(across: [["", "ops"], ["default"]])
                    == ["default"], "a blank profile name counts as `default`")

        // The mint itself.
        try expect(AgentHandle.mint(profile: "ops", connectionLabel: "Home Lab",
                                    duplicated: false) == "ops",
                   "a unique profile keeps its bare name")
        try expect(AgentHandle.mint(profile: "ops", connectionLabel: "Home Lab",
                                    duplicated: true) == "ops-home-lab",
                   "a duplicated one is <profile>-<label-slug>: a bare hyphen join, "
                   + "not @name@device and not a colon")
        try expect(AgentHandle.mint(profile: "  ", connectionLabel: "Home Lab",
                                    duplicated: true) == "default-home-lab",
                   "the profile half is normalised first")
    }

    // MARK: The round trip

    /// Two gateways, both carrying `default`. This is the shape Phase E makes
    /// real; the point of pinning it now is that the FORM has to be right
    /// before there is anything to be wrong about.
    ///
    /// The rows are built the way the app builds them — `AppModel.liveRosterBots`
    /// annotates live rows in place, `AppModel.rosterBot(for:)` turns a foreign
    /// entry into a `Bot` — but from the pure rule, because `talaria-verify`
    /// links TalariaKit alone.
    private static func nameDeviceRoster() -> (live: [Bot], union: [Bot]) {
        let liveLabel = "MacBook"
        let farLabel = "Home Lab"
        let liveNames = ["default", "ops"]
        let farNames = ["default", "ci"]
        let duplicated = AgentHandle.duplicatedNames(across: [liveNames, farNames])

        // The live half: annotate in place, and ONLY when the name collides
        // (plugin.js:2332-2334).
        let live: [Bot] = liveNames.map { name in
            Bot(id: name, job: "", shape: .circle, hue: .teal,
                handleOverride: duplicated.contains(name)
                    ? AgentHandle.mint(profile: name, connectionLabel: liveLabel,
                                       duplicated: true)
                    : nil)
        }

        // The far half: thin rows keyed by `botRosterKey` (2669), carrying the
        // bare name and the label in `remoteSource`.
        let far: [Bot] = farNames.map { name in
            let handle = AgentHandle.mint(profile: name, connectionLabel: farLabel,
                                          duplicated: duplicated.contains(name))
            return Bot(id: "home-lab::\(name)", job: "", shape: .circle, hue: .teal,
                       handleOverride: handle,
                       remoteSource: BotSource(profile: name, gatewayID: "home-lab",
                                               connectionLabel: farLabel))
        }
        return (live, live + far)
    }

    private static func nameDeviceRoundTrip() throws {
        let (_, union) = nameDeviceRoster()

        // What each row is called.
        try expect(union.map(\.handle) == ["default-macbook", "ops", "default-home-lab", "ci"],
                   "BOTH colliding sides get the suffix; unique rows keep their bare name")
        try expect(union.first?.handle == "default-macbook",
                   "the precomputed handle beats the default→hermes alias (2407 before 2411)")

        // THE ROUND TRIP. Every handle this roster minted resolves back to the
        // row that minted it — no exceptions, including the two that differ
        // only by their device suffix.
        for bot in union {
            let back = MentionResolver.resolve("@\(bot.handle) ping", roster: union, speaking: nil)
            try expect(back.bots.map(\.id) == [bot.id],
                       "@\(bot.handle) round-trips to exactly the row that minted it")
        }

        // The bare form does NOT resolve when duplicated: collision poisoning
        // protects the two default profiles rather than treating `default` as
        // a globally reserved legacy handle.
        let bare = MentionResolver.resolve("@default ping", roster: union, speaking: nil)
        try expect(bare.bots.isEmpty && bare.ambiguous == ["default"],
                   "the duplicated bare default name resolves to nobody")

        // `@hermes` addresses nobody once `default` is duplicated. This looks
        // like a regression and is the rule: `botHandle` returns the
        // precomputed handle at 2407 and never reaches the alias at 2411, so
        // no row registers `hermes` as a form.
        let alias = MentionResolver.resolve("@hermes ping", roster: union, speaking: nil)
        try expect(alias.bots.isEmpty && alias.unknown == ["hermes"],
                   "@hermes addresses NOBODY when `default` exists on two sources")

        // A unique legacy default/hermes identity remains addressable.
        let solo = [Bot(id: "default", job: "", shape: .circle, hue: .teal),
                    Bot(id: "home-lab::ci", job: "", shape: .circle, hue: .teal,
                        handleOverride: "ci",
                        remoteSource: BotSource(profile: "ci", gatewayID: "home-lab",
                                                connectionLabel: "Home Lab"))]
        try expect(solo.map(\.handle) == ["hermes", "ci"],
                   "no collision, no suffix — and `default` is still @hermes")
        try expect(MentionResolver.resolve("@hermes ping", roster: solo, speaking: nil)
                    .bots.map(\.id) == ["default"], "the unique legacy alias resolves")
        try expect(MentionResolver.resolve("@ci ping", roster: solo, speaking: nil)
                    .bots.map(\.id) == ["home-lab::ci"],
                   "a unique foreign row is addressable by its bare name (2445)")

        // Excluding one source releases the other unique legacy default form.
        let speaking = MentionResolver.resolve("@default ping", roster: union, speaking: "default")
        try expect(speaking.bots.map(\.id) == ["home-lab::default"],
                   "excluding the live speaker leaves the foreign default route")

        // A qualified secondary speaker similarly leaves the primary row.
        let farSpeaking = MentionResolver.resolve("@default ping", roster: union,
                                                  speaking: "home-lab::default")
        try expect(farSpeaking.bots.map(\.id) == ["default"],
                   "a qualified speaker excludes itself without blocking the primary")
    }

    // MARK: What the surfaces do with it

    private static func nameDeviceSurfaces() throws {
        let (live, union) = nameDeviceRoster()

        // The bare name is what a gateway call accepts; the id is not.
        let far = union.last { $0.remoteSource != nil }
        try expect(far?.id == "home-lab::ci", "a foreign row is keyed by botRosterKey (2669)")
        try expect(far?.profileName == "ci", "…and still knows the profile name it answers to")
        try expect(live.first?.profileName == "default", "a live row's profile name IS its id")

        // Display name de-slugs the PROFILE, not the key (8033) — and a
        // foreign `default` takes its device label before anything else
        // (2941-2943); `remoteDefaultNaming` below is where that rule lives.
        let farDefault = union.first { $0.id == "home-lab::default" }
        try expect(farDefault?.displayTitle == "Home Lab",
                   "a foreign `default` reads its device label, not `Home-lab::default` "
                   + "and not a second `Hermes` (2941-2943)")

        // Completion: prefix on the handle alone, and the meta line's tail is
        // the ROW's label (8034). The display half of the far row is that same
        // label, so the two `default` rows read as two different machines
        // rather than as `Bot · Hermes` twice.
        let offered = union.mentionSuggestions(for: "default-", speaking: nil,
                                               connectionLabel: "MacBook")
        try expect(offered.map(\.handle) == ["default-macbook", "default-home-lab"],
                   "a legacy-handle match does not synthesize a rename alias from a device label")
        try expect(offered.first?.meta == "Bot · Hermes · MacBook",
                   "a live row takes the array's label, and still reads Hermes")
        try expect(offered.last?.meta == "Bot · Home Lab · Home Lab",
                   "a foreign `default` names its machine in BOTH slots (2941 + 8034)")
        try expect(union.mentionSuggestions(for: "hermes", speaking: nil).isEmpty,
                   "…and the alias is not offered either, because no row answers to it")

        // Search: the fourth match field is the device label (2976), and a
        // foreign row supplies its own.
        try expect(farDefault?.matchesRosterSearch("home lab") == true,
                   "typing the device name finds the bots living on it")
        try expect(farDefault?.matchesRosterSearch("default-home") == true,
                   "so does a half-typed @name-device handle")
        try expect(live.first?.matchesRosterSearch("home lab") == false,
                   "…and does not drag the live gateway's rows in with them")

        // The consequence rule 1 exists for, on the search field. Field 1 of
        // the far row is its device label (2971 → 2941) and field 3 is its
        // `@name-device` handle (2973), so the alias reaches neither: typing
        // "hermes" finds THIS machine's primary agent and not the other one's.
        try expect(farDefault?.matchesRosterSearch("hermes") == false,
                   "`hermes` does not return the far machine's primary agent as well")
        try expect(live.first?.matchesRosterSearch("hermes") == true,
                   "…and still returns the near one, by the name its row reads")

        // The middleware identifies both halves without dispatching either.
        let near = MentionMiddleware.route("@default-macbook ship it", roster: union,
                                           speaking: "ops")
        try expect(near.recipients.map(\.id) == ["default"], "a live row is identified")
        try expect(near.unreachable.isEmpty, "…with nothing left over")
        try expect(near.text.contains("@default-macbook"),
                   "the note names it by the handle that was typed")

        let farOnly = MentionMiddleware.route("@default-home-lab ship it", roster: union,
                                              speaking: "ops")
        try expect(farOnly.recipients.map(\.id) == ["home-lab::default"],
                   "a row on another gateway keeps its exact identity")
        try expect(farOnly.unreachable.isEmpty, "…with nothing stranded")
        try expect(farOnly.text.hasSuffix("say so.]"),
                   "and the identification-only note is appended")

        let both = MentionMiddleware.route("@default-macbook and @default-home-lab go",
                                           roster: union, speaking: "ops")
        try expect(both.recipients.map(\.id) == ["default", "home-lab::default"],
                   "both source-qualified identities remain resolved")
        try expect(both.unreachable.isEmpty, "and neither is stranded")
        try expect(both.text.hasSuffix("say so.]"), "the note is still appended, unmangled")

        // Both exact handles are named as inert roster metadata.
        let note = both.text.dropFirst("@default-macbook and @default-home-lab go".count)
        try expect(note.contains("@default-home-lab"), "the remote identity is named")
        try expect(note.contains("@default-macbook"), "…and the primary identity is named")
    }

    // MARK: displayName rule 1 — a foreign `default` is named by its machine

    /// `displayName`'s FIRST rule (plugin.js:2941-2943), and the surfaces that
    /// inherit it. Pinned apart from the round trip because this is the one
    /// identity rule with a regression already in its history: upstream keys
    /// it off `remoteSource` and pointedly not off `sourceScoped`, because the
    /// version that keyed off `sourceScoped` renamed users' OWN main agent to
    /// an IP-derived label (community report, Aug 17 2026). Both directions
    /// are asserted below, because each is one condition away from the other.
    ///
    /// Without the rule, a phone bound to "MacBook" that also knows a saved
    /// "Home Lab" paints `Hermes` twice — and search, the roster and the
    /// @-completion meta line all inherit the collision.
    private static func remoteDefaultNaming() throws {
        // A thin foreign row as `AppModel.rosterBot(for:)` builds one: the
        // source-qualified id (2669), the bare name and the device label in
        // `remoteSource`, and the handle already resolved — an undisambiguated
        // `default` answers to @hermes, a duplicated one to `@name-device`.
        func far(_ name: String, handle: String, title: String? = nil,
                 label: String = "Home Lab") -> Bot {
            Bot(id: "home-lab::\(name)", job: "", shape: .circle, hue: .teal,
                title: title, handleOverride: handle,
                remoteSource: BotSource(profile: name, gatewayID: "home-lab",
                                        connectionLabel: label))
        }
        func live(_ name: String, title: String? = nil, handle: String? = nil) -> Bot {
            Bot(id: name, job: "", shape: .circle, hue: .teal,
                title: title, handleOverride: handle)
        }

        try expect(far("default", handle: "hermes").displayTitle == "Home Lab",
                   "a foreign `default` reads its device label (2941-2943)")

        // The regression guard, in the direction it actually failed.
        try expect(live("default").displayTitle == "Hermes",
                   "the live gateway's own `default` still reads Hermes — the rule keys off "
                   + "remoteSource, never off having been annotated with a source")
        try expect(live("default", handle: "default-macbook").displayTitle == "Hermes",
                   "…including once it HAS been annotated with a @name-device handle, which "
                   + "is exactly the row `sourceScoped` would have caught")

        // Scoped to the primary profile. Every other foreign row de-slugs its
        // own name, exactly as it would at home (rule 4).
        try expect(far("ops", handle: "ops").displayTitle == "Ops",
                   "a foreign `ops` is still Ops, not the machine it lives on")
        try expect(far("press-office", handle: "press-office").displayTitle == "Press Office",
                   "…and the de-slug/title-case still applies to it")

        // `&& bot.connectionLabel` (2941). A source with no usable label has
        // nothing to rename the row TO, so it falls through to rule 3 rather
        // than painting a blank name.
        try expect(far("default", handle: "hermes", label: "").displayTitle == "Hermes",
                   "a labelless source cannot rename the row")
        try expect(far("default", handle: "hermes", label: "   ").displayTitle == "Hermes",
                   "…and a whitespace-only label is no label")

        // PRECEDENCE, and it is a decision rather than a derivation — pinned
        // so that flipping it has to be deliberate. Upstream returns at 2941
        // BEFORE the meta.title check at 2949, but cannot reach the case where
        // the two disagree: `botRosterMeta` hands a remote row a null meta
        // (2717-2719) and a thin row is pushed with no title field at all
        // (2349-2356). Talaria's foreign rows DO carry the far gateway's
        // ui_meta title, so the case is reachable here, and the order upstream
        // wrote is what is kept.
        try expect(far("default", handle: "hermes", title: "Ops").displayTitle == "Home Lab",
                   "the device label outranks a title on a foreign `default` (2941 before 2949)")
        try expect(live("default", title: "Ops").displayTitle == "Ops",
                   "…while a title on the LIVE default still wins (2949)")
        try expect(far("ops", handle: "ops", title: "Deploys").displayTitle == "Deploys",
                   "…and so does a title on any other foreign row")

        // The label has to survive to the screen. `TalariaVoice.displayName`
        // collapses a row whose display name and handle agree down to
        // "@handle" (Components/ScreenHeader.swift:318), so `showsHandle`
        // staying true here is what keeps the device label visible in the soft
        // and control packs rather than a second bare `@hermes`.
        try expect(far("default", handle: "hermes").showsHandle,
                   "a foreign `default` renders `Home Lab @hermes` — the label is the name, "
                   + "and the handle is one the row really answers to")

        // SEARCH FOLLOWS THE PAINT (2971-2976 read the same helpers the row
        // renders with). Typing what the row says finds the row.
        let row = far("default", handle: "hermes")
        try expect(row.matchesRosterSearch("home lab"),
                   "the device label is field 1 here as well as field 4")
        try expect(row.matchesRosterSearch("hermes"),
                   "an undisambiguated foreign `default` is still found by the @handle it "
                   + "paints (2973 → botHandle's alias)")
        try expect(row.matchesRosterSearch("default"),
                   "and by its raw profile name, which is field 2 (2972)")
        try expect(!row.matchesRosterSearch("home-lab::"),
                   "…but never by the source-qualified id, which no row prints (2669)")
    }
}
