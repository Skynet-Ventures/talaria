import Foundation

/// Desktop Bot Mode stores per-bot cosmetics server-side in the profile's
/// `ui_meta["hermes-bots"]` block (title, shape, color, rooms), synced
/// through `profiles.configure` so they follow the profile between machines.
///
/// This type is the PARSE of that block, not the precedence over it: which of
/// desktop's block, Talaria's mirror and the name hash a face comes from is
/// decided in exactly one place, `BotCosmetics`.
/// Source: apps/desktop/src/plugins/hermes-bots/plugin.js (`mergeServerMeta`,
/// `AVATAR_SHAPES` 606, `AVATAR_COLORS` 660).
///
/// `BotModeLook`, at the bottom of this file, is the WRITE direction — the
/// same vocabulary in the other order. The two are inverses or a look picked on
/// the phone changes identity on the next poll, so they are kept in one file
/// and `ProtocolChecks.writeTablesAreTheReadTablesInverse` walks the round trip
/// entry by entry. The read tables below are pinned to their literal answers by
/// `storedAlwaysOutranksTheHash` in the same check file: a word or a hex that
/// resolves to *something* is not the contract; resolving to *what the user
/// picked* is.
public struct BotModeMeta: Sendable, Equatable {
    public var title: String?
    /// Desktop shape vocabulary: circle, squircle, pill, triangle, hexagon,
    /// cloud, drop (+ blob in the picker).
    public var shape: String?
    /// Desktop stores a literal hex from AVATAR_COLORS.
    public var colorHex: String?
    /// Legacy pre-a4f16e3 client pointer. Current Hermes defines canonical
    /// identity only by the exact `Bot Chat` title registry and drops `chat`
    /// from metadata merges. Decode remains for downgrade compatibility, but
    /// this value is never part of current whole-block writes or identity.
    public var legacyPinnedChat: String?
    /// What the profile's stored avatar asset actually IS: `"photo"` for a
    /// picture a human chose, `"shape"` for a machine-made 160 px raster of
    /// the live vector face. Desktop's roster consults it before refusing a
    /// 160×160 asset (plugin.js:415) — without it a deliberately-chosen
    /// 160×160 photo would be thrown away along with the backfills.
    public var imageKind: String?
    /// `created`, ms epoch (plugin.js:5399-5401). Ranks a brand-new bot to the
    /// top of the roster before it has said anything.
    public var created: Double?
    /// A plain boolean that rides ui_meta to every machine, so a laptop pin
    /// pins here too.
    public var pinned: Bool
    /// Per-profile roster visibility. This is deliberately independent from a
    /// hidden *session*: hiding a roster row must not remove the bot from
    /// mention resolution, rooms, unread, or activity polling.
    public var hidden: Bool
    /// Canonical room memberships. Current Hermes stores an ordered `groups`
    /// array; the older scalar `group` is only a projection of its first item.
    public var groups: [String]

    public init(title: String? = nil, shape: String? = nil,
                colorHex: String? = nil,
                imageKind: String? = nil, created: Double? = nil,
                pinned: Bool = false, hidden: Bool = false, groups: [String] = []) {
        self.title = title; self.shape = shape
        self.colorHex = colorHex; self.legacyPinnedChat = nil
        self.imageKind = imageKind; self.created = created; self.pinned = pinned; self.hidden = hidden
        self.groups = Self.normalizedGroups(groups)
    }

    /// Parse the desktop block out of a profile's `ui_meta`.
    ///
    /// Nil means **the block is absent** — a gateway that stores no ui_meta at
    /// all — and nothing else. A block that exists but claims nothing parses to
    /// an all-nil value on purpose: desktop's `mergeServerMeta` treats a
    /// present block as authoritative down to its omissions (plugin.js:441-470),
    /// so "the block says no title" has to be distinguishable from "there is no
    /// block", and a failable init that swallowed the empty case would erase
    /// exactly that difference.
    public init?(uiMeta: JSONValue?) {
        guard let block = uiMeta?["hermes-bots"], block.objectValue != nil else { return nil }
        title = block["title"]?.stringValue
        shape = block["shape"]?.stringValue
        colorHex = block["color"]?.stringValue
        legacyPinnedChat = block["chat"]?.stringValue
        imageKind = block["imageKind"]?.stringValue
        created = block["created"]?.doubleValue
        pinned = block["pinned"]?.boolValue == true
        hidden = block["hidden"]?.boolValue == true
        // A canonical array is authoritative, including an empty array.
        // Current Hermes falls back to the legacy scalar only when `groups`
        // is absent or not an array (`botGroups`, plugin.js), so malformed
        // server metadata resolves the same way on desktop and mobile.
        if let canonical = block["groups"]?.arrayValue {
            groups = Self.normalizedGroups(canonical.compactMap(\.stringValue))
        } else {
            groups = Self.normalizedGroups([block["group"]?.stringValue].compactMap { $0 })
        }
    }

    /// Compatibility value written beside `groups` for older Bot Mode builds.
    public var legacyGroupProjection: String? { groups.first }

