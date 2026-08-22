import Foundation

// A bot's face, pinned to the wire.
//
// This check exists because of a regression that shipped and was visible on a
// real device: the roster painted correctly on a cold launch and then, about
// eight seconds later, changed identity — bots swapping shape and colour, one
// swapping colour alone, two keeping both. Nothing about the gateway's answer
// had changed. Current Hermes a4f16e3f returns cosmetics in `ui_meta` alongside
// independent `last_session` activity and `canonical_session` identity. The
// rows below retain those current fields while varying everything that must
// not affect a face.
//
// The cause was two code paths where there should have been one. A roster map
// owned cosmetics; a separate signals ingest owned `has_avatar`, recency and
// liveness; they ran on different ticks, and the second one's arrival swapped
// every row's renderer. So there are three invariants here — the two halves of
// that bug, and the second door onto the same symptom:
//
//   1. RESOLUTION IS A PURE FUNCTION OF THE ROW — of `ui_meta` and `name`, and
//      of nothing else. Not `has_avatar`, not the session stamps, not the row's
//      position in the answer. `rosterRefresh()` below moves every one of those
//      and requires the faces to hold still.
//   2. STORED COSMETICS OUTRANK THE HASH, ALWAYS, AND LAND ON A KNOWN FACE.
//      The name hash is a placeholder for a profile nobody has dressed. It must
//      never be able to replace a shape or colour a human actually chose — for
//      any word in desktop's shape vocabulary or any entry in its palette, each
//      pinned to the literal silhouette and hue it has to produce.
//   3. THE WRITE TABLES ARE THE READ TABLE'S INVERSE. A look picked on the
//      phone is painted locally and then re-read off the next poll. A word that
//      writes one way and reads back another paints the pick on the tap and a
//      different face seconds later — the same user-visible symptom, reached
//      through the one path rather than around it.
//
// Plus the guard that made the avatars flip in the first place: a 160×160 PNG
// is the roster backfill's own rasterized copy of the live vector face
// (plugin.js:374-391), and displaying it back is what replaced five animated
// faces with five stills.

extension ProtocolChecks {

    /// The real `default` row: desktop cosmetics that DISAGREE with the name
    /// hash on both axes, which is what makes it a discriminating case.
    /// `stableHash("default")` lands on hexagon/amber; the block says
    /// squircle/#8b5cf6.
    private static let customisedRow = """
    {"name":"default","path":"/Users/administrator/.hermes","is_default":true,
     "model":"gpt-5.6-sol","provider":"openai-codex","description":"","skill_count":125,
     "last_session":{"id":"20260815_133046_e88359","title":"Find new bot option in Hermes",
                     "preview":"Message sent to **@ez-qa** with the full GitHub migration brief.",
                     "started_at":1786818646.81803,"last_active":1787078093.2499032,
                     "message_count":132},
     "canonical_session":{"id":"canonical-root","resolved_id":"canonical-tip",
                          "root_title":"Bot Chat","title":"Bot Chat",
                          "last_active":1787078000,"message_count":12},
     "ui_meta":{"hermes-bots":{"shape":"squircle","color":"#8b5cf6","imageKind":"shape",
                               "title":"Skynet","custom":true}},
     "has_avatar":true}
    """

    /// The SAME profile as it comes back on the ten-second poll: `has_avatar`
    /// has flipped, newest activity moved on, and the canonical registry tip
    /// advanced. Every field the second code path used to arrive carrying —
    /// and not one of them an input to a face.
    private static let refreshedRow = """
    {"name":"default","path":"/Users/administrator/.hermes","is_default":true,
     "model":"gpt-5.6-sol","provider":"openai-codex","description":"","skill_count":125,
     "last_session":{"id":"20260815_133046_e88359","title":"Find new bot option in Hermes",
                     "preview":"Pushed the branch.","started_at":1786818646.81803,
                     "last_active":1787078514.9901221,"message_count":134},
     "canonical_session":{"id":"canonical-root","resolved_id":"canonical-tip-2",
                          "root_title":"Bot Chat","title":"Bot Chat (continued)",
                          "last_active":1787078510,"message_count":14},
     "ui_meta":{"hermes-bots":{"shape":"squircle","color":"#8b5cf6","imageKind":"shape",
                               "title":"Skynet","custom":true}},
     "has_avatar":false}
    """