    /// Ordered trim/dedupe shared by reads and writes. Comparison is literal,
    /// matching Hermes: differently-cased room names remain distinct.
    public static func normalizedGroups(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let group = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.isEmpty, seen.insert(group).inserted else { continue }
            result.append(group)
        }
        return result
    }

    /// Server patch shape: `groups` is canonical and `group` remains a
    /// first-membership projection until legacy desktop builds age out.
    public static func membershipProjection(_ values: [String]) -> [String: JSONValue] {
        let groups = normalizedGroups(values)
        return [
            "groups": .array(groups.map(JSONValue.string)),
            "group": groups.first.map(JSONValue.string) ?? .null,
        ]
    }

    /// Roster visibility patch shape. Unhide must write a literal `false`, not
    /// omit/delete the key: omission means legacy/default rather than an
    /// explicit cross-device user choice.
    public static func hiddenProjection(_ hidden: Bool) -> [String: JSONValue] {
        ["hidden": .bool(hidden)]
    }

    /// Rename a canonical membership without moving its seat in the ordered
    /// array. The first element is also the legacy scalar projection, so a
    /// remove-then-append implementation would silently change old clients'
    /// active room.
    public static func replacingGroup(_ oldName: String, with newName: String,
                                      in values: [String]) -> [String] {
        normalizedGroups(values.map { $0 == oldName ? newName : $0 })
    }

    /// The stored asset is a real picture a human chose, not a rasterized copy
    /// of the vector face. Desktop's `mine.imageKind !== 'photo'` (plugin.js:415).
    public var wantsStoredPhoto: Bool { imageKind == "photo" }

    /// Desktop's shape vocabulary mapped onto Talaria's six silhouettes.
    /// Shapes Talaria has no glyph for fall back to the nearest sibling
    /// rather than being dropped (a bot should never change shape between
    /// apps more than it must).
    public var talariaShape: AvatarShape? {
        switch shape?.lowercased() {
        case "circle", "cloud": .circle
        case "squircle", "pill", "blob": .squircle
        case "hexagon": .hexagon
        case "triangle": .triangle
        case "drop", "diamond": .diamond
        case "pentagon": .pentagon
        default: nil
        }
    }

    /// Nearest Talaria hue for a desktop AVATAR_COLORS hex, by RGB distance
    /// against the palette's reference values.
    public var talariaHue: AvatarHue? {
        guard let hex = colorHex, let rgb = Self.rgb(from: hex) else { return nil }
        let reference: [(AvatarHue, (Double, Double, Double))] = [
            (.teal, (0x14, 0xb8, 0xa6)),
            (.blue, (0x38, 0xbd, 0xf8)),
            (.violet, (0x8b, 0x5c, 0xf6)),
            (.pink, (0xec, 0x48, 0x99)),
            (.amber, (0xf9, 0x73, 0x16)),
            (.green, (0x22, 0xc5, 0x5e)),
        ]
        return reference.min { a, b in
            Self.distance(rgb, a.1) < Self.distance(rgb, b.1)
        }?.0
    }

    static func rgb(from hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Double((n >> 16) & 0xFF), Double((n >> 8) & 0xFF), Double(n & 0xFF))
    }

    static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }
}

// MARK: - Vocabulary mapping (write direction)

/// Talaria's six silhouettes and six hues expressed in desktop Bot Mode's own
/// vocabulary, so a look chosen on the phone renders on the laptop.
///
/// These tables are the exact inverse of `BotModeMeta.talariaShape` /
/// `.talariaHue` above, which is what makes a round trip stable — write, poll,
/// read back, and the bot still wears what the user picked. That claim used to
/// be a comment in the view layer with nothing executable behind it, one file
/// away from the table it was claiming to invert; a word that wrote one way and
/// read back another would paint the pick on the tap and a different face ten
/// seconds later, which is the roster regression arriving by a second door.
/// It lives here, beside the read direction and inside TalariaKit, so
/// `ProtocolChecks.writeTablesAreTheReadTablesInverse` can walk both tables.
public enum BotModeLook {

    /// `AVATAR_SHAPES` (plugin.js:606) = circle, squircle, pill, triangle,
    /// hexagon, cloud, drop. Four of Talaria's six have an exact counterpart;
    /// `diamond` writes as `drop`, the same pairing `BotModeMeta.talariaShape`
    /// reads back. `pentagon` has no upstream shape at all, so it travels as
    /// its own literal word: desktop's `shapeNode` default draws an unknown
    /// shape as a circle (plugin.js:783) rather than dropping the bot, and
    /// `BotModeMeta` maps "pentagon" straight back — the pick survives the
    /// round trip instead of silently becoming a hexagon on the next poll.
    public static func shapeWord(_ shape: AvatarShape) -> String {
        switch shape {
        case .circle: "circle"
        case .squircle: "squircle"
        case .hexagon: "hexagon"
        case .triangle: "triangle"
        case .diamond: "drop"
        case .pentagon: "pentagon"
        }
    }

    /// Desktop stores a literal hex and renders it literally (`shapeNode`
    /// takes the color as a fill), so these are the reference values
    /// `BotModeMeta.talariaHue` matches against — five of them are literal
    /// `AVATAR_COLORS` entries (plugin.js:660: teal, cyan, violet, magenta,
    /// orange) and green is off-palette but renders exactly the same way.
    /// Writing anything else would round-trip through nearest-neighbour and
    /// change the user's hue.
    public static func colorHex(_ hue: AvatarHue) -> String {
        switch hue {
        case .teal: "#14b8a6"
        case .blue: "#38bdf8"
        case .violet: "#8b5cf6"
        case .pink: "#ec4899"
        case .amber: "#f97316"
        case .green: "#22c55e"
        // Reserved for gateway-originated feed rows; never a bot's own hue,
        // but the switch has to be total. Silver is also a real AVATAR_COLORS
        // entry, so this is the one case with no round trip: it reads back as
        // the nearest bot hue, by design.
        case .gateway: "#9ca3af"
        }
    }
}