    /// The same profile with its `ui_meta` gone — a gateway that cannot store
    /// it, or a client that dropped it on the way in. This is the shape the
    /// regression took, and section 2 uses it to prove the fixture can tell the
    /// difference at all.
    private static let strippedRow = """
    {"name":"default","path":"/Users/administrator/.hermes","is_default":true,
     "skill_count":125,"has_avatar":true}
    """

    /// A current `hermes-bots` block that carries no cosmetics. Canonical chat
    /// identity lives outside metadata, so the name hash is the honest answer.
    private static let emptyBlockRow = """
    {"name":"code-review","path":"/Users/administrator/.hermes/profiles/code-review",
     "is_default":false,"skill_count":104,"last_session":null,
     "canonical_session":{"id":"review-root","resolved_id":"review-tip",
                          "root_title":"Bot Chat","title":"Bot Chat"},
     "ui_meta":{"hermes-bots":{}},
     "has_avatar":true}
    """

    private static func rosterRow(_ json: String) throws -> HermesProfile {
        HermesProfile(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    /// One roster answer resolved the way the roster builder resolves it:
    /// every row, name → face. Keyed rather than ordered, because row order is
    /// one of the things a face must not depend on.
    private static func faces(_ profiles: [HermesProfile]) -> [String: String] {
        var out: [String: String] = [:]
        for profile in profiles {
            out[profile.name] = BotCosmetics.shape(for: profile).rawValue
                + "/" + BotCosmetics.hue(for: profile).rawValue
        }
        return out
    }

    static func rosterCosmeticsSurviveRefresh() throws {
        // 1. Desktop's block wins outright, and beats the hash on both axes.
        let custom = try rosterRow(customisedRow)
        try expect(BotCosmetics.shape(for: custom) == .squircle,
                   "ui_meta[hermes-bots].shape wins over the name hash")
        try expect(BotCosmetics.hue(for: custom) == .violet,
                   "ui_meta[hermes-bots].color wins over the name hash")
        try expect(BotCosmetics.derivedShape(forName: "default") == .hexagon
                    && BotCosmetics.derivedHue(forName: "default") == .amber,
                   "and the hash it beats really is a different face, or this proves nothing")

        try rosterRefresh()

        // 3. A block that exists but carries no cosmetics is not cosmetics.
        //    Canonical session identity is a sibling wire field, so the hash
        //    is honest — and it, too, has to be stable across refreshes.
        let emptyBlock = try rosterRow(emptyBlockRow)
        try expect(BotCosmetics.storedShape(for: emptyBlock) == nil
                    && BotCosmetics.storedHue(for: emptyBlock) == nil,
                   "an empty hermes-bots block stores no cosmetics")
        try expect(BotCosmetics.shape(for: emptyBlock) == BotCosmetics.derivedShape(forName: "code-review")
                    && BotCosmetics.hue(for: emptyBlock) == BotCosmetics.derivedHue(forName: "code-review"),
                   "with nothing stored, the name hash is the last resort")
        // The block is still PRESENT. Nil means "no gateway ui_meta at all";
        // an empty current block remains an authoritative absence of cosmetics.
        try expect(BotModeMeta(uiMeta: emptyBlock.uiMeta) != nil,
                   "a present empty current block remains distinguishable from no block")
        try expect(BotModeMeta(uiMeta: nil) == nil, "no ui_meta means no block")

        // Roster hide is its own explicit, cross-device boolean. An omitted
        // key remains the additive default, while unhide must serialize a
        // literal false rather than delete the key and make its intent
        // indistinguishable from a legacy row.
        let hidden = BotModeMeta(uiMeta: .object([
            "hermes-bots": .object(["hidden": .bool(true)])
        ]))
        try expect(hidden?.hidden == true, "hidden:true parses from Bot Mode metadata")
        let defaultVisibility = BotModeMeta(uiMeta: .object(["hermes-bots": .object([:])]))
        try expect(defaultVisibility?.hidden == false, "missing hidden defaults false")
        try expect(BotModeMeta.hiddenProjection(true)["hidden"] == .bool(true)
                    && BotModeMeta.hiddenProjection(false)["hidden"] == .bool(false),
                   "hide/unhide projections preserve literal true and false")

        // 4. Talaria's own mirror is the second rank, above the hash and below
        //    desktop's block — a bot recolored on the laptop must not keep this
        //    app's older pick.
        let mirrorOnly = try rosterRow("""
        {"name":"default","skill_count":0,
         "ui_meta":{"talaria":{"shape":"triangle","hue":"teal"}}}
        """)
        try expect(BotCosmetics.shape(for: mirrorOnly) == .triangle
                    && BotCosmetics.hue(for: mirrorOnly) == .teal,
                   "ui_meta[talaria] beats the hash")
        let bothBlocks = try rosterRow("""
        {"name":"default","skill_count":0,
         "ui_meta":{"hermes-bots":{"shape":"squircle","color":"#8b5cf6"},
                    "talaria":{"shape":"triangle","hue":"teal"}}}
        """)
        try expect(BotCosmetics.shape(for: bothBlocks) == .squircle
                    && BotCosmetics.hue(for: bothBlocks) == .violet,
                   "desktop's block outranks Talaria's mirror")
        // Same precedence off a bare ui_meta payload, which is what the profile
        // editor and `createBotProfile` hold — they used to read the mirror
        // alone and default to circle/teal, a fourth and fifth spelling of this
        // rule that disagreed with the roster the moment the block led.
        try expect(BotCosmetics.shape(uiMeta: bothBlocks.uiMeta, name: "default") == .squircle
                    && BotCosmetics.hue(uiMeta: bothBlocks.uiMeta, name: "default") == .violet,
                   "the ui_meta-only entry point obeys the same order")
        try expect(BotCosmetics.shape(uiMeta: nil, name: "default") == .hexagon,
                   "and falls through to the name hash, never to a fixed circle")

        try storedAlwaysOutranksTheHash()
        try writeTablesAreTheReadTablesInverse()
        try avatarProvenance()
    }

    /// 2. THE REGRESSION GUARD.
    ///
    /// The connect-time call and the ten-second poll return the same profile;
    /// what differed between the two paints was everything AROUND the
    /// cosmetics — `has_avatar` landed, the session stamps advanced, the rows
    /// came back in another order. None of that is an input to a face, and the
    /// bug was a second path that behaved as if it were.
    ///
    /// Equality on its own would be vacuous here — a pure function handed the
    /// same value twice. The teeth are the two assertions around it. First the
    /// fixture is PROVEN discriminating: strip its `ui_meta` and the face
    /// changes on both axes, so "the refresh dropped the cosmetics" is an event
    /// this fixture can actually detect. Only then is the moved-on answer
    /// required to match the ui_meta-bearing one rather than the stripped one.
    private static func rosterRefresh() throws {
        let coldStart = [try rosterRow(customisedRow), try rosterRow(emptyBlockRow)]
        // Reordered on purpose: `faces` is keyed by name, so a resolution that
        // ever reached for an index would come back with the pairs swapped.
        let refreshed = [try rosterRow(emptyBlockRow), try rosterRow(refreshedRow)]
        let stripped = try rosterRow(strippedRow)

        try expect(BotCosmetics.shape(for: stripped) != BotCosmetics.shape(for: coldStart[0])
                    && BotCosmetics.hue(for: stripped) != BotCosmetics.hue(for: coldStart[0]),
                   "the fixture must be one whose face changes when ui_meta is dropped, "
                   + "or the refresh guard below proves nothing")
        try expect(faces(coldStart) == faces(refreshed),
                   "an answer whose has_avatar, session stamps and row order all moved "
                   + "must paint exactly the faces the cold start painted")
        try expect(faces(refreshed)["default"] != faces([stripped])["default"],
                   "and after the refresh the row is still wearing what the human chose, "
                   + "not the hash it would wear with no ui_meta at all")
    }

    /// Every word desktop's shape picker can store, paired with the silhouette
    /// it MUST read back as (AVATAR_SHAPES plugin.js:606, AVATAR_PICKER_SHAPES
    /// 607), plus the two words only Talaria writes: `drop` for a diamond, and
    /// the literal `pentagon`, which desktop's `shapeNode` default draws as a
    /// circle (plugin.js:783) rather than dropping the bot.
    ///
    /// The expected silhouettes are LITERAL, and that is the whole point. An
    /// earlier version of this sweep computed the expectation by calling the
    /// same mapping it was testing, so `x == x` was all it asserted: it pinned
    /// that a word mapped to *something*, never to *what*. Rewiring `drop` to
    /// `.circle` passed it — and a user who picked diamond got a diamond on the
    /// tap (`applyLookLocally`) and a circle on the next `profiles.list` poll,
    /// which is this file's own regression wearing a different hat.
    private static let shapeVocabulary: [(word: String, silhouette: AvatarShape)] = [
        ("circle", .circle),
        ("cloud", .circle),
        ("squircle", .squircle),
        ("pill", .squircle),
        ("blob", .squircle),
        ("hexagon", .hexagon),
        ("triangle", .triangle),
        ("drop", .diamond),
        ("diamond", .diamond),
        ("pentagon", .pentagon),
    ]

    /// `AVATAR_COLORS` (plugin.js:660) in file order, each hex paired with the
    /// hue nearest-RGB must land on. Literal for the same reason: recomputing
    /// the expectation from `talariaHue` let any reference value be moved
    /// anywhere unnoticed, and a moved reference silently recolours every bot
    /// wearing the hex that used to be nearest it.
    ///
    /// Four of the ten are exact reference values; the rest are genuine
    /// nearest-neighbour verdicts, pinned here so a palette edit has to own the
    /// re-colouring it causes instead of shipping it on the next poll.
    private static let paletteVocabulary: [(hex: String, hue: AvatarHue)] = [
        ("#f5f5f4", .violet),  // white — the palette has no light hue at all
        ("#8d6748", .amber),   // brown
        ("#ef4444", .amber),   // red
        ("#f97316", .amber),   // orange — exact
        ("#14b8a6", .teal),    // teal — exact
        ("#38bdf8", .blue),    // cyan — exact
        ("#3b40c8", .violet),  // royal blue
        ("#8b5cf6", .violet),  // violet — exact
        ("#ec4899", .pink),    // magenta
        ("#9ca3af", .violet),  // silver
    ]

    /// 5. Every word in desktop's shape vocabulary and every entry in its
    ///    palette must land on a SPECIFIC Talaria face, and must beat the hash.
    ///
    ///    One row that happens to disagree with its own hash proves the rule
    ///    for one row. `simmy` is stored as a `drop`, `default` as a
    ///    `squircle`, and a mapping that silently returned nil for either would
    ///    fall through to the hash and change that bot's identity on the next
    ///    refresh — so the sweep is exhaustive, and each case is pinned to its
    ///    literal answer rather than to the mapping's own opinion.
    private static func storedAlwaysOutranksTheHash() throws {
        // A name whose hash is known, so "stored won" is checkable per case.
        let name = "default"
        let hashShape = BotCosmetics.derivedShape(forName: name)
        let hashHue = BotCosmetics.derivedHue(forName: name)

        var shapesSeen: Set<AvatarShape> = []
        for (word, silhouette) in shapeVocabulary {
            let uiMeta = JSONValue.object(["hermes-bots": .object(["shape": .string(word)])])
            try expect(BotModeMeta(uiMeta: uiMeta)?.talariaShape == silhouette,
                       "desktop shape \"\(word)\" reads back as \(silhouette.rawValue)")
            try expect(BotCosmetics.shape(uiMeta: uiMeta, name: name) == silhouette,
                       "a stored \"\(word)\" is what the roster paints, hash or no hash")
            shapesSeen.insert(silhouette)
        }
        // The sweep only means something if some of those words disagree with
        // the hash — otherwise every assertion above could pass on a resolver
        // that ignored ui_meta entirely.
        try expect(shapesSeen.contains { $0 != hashShape },
                   "the shape vocabulary must cover a silhouette the hash does not pick")

        var huesSeen: Set<AvatarHue> = []
        for (hex, hue) in paletteVocabulary {
            let uiMeta = JSONValue.object(["hermes-bots": .object(["color": .string(hex)])])
            try expect(BotModeMeta(uiMeta: uiMeta)?.talariaHue == hue,
                       "AVATAR_COLORS \(hex) reads back as \(hue.rawValue)")
            try expect(BotCosmetics.hue(uiMeta: uiMeta, name: name) == hue,
                       "a stored \(hex) is what the roster paints, hash or no hash")
            huesSeen.insert(hue)
        }
        try expect(huesSeen.contains { $0 != hashHue },
                   "the palette must cover a hue the hash does not pick")

        try gatewayHueIsUnreachable()
    }

    /// `.gateway` is the feed's reserved pseudo-hue — the colour Talaria paints
    /// gateway-originated rows in. No bot may ever wear it, from either side of
    /// the precedence.
    ///
    /// Asserting that per palette entry, as this used to, was unfalsifiable:
    /// `talariaHue` picks from a six-entry reference table that does not
    /// contain `.gateway`, so `mapped != .gateway` held by construction for any
    /// input whatsoever. The claim with teeth is the stronger one — that the
    /// pseudo-hue is unreachable from the wire AT ALL — and it fails the moment
    /// someone adds the entry to that table or rebuilds the hash's list from
    /// `AvatarHue.allCases`.
    private static func gatewayHueIsUnreachable() throws {
        // A coarse walk of the RGB cube: every well-formed hex must resolve,
        // and none of them to the pseudo-hue.
        for r in stride(from: 0, through: 255, by: 15) {
            for g in stride(from: 0, through: 255, by: 15) {
                for b in stride(from: 0, through: 255, by: 15) {
                    let hex = String(format: "#%02x%02x%02x", r, g, b)
                    guard let hue = BotModeMeta(colorHex: hex).talariaHue else {
                        throw CheckFailure(description:
                            "FAILED: well-formed hex \(hex) resolves to a hue")
                    }
                    try expect(hue != .gateway,
                               "\(hex) must not resolve to the feed's reserved pseudo-hue")
                }
            }
        }
        // Same rule on the last-resort side (BotCosmetics `derivedHue`, whose
        // case list excludes it by hand).
        for n in 0..<512 {
            let name = "bot-\(n)"
            try expect(BotCosmetics.derivedHue(forName: name) != .gateway,
                       "the name hash never picks the feed's reserved pseudo-hue")
        }
    }

    /// 6. THE ROUND TRIP: the write tables ARE the read table's inverse.
    ///
    /// `BotModeLook` turns a picked silhouette and hue into desktop's own word
    /// and hex; `BotModeMeta` reads them back off the next `profiles.list`. Let
    /// the two disagree on one entry and the pick paints on the tap and a
    /// DIFFERENT face ten seconds later — this file's regression arriving by a
    /// second door, through the one path instead of around it.
    ///
    /// That inverse claim used to be a comment in the view layer with nothing
    /// executable behind it, a module away from the table it named. Both tables
    /// now sit in TalariaKit/BotModeMeta.swift so this can walk them.
    static func writeTablesAreTheReadTablesInverse() throws {
        // The literals desktop itself sees. Round-tripping proves only that the
        // two tables agree with EACH OTHER; desktop matches the word against
        // AVATAR_SHAPES and uses the hex as a literal fill (plugin.js:606, 660),
        // so a pair that agreed in some private spelling would be stable on the
        // phone and wrong on the laptop.
        let writtenWord: [AvatarShape: String] = [
            .circle: "circle", .squircle: "squircle", .hexagon: "hexagon",
            .triangle: "triangle", .diamond: "drop", .pentagon: "pentagon",
        ]
        let writtenHex: [AvatarHue: String] = [
            .teal: "#14b8a6", .blue: "#38bdf8", .violet: "#8b5cf6",
            .pink: "#ec4899", .amber: "#f97316", .green: "#22c55e",
            .gateway: "#9ca3af",
        ]

        for shape in AvatarShape.allCases {
            let word = BotModeLook.shapeWord(shape)
            try expect(word == writtenWord[shape],
                       "\(shape.rawValue) travels to desktop as \"\(writtenWord[shape] ?? "?")\"")
            try expect(BotModeMeta(shape: word).talariaShape == shape,
                       "\(shape.rawValue) writes as \"\(word)\" and reads back as itself")
            // …and that word is one the vocabulary sweep pins, so the two
            // tables cannot drift into a dialect that agrees only with itself.
            try expect(shapeVocabulary.contains { $0.word == word && $0.silhouette == shape },
                       "\"\(word)\" is a word the vocabulary sweep covers")
        }

        for hue in AvatarHue.allCases {
            let hex = BotModeLook.colorHex(hue)
            try expect(hex == writtenHex[hue],
                       "\(hue.rawValue) travels to desktop as \(writtenHex[hue] ?? "?")")
            guard hue != .gateway else { continue }
            try expect(BotModeMeta(colorHex: hex).talariaHue == hue,
                       "\(hue.rawValue) writes as \(hex) and reads back as itself")
        }
        // `.gateway` is the one entry with no round trip, by design: it is the
        // feed's pseudo-hue and never a bot's own, and silver is a real
        // AVATAR_COLORS entry. Pinned rather than skipped, so "no round trip"
        // stays a decision with a known landing place instead of whatever
        // nearest-RGB happens to say after the next palette edit.
        try expect(BotModeMeta(colorHex: writtenHex[.gateway] ?? "").talariaHue == .violet,
                   "silver reads back as the nearest bot hue, never as .gateway itself")

        // End to end, through the resolver the roster actually calls, over the
        // block the save path actually writes (`saveBotLook` /`newBotUIMeta`
        // send `shape` + `color` + `custom` in the desktop block). Agreeing
        // tables are not enough on their own: `BotCosmetics` could still read a
        // key the writer never sets, and the pick would fall through to the
        // hash on the very next poll. Every silhouette is swept, so a resolver
        // that reached for the name hash could match at most one of the six.
        for shape in AvatarShape.allCases {
            for hue in AvatarHue.allCases where hue != .gateway {
                let saved = JSONValue.object(["hermes-bots": .object([
                    "shape": .string(BotModeLook.shapeWord(shape)),
                    "color": .string(BotModeLook.colorHex(hue)),
                    "custom": .bool(true),
                ])])
                try expect(BotCosmetics.shape(uiMeta: saved, name: "default") == shape
                            && BotCosmetics.hue(uiMeta: saved, name: "default") == hue,
                           "a saved \(shape.rawValue)/\(hue.rawValue) is exactly what the "
                           + "next poll paints")
            }
        }
    }

    /// The other half of the same bug: which stored asset bytes may be shown.
    ///
    /// Desktop refuses a 160×160 PNG on the roster because that is the size its
    /// own backfill rasterizes the live vector face at (plugin.js:411-417) —
    /// unless the profile's ui_meta says the stored image is a photo a human
    /// chose (`mine.imageKind !== 'photo'`). Talaria has to make the same call
    /// from the same two inputs or its faces freeze into snapshots of
    /// themselves.
    private static func avatarProvenance() throws {
        /// A PNG header only — signature + IHDR length/type + width/height,
        /// which is all the sniff reads.
        func pngHeader(width: UInt32, height: UInt32) -> Data {
            var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                                  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
            for value in [width, height] {
                bytes.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                                          UInt8(truncatingIfNeeded: value >> 16),
                                          UInt8(truncatingIfNeeded: value >> 8),
                                          UInt8(truncatingIfNeeded: value)])
            }
            return Data(bytes)
        }

        let backfilledFace = pngHeader(width: 160, height: 160)
        try expect(AvatarArtwork.isBackfilledFacePNG(backfilledFace),
                   "160×160 is the rasterized vector face, not a portrait")
        try expect(!AvatarArtwork.isBackfilledFacePNG(pngHeader(width: 256, height: 256)),
                   "256 is a user upload")
        try expect(!AvatarArtwork.isBackfilledFacePNG(pngHeader(width: 96, height: 104)),
                   "96×104 is a pet sprite")
        try expect(!AvatarArtwork.isBackfilledFacePNG(Data("not a png".utf8)),
                   "non-PNG bytes are not a backfilled face")
        try expect(!AvatarArtwork.isBackfilledFacePNG(backfilledFace.prefix(20)),
                   "a truncated header is not evidence of anything")

        let dataURL = "data:image/png;base64," + backfilledFace.base64EncodedString()
        try expect(AvatarArtwork.isBackfilledFacePNG(dataURL: dataURL),
                   "the profiles.get_asset data-URL form sniffs the same bytes")
        try expect(!AvatarArtwork.isBackfilledFacePNG(dataURL: "data:image/jpeg;base64,AAAA"),
                   "only PNG carries the backfill signature")

        // The verdict itself, both inputs (plugin.js:415).
        try expect(!AvatarArtwork.isDisplayablePortrait(backfilledFace, wantsStoredPhoto: false),
                   "a 160×160 asset on a shape-kind profile must never reach the roster")
        try expect(AvatarArtwork.isDisplayablePortrait(backfilledFace, wantsStoredPhoto: true),
                   "imageKind == photo means 160×160 is just a small picture")
        try expect(AvatarArtwork.isDisplayablePortrait(pngHeader(width: 512, height: 512),
                                                       wantsStoredPhoto: false),
                   "any other size is a real portrait")

        // `imageKind` has to survive the parse, or the clause above is dead and
        // a deliberately-chosen 160×160 photo gets thrown away with the
        // backfills.
        let photo = BotModeMeta(uiMeta: .object([
            "hermes-bots": .object(["imageKind": .string("photo")])
        ]))
        try expect(photo?.wantsStoredPhoto == true, "imageKind parses out of the desktop block")
        try expect(BotModeMeta(uiMeta: .object([
            "hermes-bots": .object(["imageKind": .string("shape")])
        ]))?.wantsStoredPhoto == false, "imageKind \"shape\" is not a photo")
        // A block whose ONLY key is imageKind still parses — the roster's own
        // fetch guard reads it off exactly such a block on a profile whose
        // look was never customised.
        try expect(BotModeMeta(uiMeta: .object([
            "hermes-bots": .object(["imageKind": .string("photo")])
        ])) != nil, "a block claiming only imageKind is still a present block")
    }
}
