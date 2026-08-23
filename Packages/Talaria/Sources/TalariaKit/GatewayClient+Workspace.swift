import Foundation

/// A request returned through the success transport path, but its body did
/// not contain the operation-specific receipt required to prove what Hermes
/// accepted. This is deliberately distinct from an explicit `ok: false`
/// refusal: callers must reconcile state instead of treating the write as
/// safely retryable.
public struct AckValidationError: Error, LocalizedError, Sendable, Equatable {
    public var operation: String
    public var detail: String

    public init(operation: String, detail: String = "Hermes returned a malformed success acknowledgement.") {
        self.operation = operation
        self.detail = detail
    }

    public var errorDescription: String? { "\(operation): \(detail)" }
}

public enum WorkspaceFileSizePolicy {
    public static let maximumBytes = 12 * 1_024 * 1_024

    /// `/api/files` includes the root directory's complete entry list even
    /// when artifact loading needs only its locked-root metadata. Bound that
    /// proof envelope independently so a very large directory cannot be fully
    /// buffered on mobile merely to establish capability.
    public static let maximumManagedRootResponseBytes = 1 * 1_024 * 1_024

    /// Base64 JSON envelope ceiling for `/api/files/read`. Hermes permits a
    /// 100 MB decoded file, while Talaria admits only 12 MB; the transport must
    /// stop the encoded response before Foundation buffers the larger body.
    public static let maximumManagedReadResponseBytes =
        ((maximumBytes + 2) / 3) * 4 + 64 * 1_024

    public static func allows(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumBytes
    }

    static var maximumBase64Characters: Int {
        ((maximumBytes + 2) / 3) * 4
    }
}

// Typed, source-safe access to Hermes' portable workspace surfaces. These
// wrappers deliberately stop at authenticated gateway APIs: Electron-local
// process spawning, Finder/Explorer reveal and the desktop PTY are not remote
// capabilities and are never approximated with shell.exec.

/// Host paths in Hermes payloads belong to the gateway, not to the phone.
/// Foundation's file-URL helpers apply the *phone's* platform rules, which
/// turns a Windows drive or UNC path into a bogus POSIX parent on iOS/macOS.
/// This parser keeps the remote platform's root semantics and rejects any
/// traversal that would climb above that root.
public enum WorkspaceRemotePath {
    private enum Prefix: Equatable {
        case posix
        case drive(String)
        case unc(server: String, share: String)
        case relative

        var isCaseInsensitive: Bool {
            switch self {
            case .drive, .unc: true
            case .posix, .relative: false
            }
        }
    }

    private struct Parsed {
        var prefix: Prefix
        var segments: [String]
    }

    public static func normalized(_ raw: String) -> String? {
        parse(raw).map(render)
    }

    public static func parent(of raw: String) -> String? {
        guard var parsed = parse(raw), !parsed.segments.isEmpty else { return nil }
        parsed.segments.removeLast()
        if parsed.prefix == .relative, parsed.segments.isEmpty { return nil }
        return render(parsed)
    }

    public static func basename(of raw: String) -> String {
        guard let parsed = parse(raw) else { return "" }
        if let last = parsed.segments.last { return last }
        if case .unc(_, let share) = parsed.prefix { return share }
        return ""
    }

    public static func isFilesystemRoot(_ raw: String) -> Bool {
        guard let parsed = parse(raw) else { return false }
        return parsed.prefix != .relative && parsed.segments.isEmpty
    }

    public static func isAbsolute(_ raw: String) -> Bool {
        guard let parsed = parse(raw) else { return false }
        return parsed.prefix != .relative
    }

    public static func contains(_ rawPath: String, in rawRoot: String) -> Bool {
        guard let path = parse(rawPath), let root = parse(rawRoot),
              prefixesMatch(path.prefix, root.prefix),
              root.segments.count <= path.segments.count else { return false }
        let insensitive = root.prefix.isCaseInsensitive
        return root.segments.indices.allSatisfy { index in
            insensitive
                ? root.segments[index].caseInsensitiveCompare(path.segments[index]) == .orderedSame
                : root.segments[index] == path.segments[index]
        }
    }

    private static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let value = trimmed.replacingOccurrences(of: "\\", with: "/")

        let prefix: Prefix
        let pieces: [Substring]
        if value.hasPrefix("//") {
            let all = value.drop(while: { $0 == "/" }).split(separator: "/", omittingEmptySubsequences: true)
            guard all.count >= 2 else { return nil }
            prefix = .unc(server: String(all[0]), share: String(all[1]))
            pieces = Array(all.dropFirst(2))
        } else if value.count >= 3 {
            let chars = Array(value.prefix(3))
            if chars[0].isLetter, chars[1] == ":", chars[2] == "/" {
                prefix = .drive(String(chars[0]).uppercased())
                pieces = value.dropFirst(3).split(separator: "/", omittingEmptySubsequences: true)
            } else if value.dropFirst().first == ":" {
                // `C:relative` is drive-current-directory syntax. Its meaning
                // depends on process state and cannot be fenced remotely.
                return nil
            } else if value.hasPrefix("/") {
                prefix = .posix
                pieces = value.drop(while: { $0 == "/" }).split(separator: "/", omittingEmptySubsequences: true)
            } else {
                prefix = .relative
                pieces = value.split(separator: "/", omittingEmptySubsequences: true)
            }
        } else if value.hasPrefix("/") {
            prefix = .posix
            pieces = value.drop(while: { $0 == "/" }).split(separator: "/", omittingEmptySubsequences: true)
        } else if value.count >= 2, value.dropFirst().first == ":" {
            return nil
        } else {
            prefix = .relative
            pieces = value.split(separator: "/", omittingEmptySubsequences: true)
        }

        var segments: [String] = []
        for piece in pieces {
            if piece == "." { continue }
            if piece == ".." {
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
            } else {
                segments.append(String(piece))
            }
        }
        if prefix == .relative, segments.isEmpty { return nil }
        return Parsed(prefix: prefix, segments: segments)
    }

    private static func render(_ parsed: Parsed) -> String {
        let suffix = parsed.segments.joined(separator: "/")
        switch parsed.prefix {
        case .posix:
            return suffix.isEmpty ? "/" : "/" + suffix
        case .drive(let drive):
            return suffix.isEmpty ? "\(drive):/" : "\(drive):/" + suffix
        case .unc(let server, let share):
            let root = "//\(server)/\(share)"
            return suffix.isEmpty ? root : root + "/" + suffix
        case .relative:
            return suffix
        }
    }

    private static func prefixesMatch(_ lhs: Prefix, _ rhs: Prefix) -> Bool {
        switch (lhs, rhs) {
        case (.posix, .posix), (.relative, .relative):
            return true
        case (.drive(let a), .drive(let b)):
            return a.caseInsensitiveCompare(b) == .orderedSame
        case (.unc(let aserver, let ashare), .unc(let bserver, let bshare)):
            return aserver.caseInsensitiveCompare(bserver) == .orderedSame
                && ashare.caseInsensitiveCompare(bshare) == .orderedSame
        default:
            return false
        }
    }
}

public struct GatewayWorkspaceRoute: Hashable, Sendable, Identifiable {
    public var gatewayID: String
    /// The exact profile name the user selected from Hermes' inventory.  This
    /// is deliberately raw: display names and trimmed/fallback values are not
    /// safe routing identities for a profile-scoped RPC.
    public var profile: String

    public var rawProfile: String { profile }

    public var id: String {
        gatewayID + "\u{1f}" + profile
    }

    public init(gatewayID: String, profile: String) {
        self.gatewayID = gatewayID
        self.profile = profile
    }

    /// Keep validation separate from construction so that a rejected raw value
    /// is never silently rewritten to another profile (not even `default`).
    public var isWellFormed: Bool {
        !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The one profile-selection fence for the Projects namespace.  A profile is
/// eligible only when it is an exact, nonblank member of the gateway inventory
/// just observed by the caller.  In particular, a display label, a trimmed
/// spelling, and an omitted profile are all rejected rather than falling back
/// to the gateway's launch profile.
public enum WorkspaceProjectScope {
    public static func route(gatewayID: String, rawProfile: String,
                             knownProfiles: [String]) -> GatewayWorkspaceRoute? {
        let route = GatewayWorkspaceRoute(gatewayID: gatewayID, profile: rawProfile)
        guard route.isWellFormed, knownProfiles.contains(route.profile) else { return nil }
        return route
    }

    /// Normalize nothing: profile names are gateway routing identities, not
    /// presentation strings.  Reject whitespace-only, padded, duplicate, and
    /// case-ambiguous inventories before a caller can select one of them.
    public static func knownRawProfiles(from rows: [HermesProfile]) throws -> [String] {
        var exact = Set<String>()
        var folded = Set<String>()
        let values = try rows.map { row -> String in
            let raw = row.name
            guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  exact.insert(raw).inserted,
                  folded.insert(raw.lowercased()).inserted else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned an invalid or ambiguous profile inventory.")
            }
            return raw
        }
        guard !values.isEmpty else {
            throw GatewayError(code: 404,
                               message: "Hermes did not report a selectable profile for Projects.")
        }
        return values
    }

    /// Revalidate a previously selected route against a *fresh* gateway
    /// inventory. Hermes deliberately falls back to its launch profile for an
    /// unknown explicit profile, so membership in an older roster snapshot is
    /// never enough authority for a `projects.*` request.
    @discardableResult
    public static func requireCurrent(_ route: GatewayWorkspaceRoute,
                                      in rows: [HermesProfile]) throws -> [String] {
        let names = try knownRawProfiles(from: rows)
        guard self.route(gatewayID: route.gatewayID, rawProfile: route.rawProfile,
                         knownProfiles: names) == route else {
            throw GatewayError(
                code: 409,
                message: "The selected Hermes profile was renamed or deleted. Projects remain blocked to avoid launch-profile fallback."
            )
        }
        return names
    }
}

/// Exact 9ef9 JSON-RPC request envelopes for Hermes Projects.  Keeping the
/// method and params together makes it difficult for a future caller to issue
/// a `projects.*` request without the selected raw profile.
public struct WorkspaceProjectRequest: Equatable, Sendable {
    public static let overviewPreviewLimit = 3
    public static let sessionLimit = 5_000

    public var method: String
    public var params: JSONValue

    public static func list(in route: GatewayWorkspaceRoute) throws -> Self {
        try make(method: "projects.list", route: route)
    }

    public static func discoverRepos(in route: GatewayWorkspaceRoute) throws -> Self {
        try make(method: "projects.discover_repos", route: route,
                 fields: ["scan": .bool(true)])
    }

    public static func tree(in route: GatewayWorkspaceRoute) throws -> Self {
        try make(method: "projects.tree", route: route, fields: [
            "preview_limit": .number(Double(overviewPreviewLimit)),
            "session_limit": .number(Double(sessionLimit)),
        ])
    }

    public static func projectSessions(id: String, in route: GatewayWorkspaceRoute) throws -> Self {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError(code: 400, message: "A nonblank Hermes project identity is required.")
        }
        return try make(method: "projects.project_sessions", route: route, fields: [
            "project_id": .string(id),
            "session_limit": .number(Double(sessionLimit)),
        ])
    }

    static func write(_ method: String, fields: [String: JSONValue],
                      in route: GatewayWorkspaceRoute) throws -> Self {
        try make(method: method, route: route, fields: fields)
    }

    private static func make(method: String, route: GatewayWorkspaceRoute,
                             fields: [String: JSONValue] = [:]) throws -> Self {
        guard route.isWellFormed else {
            throw GatewayError(code: 400,
                               message: "Projects require a nonblank, explicitly selected Hermes profile.")
        }
        // Callers never control the profile key.  The route's raw value is the
        // only profile spelling that can reach the wire.
        var params = fields
        params["profile"] = .string(route.profile)
        return Self(method: method, params: .object(params))
    }
}

/// The only permissible ordering for a full Projects refresh.  Discovery is
/// first because Hermes folds its completed scan into `projects.tree`; list
/// and tree then share the exact same verified raw profile route.
public struct WorkspaceProjectSnapshotRequests: Equatable, Sendable {
    public var discovery: WorkspaceProjectRequest
    public var listing: WorkspaceProjectRequest
    public var tree: WorkspaceProjectRequest

    public init(in route: GatewayWorkspaceRoute) throws {
        discovery = try .discoverRepos(in: route)
        listing = try .list(in: route)
        tree = try .tree(in: route)
    }

    public var ordered: [WorkspaceProjectRequest] { [discovery, listing, tree] }
}

public enum WorkspaceFileSource: String, Hashable, Sendable {
    case managed
    case project
}

public struct ManagedFileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var modifiedAt: Double?
    public var mimeType: String
    public var source: WorkspaceFileSource

    init(_ value: JSONValue, source: WorkspaceFileSource = .managed) {
        name = value["name"]?.stringValue ?? ""
        path = value["path"]?.stringValue ?? ""
        isDirectory = value["is_directory"]?.boolValue
            ?? value["isDirectory"]?.boolValue ?? false
        size = value["size"]?.intValue ?? 0
        modifiedAt = value["mtime"]?.doubleValue
        mimeType = value["mime_type"]?.stringValue ?? "application/octet-stream"
        self.source = source
    }
}

public struct ManagedFileListing: Sendable {
    public var path: String
    public var parent: String?
    public var root: String
    public var lockedRoot: String?
    public var canChangePath: Bool
    public var entries: [ManagedFileEntry]
    public var source: WorkspaceFileSource

    init(_ value: JSONValue, source: WorkspaceFileSource = .managed, requestedPath: String? = nil) {
        path = value["path"]?.stringValue ?? requestedPath ?? ""
        if let wireParent = value["parent"]?.stringValue?.nilIfEmpty {
            parent = WorkspaceRemotePath.normalized(wireParent)
        } else if source == .project, let requestedPath {
            parent = WorkspaceRemotePath.parent(of: requestedPath)
        } else {
            parent = nil
        }
        root = value["root"]?.stringValue ?? requestedPath ?? ""
        lockedRoot = value["locked_root"]?.stringValue?.nilIfEmpty
        canChangePath = value["can_change_path"]?.boolValue ?? false
        self.source = source
        entries = value["entries"]?.arrayValue?.compactMap { row in
            let entry = ManagedFileEntry(row, source: source)
            return WorkspaceSensitivePath.allows(entry.path) ? entry : nil
        } ?? []
    }

    /// Decode only the locked managed-files shape that Hermes can fence with
    /// canonical real paths. An unlocked local-home listing or any response
    /// whose returned paths escape that fence is intentionally unavailable to
    /// a remote Command Center.
    init(validatingManaged value: JSONValue, requestedPath: String? = nil) throws {
        self.init(value, source: .managed, requestedPath: requestedPath)
        guard let locked = value["locked_root"]?.stringValue
            .flatMap(WorkspaceRemotePath.normalized),
              WorkspaceRemotePath.isAbsolute(locked),
              !WorkspaceRemotePath.isFilesystemRoot(locked),
              let returned = WorkspaceRemotePath.normalized(path),
              WorkspaceRemotePath.contains(returned, in: locked),
              remotePathsMatch(value["root"]?.stringValue, locked) else {
            throw GatewayError(
                code: 501,
                message: "Hermes did not provide a locked, canonical managed-files boundary. Files remain unavailable."
            )
        }
        if let requestedPath, !requestedPath.isEmpty,
           !remotePathsMatch(requestedPath, returned) {
            throw GatewayError(code: 502,
                               message: "Hermes returned a different managed directory than Talaria requested.")
        }
        if let parent = value["parent"]?.stringValue?.nilIfEmpty {
            guard let normalized = WorkspaceRemotePath.normalized(parent),
                  WorkspaceRemotePath.contains(normalized, in: locked) else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned an unsafe managed-directory parent.")
            }
            self.parent = normalized
        }
        guard let rows = value["entries"]?.arrayValue else {
            throw GatewayError(code: 502, message: "Hermes omitted the managed-directory entries.")
        }
        for row in rows {
            guard let child = row["path"]?.stringValue.flatMap(WorkspaceRemotePath.normalized),
                  WorkspaceRemotePath.contains(child, in: locked),
                  WorkspaceSensitivePath.allows(child) else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned an entry outside the managed-files safety boundary.")
            }
        }
        path = returned
        root = locked
        lockedRoot = locked
        entries = rows.map { ManagedFileEntry($0, source: .managed) }
    }
}

public struct ManagedFileBody: Sendable {
    public var name: String
    public var path: String
    public var mimeType: String
    public var bytes: Data
    public var isText: Bool
    public var isTruncated: Bool
    public var textPreview: String?
    public var lockedRoot: String?

    init(_ value: JSONValue, source: WorkspaceFileSource = .managed) throws {
        name = value["name"]?.stringValue ?? ""
        path = value["path"]?.stringValue ?? ""
        mimeType = value["mime_type"]?.stringValue ?? "application/octet-stream"
        lockedRoot = value["locked_root"]?.stringValue.flatMap(WorkspaceRemotePath.normalized)
        guard let encoded = value["data_url"]?.stringValue,
              let comma = encoded.firstIndex(of: ","),
              encoded[..<comma].contains(";base64") else {
            throw GatewayError(code: -71, message: "Managed file response contained invalid data.")
        }
        let payload = encoded[encoded.index(after: comma)...]
        guard payload.utf8.count <= WorkspaceFileSizePolicy.maximumBase64Characters else {
            throw GatewayError(code: 413, message: "This file exceeds Talaria’s 12 MB mobile preview limit.")
        }
        guard let decoded = Data(base64Encoded: String(payload)) else {
            throw GatewayError(code: -71, message: "Managed file response contained invalid data.")
        }
        guard WorkspaceFileSizePolicy.allows(byteCount: decoded.count) else {
            throw GatewayError(code: 413, message: "This file exceeds Talaria’s 12 MB mobile preview limit.")
        }
        if let declaredSize = value["size"]?.intValue, declaredSize != decoded.count {
            throw GatewayError(code: 502,
                               message: "Hermes returned managed-file bytes that do not match its declared size.")
        }
        bytes = decoded
        isText = mimeType.hasPrefix("text/")
        isTruncated = false
        textPreview = isText ? String(data: decoded, encoding: .utf8) : nil
    }

    init(validatingManaged value: JSONValue, requestedPath: String) throws {
        try self.init(value, source: .managed)
        guard let lockedRoot,
              WorkspaceRemotePath.isAbsolute(lockedRoot),
              !WorkspaceRemotePath.isFilesystemRoot(lockedRoot),
              let returned = WorkspaceRemotePath.normalized(path),
              remotePathsMatch(returned, requestedPath),
              WorkspaceRemotePath.contains(returned, in: lockedRoot),
              WorkspaceSensitivePath.allows(returned) else {
            throw GatewayError(code: 502,
                               message: "Hermes could not prove the requested file stayed inside its locked managed root.")
        }
        path = returned
    }

    /// Artifact reads first capture `/api/files`' locked root, then require the
    /// exact same root and canonical target from `/api/files/read`. A root
    /// change is authority loss, not an ordinary malformed preview.
    init(validatingArtifact value: JSONValue, requestedPath: String,
         expectedLockedRoot: String) throws {
        guard let expected = WorkspaceRemotePath.normalized(expectedLockedRoot),
              WorkspaceRemotePath.isAbsolute(expected),
              !WorkspaceRemotePath.isFilesystemRoot(expected),
              let returnedRoot = value["locked_root"]?.stringValue
                .flatMap(WorkspaceRemotePath.normalized),
              returnedRoot == expected,
              let rootEcho = value["root"]?.stringValue
                .flatMap(WorkspaceRemotePath.normalized),
              rootEcho == expected,
              let requested = WorkspaceRemotePath.normalized(requestedPath),
              let returned = value["path"]?.stringValue
                .flatMap(WorkspaceRemotePath.normalized),
              returned == requested,
              WorkspaceRemotePath.contains(returned, in: expected),
              WorkspaceSensitivePath.allows(returned) else {
            throw GatewayError(
                code: GatewayClient.managedFileAuthorityUnproven,
                message: "Hermes did not preserve the captured managed-file root and canonical path.")
        }
        guard let sizeValue = value["size"],
              case .number(let rawSize) = sizeValue,
              rawSize.isFinite,
              rawSize >= 0,
              rawSize.rounded(.towardZero) == rawSize,
              rawSize < Double(Int.max) else {
            throw GatewayError(code: 502,
                               message: "Hermes returned an invalid managed-file size.")
        }
        guard Int(rawSize) <= WorkspaceFileSizePolicy.maximumBytes else {
            throw GatewayError(
                code: 413,
                message: "This file exceeds Talaria’s 12 MB mobile preview limit.")
        }
        try self.init(value, source: .managed)
        path = returned
    }

    init(project value: JSONValue, path: String) throws {
        self.path = value["path"]?.stringValue ?? path
        name = WorkspaceRemotePath.basename(of: path)
        mimeType = value["mimeType"]?.stringValue ?? "text/plain"
        lockedRoot = nil
        isTruncated = value["truncated"]?.boolValue ?? false
        let binary = value["binary"]?.boolValue ?? false
        isText = !binary
        if !binary, let text = value["text"]?.stringValue {
            bytes = Data(text.utf8)
            textPreview = text
        } else {
            bytes = Data()
            textPreview = nil
        }
    }
}

public struct HermesProjectFolder: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var label: String?
    public var isPrimary: Bool

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        label = value["label"]?.stringValue?.nilIfEmpty
        isPrimary = value["is_primary"]?.boolValue ?? false
    }
}

public struct HermesProject: Identifiable, Hashable, Sendable {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String?
    public var icon: String?
    public var color: String?
    public var primaryPath: String?
    public var isArchived: Bool
    public var folders: [HermesProjectFolder]

    init(_ value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        slug = value["slug"]?.stringValue ?? ""
        name = value["name"]?.stringValue ?? slug
        description = value["description"]?.stringValue?.nilIfEmpty
        icon = value["icon"]?.stringValue?.nilIfEmpty
        color = value["color"]?.stringValue?.nilIfEmpty
        primaryPath = value["primary_path"]?.stringValue?.nilIfEmpty
        isArchived = value["archived"]?.boolValue ?? false
        folders = value["folders"]?.arrayValue?.map(HermesProjectFolder.init) ?? []
    }
}

public struct HermesProjectListing: Sendable {
    public var projects: [HermesProject]
    public var activeID: String?

    init(_ value: JSONValue) {
        projects = value["projects"]?.arrayValue?.map(HermesProject.init) ?? []
        let reportedActiveID = value["active_id"]?.stringValue?.nilIfEmpty
        // c1e25 intentionally leaves the project_meta pointer untouched when
        // its target is archived or deleted.  That pointer is history, not a
        // selectable project: only a visible (non-archived) row can be active.
        activeID = reportedActiveID.flatMap { candidate in
            projects.contains(where: { $0.id == candidate && !$0.isArchived })
                ? candidate : nil
        }
    }

    init(validatingAcknowledgement value: JSONValue, operation: String) throws {
        guard let rawProjects = value["projects"]?.arrayValue else {
            throw AckValidationError(operation: operation,
                                     detail: "Hermes did not return a valid authoritative project listing.")
        }
        switch value["active_id"] {
        case .null:
            break
        case .string(let id) where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            break
        default:
            throw AckValidationError(operation: operation,
                                     detail: "Hermes did not return a valid authoritative project listing.")
        }
        self.init(value)
        guard projects.count == rawProjects.count,
              projects.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(projects.map(\.id)).count == projects.count else {
            throw AckValidationError(operation: operation,
                                     detail: "Hermes returned malformed or partial project identities.")
        }
    }

    init(validatingArchiveAcknowledgement value: JSONValue, id: String,
         restore: Bool) throws {
        let operation = restore ? "Restore project" : "Archive project"
        try self.init(validatingAcknowledgement: value, operation: operation)
        guard let target = projects.first(where: { $0.id == id }),
              target.isArchived == !restore else {
            throw AckValidationError(
                operation: operation,
                detail: restore
                    ? "Hermes did not return the restored project as visible."
                    : "Hermes did not return the target project as archived."
            )
        }
    }

    init(validatingDeleteAcknowledgement value: JSONValue, id: String) throws {
        try self.init(validatingAcknowledgement: value, operation: "Delete project")
        guard !projects.contains(where: { $0.id == id }) else {
            throw AckValidationError(operation: "Delete project",
                                     detail: "Hermes still returned the deleted project.")
        }
    }
}

public struct HermesProjectSessionPreview: Identifiable, Hashable, Sendable {
    public var id: String { profile + "\u{1f}" + storedID }
    public var storedID: String
    public var profile: String
    public var title: String
    public var preview: String
    public var lastActive: Double

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue?.nilIfEmpty,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let profile = value["profile"]?.stringValue,
              !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        storedID = id
        self.profile = profile
        title = value["title"]?.stringValue?.nilIfEmpty ?? "Untitled session"
        preview = value["preview"]?.stringValue ?? ""
        lastActive = value["last_active"]?.doubleValue ?? value["started_at"]?.doubleValue ?? 0
    }

    init?(_ value: JSONValue, expectedProfile: String) {
        guard let decoded = HermesProjectSessionPreview(value),
              decoded.profile == expectedProfile else { return nil }
        self = decoded
    }
}

public struct HermesProjectTree: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var path: String?
    public var sessionCount: Int
    public var totalTokens: Int
    public var totalCostUSD: Double
    public var previews: [HermesProjectSessionPreview]

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue?.nilIfEmpty,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sessionCountValue = value["sessionCount"]?.doubleValue,
              let sessionCount = Int(exactly: sessionCountValue),
              sessionCount >= 0,
              let rawPreviews = value["previewSessions"]?.arrayValue else { return nil }
        let previews = rawPreviews.compactMap(HermesProjectSessionPreview.init)
        guard previews.count == rawPreviews.count,
              previews.count <= sessionCount,
              Set(previews.map(\.id)).count == previews.count else { return nil }
        self.id = id
        label = value["label"]?.stringValue?.nilIfEmpty ?? id
        path = value["path"]?.stringValue?.nilIfEmpty
        self.sessionCount = sessionCount
        totalTokens = value["totalTokens"]?.intValue ?? 0
        totalCostUSD = value["totalCostUsd"]?.doubleValue ?? 0
        self.previews = previews
    }

    static func validatedList(from response: JSONValue) throws -> [HermesProjectTree] {
        if let errorsValue = response["errors"] {
            guard let errors = errorsValue.arrayValue else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned invalid project-tree error metadata.")
            }
            guard errors.isEmpty else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned only a partial project tree.")
            }
        }
        guard let rawProjects = response["projects"]?.arrayValue else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted the project-tree array.")
        }
        let projects = rawProjects.compactMap(HermesProjectTree.init)
        guard projects.count == rawProjects.count else {
            throw GatewayError(code: 502,
                               message: "Hermes returned malformed nested project-session metadata.")
        }
        return projects
    }

    /// Decode the profile-scoped 9ef9 `projects.tree` payload.  Hermes keeps
    /// profile ownership out of each stored-session row because one RPC already
    /// selects the database.  Talaria adds the *already verified requested raw
    /// profile* locally; it never trusts a response to nominate another route.
    static func scopedList(from response: JSONValue, profile: String) throws -> [HermesProjectTree] {
        try WorkspaceProjectPayload.treeProof(response, profile: profile).projects
    }

    /// Preserve the fresh profile-global `scoped_session_ids` witness for
    /// drill-in completeness checks. The array-only compatibility decoder
    /// above is sufficient for rendering but intentionally not for authority.
    static func scopedProof(from response: JSONValue,
                            profile: String) throws -> WorkspaceProjectTreeProof {
        try WorkspaceProjectPayload.treeProof(response, profile: profile)
    }

    /// Decode the exact `projects.project_sessions` result for one selected
    /// project.  `project: null` is not an empty session list: it is what the
    /// gateway returns for a discovery-only / no-longer-hydratable project, and
    /// presenting it as a completed drill-in would hide that distinction.
    static func scopedProjectSessions(from response: JSONValue, projectID: String,
                                      profile: String) throws -> HermesProjectTree {
        try WorkspaceProjectPayload.projectSessions(response, projectID: projectID, profile: profile)
    }
}

private enum WorkspaceProjectPayload {
    static func treeProof(_ response: JSONValue,
                          profile: String) throws -> WorkspaceProjectTreeProof {
        try requireProfile(profile)
        guard response["errors"] == nil else {
            throw GatewayError(code: 502,
                               message: "Hermes returned partial project-tree metadata.")
        }
        guard let rawProjects = response["projects"]?.arrayValue,
              let rawScopedIDs = response["scoped_session_ids"]?.arrayValue else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted required profile-scoped project-tree fields.")
        }
        // Decode the field strictly, but do not require the pointer to resolve:
        // c1e25 can legally retain an archived/deleted project id here.  Tree
        // membership remains authoritative for what is actually selectable.
        _ = try activeProjectID(from: response)
        let scopedIDs = try sessionIDs(rawScopedIDs)
        let scopedIDSet = Set(scopedIDs)
        guard scopedIDSet.count == scopedIDs.count else {
            throw GatewayError(code: 502,
                               message: "Hermes returned duplicate scoped-session identifiers.")
        }

        var authoritativePlacedCount = 0
        let projects = try rawProjects.map { raw -> HermesProjectTree in
            try validateRepositoryShape(raw, hydrated: false)
            let rows = try injectedSessionRows(raw["previewSessions"], profile: profile)
            guard rows.count <= WorkspaceProjectRequest.overviewPreviewLimit else {
                throw GatewayError(code: 502,
                                   message: "Hermes exceeded the requested profile-scoped preview window.")
            }
            guard let project = HermesProjectTree(scoped: raw, profile: profile, rows: rows) else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned malformed profile-scoped project metadata.")
            }
            if !isDiscoveryOnlyProject(raw) {
                authoritativePlacedCount = min(
                    WorkspaceProjectSessionWindowPolicy.maximumRows,
                    authoritativePlacedCount + min(
                        WorkspaceProjectSessionWindowPolicy.maximumRows,
                        project.sessionCount
                    )
                )
            }
            return project
        }
        guard Set(projects.map(\.id)).count == projects.count else {
            throw GatewayError(code: 502, message: "Hermes returned duplicate project identities.")
        }
        let previewIDs = projects.flatMap(\.previews).map(\.storedID)
        guard Set(previewIDs).count == previewIDs.count,
              previewIDs.allSatisfy({ scopedIDSet.contains($0) }) else {
            throw GatewayError(code: 502,
                               message: "Hermes returned preview sessions outside its authoritative scoped-session set.")
        }
        // `scoped_session_ids` is the global witness for the bounded stored
        // session query. Project counts may additionally describe discovered
        // repositories whose historical rows are not hydrated and therefore
        // are deliberately absent from this set; they cannot be substituted
        // for the scoped count. Reaching the requested 5,000 ids is ambiguous.
        guard scopedIDs.count == authoritativePlacedCount,
              WorkspaceProjectSessionWindowPolicy.isUnsaturated(
                totalReportedSessions: scopedIDs.count
              ) else {
            throw GatewayError(
                code: 501,
                message: "Hermes’ profile-scoped project tree is incomplete or reached its session window. Talaria will not present a partial project view as complete."
            )
        }
        return WorkspaceProjectTreeProof(
            projects: projects, scopedSessionCount: scopedIDs.count,
            scopedSessionIDs: scopedIDSet
        )
    }

    static func projectSessions(_ response: JSONValue, projectID: String,
                                profile: String) throws -> HermesProjectTree {
        try requireProfile(profile)
        guard !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError(code: 400, message: "A nonblank Hermes project identity is required.")
        }
        guard let rawProject = response["project"] else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted the profile-scoped project-session result.")
        }
        guard rawProject != .null else {
            throw GatewayError(
                code: 404,
                message: "Hermes did not hydrate this project. Discovery-only projects do not have an authoritative session drill-in."
            )
        }
        guard rawProject["id"]?.stringValue == projectID else {
            throw GatewayError(code: 502,
                               message: "Hermes returned sessions for a different project.")
        }
        guard let rawPreviews = rawProject["previewSessions"]?.arrayValue,
              rawPreviews.isEmpty else {
            throw GatewayError(code: 502,
                               message: "Hermes returned an invalid profile-scoped project-session shape.")
        }
        try validateRepositoryShape(rawProject, hydrated: true)
        let rows = try hydratedSessionRows(from: rawProject)
        guard let project = HermesProjectTree(scoped: rawProject, profile: profile,
                                              rows: try injectedSessionRows(rows, profile: profile)),
              project.sessionCount == rows.count,
              WorkspaceProjectSessionWindowPolicy.isProvablyComplete(
                totalReportedSessions: project.sessionCount,
                selectedReportedSessions: project.sessionCount,
                selectedPreviewCount: project.previews.count
              ) else {
            throw GatewayError(
                code: 501,
                message: "Hermes’ profile-scoped project-session response is incomplete or reached its bounded window."
            )
        }
        return project
    }

    private static func requireProfile(_ profile: String) throws {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError(code: 400,
                               message: "Projects require a nonblank, explicitly selected Hermes profile.")
        }
    }

    private static func activeProjectID(from response: JSONValue) throws -> String? {
        guard let value = response["active_id"] else {
            throw GatewayError(code: 502, message: "Hermes omitted the active project identity.")
        }
        switch value {
        case .null: return nil
        case .string(let id) where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return id
        default:
            throw GatewayError(code: 502, message: "Hermes returned an invalid active project identity.")
        }
    }

    private static func sessionIDs(_ rows: [JSONValue]) throws -> [String] {
        try rows.map { row in
            guard let id = row.stringValue?.nilIfEmpty,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned malformed scoped-session metadata.")
            }
            return id
        }
    }

    private static func injectedSessionRows(_ value: JSONValue?, profile: String) throws -> [JSONValue] {
        guard let rawRows = value?.arrayValue else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted project-session rows required by the Projects contract.")
        }
        return try injectedSessionRows(rawRows, profile: profile)
    }

    private static func injectedSessionRows(_ rows: [JSONValue], profile: String) throws -> [JSONValue] {
        try rows.map { row in
            guard var object = row.objectValue else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned a malformed project-session row.")
            }
            // The profile is implicit in the scoped RPC. Overwrite any stray
            // payload value so a malformed/cross-profile row cannot change the
            // source route used when the user opens it.
            object["profile"] = .string(profile)
            return .object(object)
        }
    }

    private static func hydratedSessionRows(from project: JSONValue) throws -> [JSONValue] {
        guard let rawRepos = project["repos"]?.arrayValue else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted the hydrated project repository lanes.")
        }
        var repoIDs = Set<String>()
        var rows: [JSONValue] = []
        for rawRepo in rawRepos {
            guard let repoID = rawRepo["id"]?.stringValue?.nilIfEmpty,
                  repoIDs.insert(repoID).inserted,
                  let expectedCount = nonnegativeInteger(rawRepo["sessionCount"]),
                  let rawGroups = rawRepo["groups"]?.arrayValue else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned malformed hydrated project repository metadata.")
            }
            var groupIDs = Set<String>()
            var repoRows: [JSONValue] = []
            for rawGroup in rawGroups {
                guard let groupID = rawGroup["id"]?.stringValue?.nilIfEmpty,
                      groupIDs.insert(groupID).inserted,
                      let groupRows = rawGroup["sessions"]?.arrayValue else {
                    throw GatewayError(code: 502,
                                       message: "Hermes returned malformed hydrated project lane metadata.")
                }
                repoRows.append(contentsOf: groupRows)
            }
            guard expectedCount == repoRows.count else {
                throw GatewayError(code: 502,
                                   message: "Hermes reported a partial hydrated project repository.")
            }
            rows.append(contentsOf: repoRows)
        }
        return rows
    }

    private static func validateRepositoryShape(_ project: JSONValue, hydrated: Bool) throws {
        guard let rawRepos = project["repos"]?.arrayValue else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted project repository metadata.")
        }
        var repoIDs = Set<String>()
        for rawRepo in rawRepos {
            guard let repoID = rawRepo["id"]?.stringValue?.nilIfEmpty,
                  repoIDs.insert(repoID).inserted,
                  nonnegativeInteger(rawRepo["sessionCount"]) != nil,
                  let rawGroups = rawRepo["groups"]?.arrayValue else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned malformed project repository metadata.")
            }
            var groupIDs = Set<String>()
            for rawGroup in rawGroups {
                guard let groupID = rawGroup["id"]?.stringValue?.nilIfEmpty,
                      groupIDs.insert(groupID).inserted,
                      let sessions = rawGroup["sessions"]?.arrayValue,
                      !hydrated || sessions.allSatisfy({ $0.objectValue != nil }) else {
                    throw GatewayError(code: 502,
                                       message: "Hermes returned malformed project repository lanes.")
                }
                if !hydrated, !sessions.isEmpty {
                    throw GatewayError(code: 502,
                                       message: "Hermes returned hydrated rows in an overview-only project tree.")
                }
            }
        }
    }

    /// Tier-3 auto projects are discovered from full history/disk after the
    /// bounded stored-session query. They carry historical counts but no
    /// hydrated lanes and correctly contribute no `scoped_session_ids`.
    private static func isDiscoveryOnlyProject(_ project: JSONValue) -> Bool {
        guard project["isAuto"]?.boolValue == true,
              let repos = project["repos"]?.arrayValue,
              !repos.isEmpty else { return false }
        return repos.allSatisfy { repo in
            guard let groups = repo["groups"]?.arrayValue else { return false }
            return groups.isEmpty
        }
    }

    private static func nonnegativeInteger(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, let integer = Int(exactly: number), integer >= 0 else {
            return nil
        }
        return integer
    }
}

private extension HermesProjectTree {
    init?(scoped value: JSONValue, profile: String, rows: [JSONValue]) {
        guard var object = value.objectValue else { return nil }
        object["previewSessions"] = .array(rows)
        guard let decoded = HermesProjectTree(.object(object)),
              decoded.previews.allSatisfy({ $0.profile == profile }),
              decoded.previews.count == rows.count else { return nil }
        self = decoded
    }
}

public struct HermesGitFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var status: String
    public var staged: Bool
    public var unstaged: Bool
    public var added: Int
    public var removed: Int

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        status = value["status"]?.stringValue ?? "M"
        staged = value["staged"]?.boolValue ?? false
        unstaged = value["unstaged"]?.boolValue ?? !staged
        added = value["added"]?.intValue ?? 0
        removed = value["removed"]?.intValue ?? 0
    }
}

public struct HermesGitStatus: Sendable {
    public var branch: String?
    public var defaultBranch: String?
    public var detached: Bool
    public var ahead: Int
    public var behind: Int
    public var added: Int
    public var removed: Int
    public var files: [HermesGitFile]

    init(_ value: JSONValue) {
        branch = value["branch"]?.stringValue?.nilIfEmpty
        defaultBranch = value["defaultBranch"]?.stringValue?.nilIfEmpty
        detached = value["detached"]?.boolValue ?? false
        ahead = value["ahead"]?.intValue ?? 0
        behind = value["behind"]?.intValue ?? 0
        added = value["added"]?.intValue ?? 0
        removed = value["removed"]?.intValue ?? 0
        files = value["files"]?.arrayValue?.map(HermesGitFile.init) ?? []
    }
}

public struct HermesGitBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var checkedOut: Bool
    public var isDefault: Bool
    public var isRemote: Bool
    public var worktreePath: String?

    init(_ value: JSONValue) {
        name = value["name"]?.stringValue ?? ""
        checkedOut = value["checkedOut"]?.boolValue ?? false
        isDefault = value["isDefault"]?.boolValue ?? false
        isRemote = value["isRemote"]?.boolValue ?? false
        worktreePath = value["worktreePath"]?.stringValue?.nilIfEmpty
    }
}

public struct HermesGitWorktree: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var branch: String?
    public var isMain: Bool
    public var detached: Bool
    public var locked: Bool

    init(_ value: JSONValue) {
        path = value["path"]?.stringValue ?? ""
        branch = value["branch"]?.stringValue?.nilIfEmpty
        isMain = value["isMain"]?.boolValue ?? false
        detached = value["detached"]?.boolValue ?? false
        locked = value["locked"]?.boolValue ?? false
    }
}

public enum HermesCommandOrigin: String, Hashable, Sendable {
    case builtIn
    case skill
    case quickCommand
    case unclassified
}

public struct HermesCommand: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var origin: HermesCommandOrigin
}

public enum WorkspaceCommandPolicy {
    public static func canonicalName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "/" })).lowercased()
    }

    /// Catalog origin metadata cannot make `command.dispatch` safe for Command
    /// Center because Hermes resolves shadowing plugins and quick commands
    /// before its built-ins.
    /// Keep this invariant explicit so a future catalog UI cannot accidentally
    /// re-enable Command Center dispatch based on a name or claimed origin.
    public static func permitsCommandCenterDispatch(_ command: HermesCommand) -> Bool {
        _ = command
        return false
    }
}

public enum WorkspaceProjectSessionWindowPolicy {
    public static let maximumRows = 5_000

    public static func isUnsaturated(totalReportedSessions: Int) -> Bool {
        totalReportedSessions >= 0 && totalReportedSessions < maximumRows
    }

    /// Hermes derives project counts after applying a global per-profile row
    /// limit and returns neither a total nor a cursor. Any saturated aggregate
    /// is therefore ambiguous, even when the selected project's own previews
    /// appear complete.
    public static func isProvablyComplete(totalReportedSessions: Int,
                                          selectedReportedSessions: Int,
                                          selectedPreviewCount: Int) -> Bool {
        isUnsaturated(totalReportedSessions: totalReportedSessions)
            && selectedReportedSessions >= 0
            && selectedReportedSessions <= totalReportedSessions
            && selectedPreviewCount >= selectedReportedSessions
    }
}

/// A decoded `projects.tree` plus the count of its unique authoritative
/// `scoped_session_ids`. Discovered-only repository counts are presentation
/// metadata and do not inflate this global bounded-query witness.
public struct WorkspaceProjectTreeProof: Sendable, Equatable {
    public var projects: [HermesProjectTree]
    public var scopedSessionCount: Int
    /// Exact bounded-query witness returned by `projects.tree`. The count is
    /// retained separately for compatibility and diagnostics, but stability
    /// checks must compare the identifiers themselves so equal-sized swaps do
    /// not make a stale hydrated response look current.
    public var scopedSessionIDs: Set<String>

    public init(projects: [HermesProjectTree], scopedSessionCount: Int,
                scopedSessionIDs: Set<String> = []) {
        self.projects = projects
        self.scopedSessionCount = scopedSessionCount
        self.scopedSessionIDs = scopedSessionIDs
    }
}

/// Joins one freshly decoded `projects.tree` response with the subsequent
/// `projects.project_sessions` response. The latter carries neither the
/// profile-global total nor `scoped_session_ids`, so a cached overview can
/// never supply this proof.
public enum WorkspaceProjectDrillInProof {
    /// Join the pre-hydration and post-hydration tree witnesses. The bounded
    /// project-session response is publishable only when the exact tree proof
    /// stayed unchanged across that RPC; otherwise the user can retry against
    /// a single coherent snapshot.
    public static func validate(
        projectID: String,
        beforeHydration: WorkspaceProjectTreeProof,
        afterHydration: WorkspaceProjectTreeProof,
        hydrated: HermesProjectTree
    ) throws -> HermesProjectTree {
        guard WorkspaceProjectSessionWindowPolicy.isUnsaturated(
            totalReportedSessions: beforeHydration.scopedSessionCount
        ), WorkspaceProjectSessionWindowPolicy.isUnsaturated(
            totalReportedSessions: afterHydration.scopedSessionCount
        ) else {
            throw GatewayError(
                code: 501,
                message: "Hermes' profile-scoped project tree reached its bounded session window during drill-in."
            )
        }
        guard beforeHydration == afterHydration else {
            throw GatewayError(
                code: 409,
                message: "Hermes' profile-scoped project tree changed while sessions were loading. Try again."
            )
        }
        return try validate(projectID: projectID, freshTree: afterHydration,
                            hydrated: hydrated)
    }

    public static func validate(projectID: String,
                                freshTree: WorkspaceProjectTreeProof,
                                hydrated: HermesProjectTree) throws -> HermesProjectTree {
        guard let overview = freshTree.projects.first(where: { $0.id == projectID }) else {
            throw GatewayError(code: 404,
                               message: "Hermes no longer reports this project in the selected profile.")
        }
        guard hydrated.id == overview.id,
              hydrated.sessionCount == overview.sessionCount,
              WorkspaceProjectSessionWindowPolicy.isProvablyComplete(
                totalReportedSessions: freshTree.scopedSessionCount,
                selectedReportedSessions: overview.sessionCount,
                selectedPreviewCount: hydrated.previews.count
              ) else {
            throw GatewayError(
                code: 501,
                message: "Hermes' fresh profile-scoped project proof is incomplete or saturated."
            )
        }
        return hydrated
    }

    /// Cached preview buttons are navigation hints, not authority. Resolve the
    /// exact stored id/profile again from the freshly proven drill-in before
    /// opening a conversation.
    public static func validatedNavigation(
        cached: HermesProjectSessionPreview,
        in hydrated: HermesProjectTree
    ) throws -> HermesProjectSessionPreview {
        guard let current = hydrated.previews.first(where: {
            $0.storedID == cached.storedID && $0.profile == cached.profile
        }) else {
            throw GatewayError(code: 404,
                               message: "That project session moved or is no longer available.")
        }
        return current
    }
}

/// One internally coherent profile-scoped Projects refresh.  The repository
/// discovery result is deliberately carried with the list/tree so callers do
/// not accidentally issue the tree before the remote scan has completed.
public struct WorkspaceProjectSnapshot: Sendable {
    public var listing: HermesProjectListing
    public var tree: [HermesProjectTree]
    public var discoveredRoots: [String]
    public var scopedSessionCount: Int

    public init(listing: HermesProjectListing, tree: [HermesProjectTree],
                discoveredRoots: [String], scopedSessionCount: Int) {
        var normalizedListing = listing
        if let activeID = normalizedListing.activeID,
           !tree.contains(where: { $0.id == activeID }) {
            // The tree is the visible profile-scoped surface.  A list pointer
            // which cannot be placed in that tree is the legal stale c1e25
            // metadata case, not authority to select an invisible project.
            normalizedListing.activeID = nil
        }
        self.listing = normalizedListing
        self.tree = tree
        self.discoveredRoots = discoveredRoots
        self.scopedSessionCount = scopedSessionCount
    }
}

public enum ManagedTextWriteResult: Sendable, Equatable {
    case saved
    case conflict(current: Data)
}

public struct HermesUpdateCheck: Sendable, Equatable {
    public var canApply: Bool
    public var recommendedCommand: String?
    public var message: String?
    public var raw: JSONValue

    init(_ value: JSONValue) throws {
        guard let canApply = value["can_apply"]?.boolValue else {
            throw GatewayError(code: -86, message: "Hermes did not report whether this installation can update itself.")
        }
        self.canApply = canApply
        recommendedCommand = value["update_command"]?.stringValue?.nilIfEmpty
            ?? value["recommended_command"]?.stringValue?.nilIfEmpty
        message = value["message"]?.stringValue?.nilIfEmpty
        raw = value
    }
}

public struct HermesProcess: Identifiable, Hashable, Sendable {
    public var id: String
    public var command: String
    public var status: String
    public var cwd: String
    public var outputTail: String
    public var uptimeSeconds: Int

    init(_ value: JSONValue) {
        id = value["session_id"]?.stringValue
            ?? value["id"]?.stringValue ?? value["process_id"]?.stringValue ?? ""
        command = value["command"]?.stringValue ?? value["cmd"]?.stringValue ?? ""
        status = value["status"]?.stringValue ?? "running"
        cwd = value["cwd"]?.stringValue ?? ""
        outputTail = value["output_tail"]?.stringValue
            ?? value["output_preview"]?.stringValue ?? ""
        uptimeSeconds = value["uptime_seconds"]?.intValue ?? 0
    }
}

public extension GatewayClient {
    func workspaceStatus() async throws -> JSONValue {
        try await restJSON(path: "api/status", timeout: 15)
    }

    func workspaceMemoryStatus() async throws -> JSONValue {
        try await restJSON(path: "api/memory", timeout: 30)
    }

    func workspaceCuratorStatus() async throws -> JSONValue {
        try await restJSON(path: "api/curator", timeout: 30)
    }

    func setWorkspaceCuratorPaused(_ paused: Bool) async throws -> JSONValue {
        let response = try await restJSON(path: "api/curator/paused", method: "PUT",
                                          body: .object(["paused": .bool(paused)]), timeout: 30)
        if response["ok"]?.boolValue == false {
            throw GatewayError(code: 409, message: "Hermes refused the curator state change.")
        }
        guard response["ok"]?.boolValue == true,
              response["paused"]?.boolValue == paused else {
            throw AckValidationError(operation: "Change curator state")
        }
        return response
    }

    func runWorkspaceCurator() async throws -> JSONValue {
        let response = try await restJSON(path: "api/curator/run", method: "POST",
                                          body: .object([:]), timeout: 30)
        try requireAccepted(response, operation: "Run curator")
        guard response["name"]?.stringValue == "curator-run",
              response["pid"]?.intValue != nil else {
            throw AckValidationError(operation: "Run curator",
                                     detail: "Hermes omitted the accepted curator action identity.")
        }
        return response
    }

    func workspaceUsage(days: Int = 30, profile: String? = nil) async throws -> JSONValue {
        var query = [URLQueryItem(name: "days", value: String(min(max(days, 1), 365)))]
        if let profile = profile?.nilIfEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        return try await restJSON(path: "api/analytics/usage", query: query, timeout: 60)
    }

    func startWorkspaceAction(path: String, body: JSONValue? = nil,
                              timeout: TimeInterval = 30) async throws -> JSONValue {
        try await restJSON(path: path, method: "POST", body: body ?? .object([:]), timeout: timeout)
    }

    func workspaceActionStatus(name: String) async throws -> JSONValue {
        try await restJSON(path: "api/actions/\(name)/status", timeout: 15)
    }

    func checkHermesUpdate() async throws -> HermesUpdateCheck {
        try HermesUpdateCheck(try await restJSON(path: "api/hermes/update/check", timeout: 60))
    }

    func resetWorkspaceMemory(target: String) async throws -> JSONValue {
        guard ["all", "memory", "user"].contains(target) else {
            throw GatewayError(code: -81, message: "Unsupported memory reset target.")
        }
        return try await startWorkspaceAction(path: "api/memory/reset",
                                              body: .object(["target": .string(target)]))
    }

    func createDebugShare() async throws -> JSONValue {
        try await startWorkspaceAction(path: "api/ops/debug-share",
                                       body: .object(["lines": .number(1000), "redact": .bool(true)]),
                                       timeout: 120)
    }

    func managedFiles(path: String? = nil) async throws -> ManagedFileListing {
        let query = path?.nilIfEmpty.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        return try ManagedFileListing(
            validatingManaged: try await restJSON(path: "api/files", query: query),
            requestedPath: path
        )
    }

    /// Root proof for a gateway-hosted artifact. Ordinary self-managed Hermes
    /// installs deliberately return `locked_root: null`; that is an honest nil
    /// capability, never permission to borrow an active WorkspaceRuntime root.
    func managedArtifactRoot() async throws -> String? {
        try Self.validatedManagedArtifactRoot(
            try await restJSONBounded(
                path: "api/files",
                timeout: 30,
                maximumResponseBytes: WorkspaceFileSizePolicy.maximumManagedRootResponseBytes
            ))
    }

    internal static func validatedManagedArtifactRoot(_ value: JSONValue) throws -> String? {
        guard let rawLocked = value["locked_root"]?.stringValue?.nilIfEmpty else {
            return nil
        }
        guard let locked = WorkspaceRemotePath.normalized(rawLocked),
              WorkspaceRemotePath.isAbsolute(locked),
              !WorkspaceRemotePath.isFilesystemRoot(locked),
              let root = value["root"]?.stringValue.flatMap(WorkspaceRemotePath.normalized),
              root == locked,
              let returned = value["path"]?.stringValue.flatMap(WorkspaceRemotePath.normalized),
              returned == locked,
              value["can_change_path"]?.boolValue == false else {
            throw GatewayError(
                code: managedFileAuthorityUnproven,
                message: "Hermes did not provide one canonical locked managed-files root.")
        }
        return locked
    }

    /// Exact-client, wire-bounded artifact body read. The captured root is
    /// required again in the body acknowledgement; both it and the canonical
    /// returned path must match before decoded bytes leave TalariaKit.
    func managedArtifactFile(path: String, expectedLockedRoot: String) async throws
        -> ManagedFileBody {
        try ManagedFileBody(
            validatingArtifact: try await restJSONBounded(
                path: "api/files/read",
                query: [URLQueryItem(name: "path", value: path)],
                timeout: 60,
                maximumResponseBytes: WorkspaceFileSizePolicy.maximumManagedReadResponseBytes
            ),
            requestedPath: path,
            expectedLockedRoot: expectedLockedRoot
        )
    }

    func managedFile(path: String) async throws -> ManagedFileBody {
        try ManagedFileBody(
            validatingManaged: try await restJSON(
                path: "api/files/read",
                query: [URLQueryItem(name: "path", value: path)], timeout: 60
            ),
            requestedPath: path
        )
    }

    func projectFiles(path: String) async throws -> ManagedFileListing {
        _ = path
        throw GatewayError(
            code: 501,
            message: "Project files are unavailable because this Hermes version does not return an authoritative realpath/containment proof. Managed Files remain available."
        )
    }

    func projectFile(path: String) async throws -> ManagedFileBody {
        _ = path
        throw GatewayError(
            code: 501,
            message: "Project-file content is blocked until Hermes can prove the resolved target remains inside the selected project root."
        )
    }

    func discoveredWorkspaceRoots(in route: GatewayWorkspaceRoute) async throws -> [String] {
        let request = try WorkspaceProjectRequest.discoverRepos(in: route)
        return try Self.decodedDiscoveredWorkspaceRoots(
            try await rpc(request.method, request.params)
        )
    }

    private static func decodedDiscoveredWorkspaceRoots(_ response: JSONValue) throws -> [String] {
        guard let repos = response["repos"]?.arrayValue else {
            throw GatewayError(code: 502,
                               message: "Hermes omitted the profile-scoped repository discovery result.")
        }
        return try repos.map { row in
            guard let root = row.stringValue?.nilIfEmpty
                    ?? row["root"]?.stringValue?.nilIfEmpty else {
                throw GatewayError(code: 502,
                                   message: "Hermes returned malformed profile-scoped repository metadata.")
            }
            return root
        }
    }

    @discardableResult
    func uploadManagedFile(path: String, bytes: Data, mimeType: String,
                           overwrite: Bool) async throws -> ManagedFileEntry {
        guard WorkspaceFileSizePolicy.allows(byteCount: bytes.count) else {
            throw GatewayError(code: 413, message: "Files larger than 12 MB are not uploaded from the phone.")
        }
        let dataURL = "data:\(mimeType);base64,\(bytes.base64EncodedString())"
        let response = try await restJSON(path: "api/files/upload", method: "POST", body: .object([
            "path": .string(path), "data_url": .string(dataURL), "overwrite": .bool(overwrite),
        ]), timeout: 120)
        try requireAccepted(response, operation: "Managed file upload")
        try requireManagedFence(response, target: path, operation: "Managed file upload")
        guard let entry = response["entry"],
              remotePathsEqual(entry["path"]?.stringValue, path) else {
            throw AckValidationError(operation: "Managed file upload",
                                     detail: "Hermes did not return the exact uploaded path.")
        }
        return ManagedFileEntry(entry)
    }

    @discardableResult
    func createManagedDirectory(path: String) async throws -> ManagedFileEntry {
        let response = try await restJSON(path: "api/files/mkdir", method: "POST",
                                          body: .object(["path": .string(path)]))
        try requireAccepted(response, operation: "Managed directory creation")
        try requireManagedFence(response, target: path, operation: "Managed directory creation")
        guard let entry = response["entry"], remotePathsEqual(entry["path"]?.stringValue, path),
              entry["is_directory"]?.boolValue == true else {
            throw AckValidationError(operation: "Managed directory creation",
                                     detail: "Hermes did not return the exact created directory.")
        }
        return ManagedFileEntry(entry)
    }

    func deleteManagedFile(path: String, recursive: Bool = false) async throws {
        let response = try await restJSON(path: "api/files", method: "DELETE", body: .object([
            "path": .string(path), "recursive": .bool(recursive),
        ]))
        try requireAccepted(response, operation: "Managed file deletion")
        try requireManagedFence(response, target: path, operation: "Managed file deletion")
        guard remotePathsEqual(response["path"]?.stringValue, path) else {
            throw AckValidationError(operation: "Managed file deletion",
                                     detail: "Hermes did not echo the deleted path.")
        }
    }

    func projects(in route: GatewayWorkspaceRoute) async throws -> HermesProjectListing {
        let request = try WorkspaceProjectRequest.list(in: route)
        return try HermesProjectListing(validatingAcknowledgement:
            try await rpc(request.method, request.params), operation: "List projects")
    }

    func projectTree(in route: GatewayWorkspaceRoute) async throws -> [HermesProjectTree] {
        let proof = try await projectTreeProof(in: route)
        return proof.projects
    }

    func projectTreeProof(in route: GatewayWorkspaceRoute) async throws
        -> WorkspaceProjectTreeProof {
        let request = try WorkspaceProjectRequest.tree(in: route)
        return try HermesProjectTree.scopedProof(
            from: try await rpc(request.method, request.params, timeout: 60),
            profile: route.rawProfile
        )
    }

    func projectSessions(id: String, in route: GatewayWorkspaceRoute) async throws -> HermesProjectTree {
        let request = try WorkspaceProjectRequest.projectSessions(id: id, in: route)
        return try HermesProjectTree.scopedProjectSessions(
            from: try await rpc(request.method, request.params, timeout: 120),
            projectID: id, profile: route.rawProfile
        )
    }

    /// Discovery must finish before the tree is built: 9ef9's tree folds the
    /// just-scanned remote repositories into its explicit/auto project model.
    /// This intentionally does not use an `async let` for discovery and tree.
    func projectSnapshot(in route: GatewayWorkspaceRoute) async throws -> WorkspaceProjectSnapshot {
        let requests = try WorkspaceProjectSnapshotRequests(in: route)
        let discoveryResponse = try await rpc(requests.discovery.method, requests.discovery.params)
        let discoveredRoots = try Self.decodedDiscoveredWorkspaceRoots(discoveryResponse)

        // Do not move this tree call above the completed discovery response.
        // The plan makes that dependency explicit and independently testable.
        async let listingResponse = rpc(requests.listing.method, requests.listing.params)
        let treeResponse = try await rpc(requests.tree.method, requests.tree.params, timeout: 60)
        let projectListing = try HermesProjectListing(
            validatingAcknowledgement: try await listingResponse,
            operation: "List projects"
        )
        let tree = try HermesProjectTree.scopedProof(from: treeResponse,
                                                     profile: route.rawProfile)
        return WorkspaceProjectSnapshot(listing: projectListing, tree: tree.projects,
                                        discoveredRoots: discoveredRoots,
                                        scopedSessionCount: tree.scopedSessionCount)
    }

    func createProject(name: String, folders: [String], primaryPath: String?,
                       description: String? = nil, use: Bool = false,
                       in route: GatewayWorkspaceRoute) async throws -> HermesProject {
        var body: [String: JSONValue] = [
            "name": .string(name), "folders": .array(folders.map(JSONValue.string)), "use": .bool(use),
        ]
        if let primaryPath = primaryPath?.nilIfEmpty { body["primary_path"] = .string(primaryPath) }
        if let description = description?.nilIfEmpty { body["description"] = .string(description) }
        let request = try WorkspaceProjectRequest.write("projects.create", fields: body, in: route)
        let response = try await rpc(request.method, request.params)
        guard let project = response["project"],
              let id = project["id"]?.stringValue?.nilIfEmpty else {
            throw AckValidationError(operation: "Create project",
                                     detail: "Hermes did not return the created project identity.")
        }
        let decoded = HermesProject(project)
        guard decoded.id == id else {
            throw AckValidationError(operation: "Create project")
        }
        return decoded
    }

    func updateProject(id: String, name: String? = nil, description: String? = nil,
                       icon: String? = nil, color: String? = nil,
                       in route: GatewayWorkspaceRoute) async throws -> HermesProject {
        var body: [String: JSONValue] = ["id": .string(id)]
        if let name { body["name"] = .string(name) }
        if let description { body["description"] = .string(description) }
        if let icon { body["icon"] = .string(icon) }
        if let color { body["color"] = .string(color) }
        let request = try WorkspaceProjectRequest.write("projects.update", fields: body, in: route)
        let response = try await rpc(request.method, request.params)
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Update project",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func addProjectFolder(id: String, path: String, label: String? = nil,
                          isPrimary: Bool = false,
                          in route: GatewayWorkspaceRoute) async throws -> HermesProject {
        var body: [String: JSONValue] = [
            "id": .string(id), "path": .string(path), "is_primary": .bool(isPrimary),
        ]
        if let label = label?.nilIfEmpty { body["label"] = .string(label) }
        let request = try WorkspaceProjectRequest.write("projects.add_folder", fields: body, in: route)
        let response = try await rpc(request.method, request.params)
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Add project folder",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func removeProjectFolder(id: String, path: String,
                             in route: GatewayWorkspaceRoute) async throws -> HermesProject {
        let request = try WorkspaceProjectRequest.write("projects.remove_folder", fields: [
            "id": .string(id), "path": .string(path),
        ], in: route)
        let response = try await rpc(request.method, request.params)
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Remove project folder",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func setPrimaryProjectFolder(id: String, path: String,
                                 in route: GatewayWorkspaceRoute) async throws -> HermesProject {
        let request = try WorkspaceProjectRequest.write("projects.set_primary", fields: [
            "id": .string(id), "path": .string(path),
        ], in: route)
        let response = try await rpc(request.method, request.params)
        guard let project = response["project"], project["id"]?.stringValue == id else {
            throw AckValidationError(operation: "Set primary project folder",
                                     detail: "Hermes did not return the updated project identity.")
        }
        return HermesProject(project)
    }

    func archiveProject(id: String, restore: Bool = false,
                        in route: GatewayWorkspaceRoute) async throws -> HermesProjectListing {
        let request = try WorkspaceProjectRequest.write("projects.archive", fields: [
            "id": .string(id), "restore": .bool(restore),
        ], in: route)
        return try HermesProjectListing(
            validatingArchiveAcknowledgement: try await rpc(request.method, request.params),
            id: id, restore: restore
        )
    }

    func deleteProject(id: String, in route: GatewayWorkspaceRoute) async throws -> HermesProjectListing {
        let request = try WorkspaceProjectRequest.write("projects.delete", fields: ["id": .string(id)], in: route)
        return try HermesProjectListing(
            validatingDeleteAcknowledgement: try await rpc(request.method, request.params),
            id: id
        )
    }

    func setActiveProject(id: String?, in route: GatewayWorkspaceRoute) async throws -> String? {
        let request = try WorkspaceProjectRequest.write("projects.set_active", fields: [
            "id": id.map(JSONValue.string) ?? .null,
        ], in: route)
        let response = try await rpc(request.method, request.params)
        let active = response["active_id"]?.stringValue?.nilIfEmpty
        if let id, active != id {
            throw AckValidationError(operation: "Select project",
                                     detail: "Hermes did not echo the selected project identity.")
        }
        if id == nil, response["active_id"] != .null {
            throw AckValidationError(operation: "Clear active project")
        }
        return active
    }

    func workspaceGitStatus(path: String) async throws -> HermesGitStatus {
        let value = try await restJSON(path: "api/git/status",
                                       query: [URLQueryItem(name: "path", value: path)])
        guard value != .null else {
            throw GatewayError(code: 404, message: "The selected folder is not a Git repository.")
        }
        return HermesGitStatus(value)
    }

    func gitReviewFiles(path: String) async throws -> [HermesGitFile] {
        let value = try await restJSON(path: "api/git/review/list", query: [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "scope", value: "uncommitted"),
        ])
        return value["files"]?.arrayValue?.map(HermesGitFile.init) ?? []
    }

    func gitBranches(path: String) async throws -> [HermesGitBranch] {
        let value = try await restJSON(path: "api/git/branches",
                                       query: [URLQueryItem(name: "path", value: path)])
        return value["branches"]?.arrayValue?.map(HermesGitBranch.init) ?? []
    }

    func gitWorktrees(path: String) async throws -> [HermesGitWorktree] {
        let value = try await restJSON(path: "api/git/worktrees",
                                       query: [URLQueryItem(name: "path", value: path)])
        return value["worktrees"]?.arrayValue?.map(HermesGitWorktree.init) ?? []
    }

    func gitBaseBranches(path: String) async throws -> [HermesGitBranch] {
        let value = try await restJSON(path: "api/git/base-branches",
                                       query: [URLQueryItem(name: "path", value: path)])
        return value["branches"]?.arrayValue?.map(HermesGitBranch.init) ?? []
    }

    func addGitWorktree(path: String, name: String, branch: String,
                        base: String?) async throws {
        var body: [String: JSONValue] = [
            "path": .string(path), "name": .string(name), "branch": .string(branch),
        ]
        if let base = base?.nilIfEmpty { body["base"] = .string(base) }
        let response = try await restJSON(path: "api/git/worktree/add", method: "POST",
                                          body: .object(body), timeout: 120)
        guard response["path"]?.stringValue?.nilIfEmpty != nil,
              response["branch"]?.stringValue == branch else {
            throw AckValidationError(operation: "Create Git worktree")
        }
    }

    /// Convert a local or remote-tracking ref into a worktree using Hermes'
    /// `existingBranch` contract. Passing `origin/feature` to branch/switch is
    /// not equivalent: it can fail or detach HEAD instead of creating the
    /// tracking local branch that the desktop flow promises.
    func addExistingGitWorktree(path: String, branch: String) async throws {
        let response = try await restJSON(path: "api/git/worktree/add", method: "POST",
                                          body: .object([
                                            "path": .string(path),
                                            "existingBranch": .string(branch),
                                          ]), timeout: 120)
        let expectedLocal = branch.split(separator: "/", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? branch
        guard response["path"]?.stringValue?.nilIfEmpty != nil,
              response["branch"]?.stringValue == expectedLocal else {
            throw AckValidationError(operation: "Create branch worktree")
        }
    }

    func switchGitBranch(path: String, branch: String) async throws {
        let response = try await restJSON(path: "api/git/branch/switch", method: "POST", body: .object([
            "path": .string(path), "branch": .string(branch),
        ]), timeout: 60)
        guard response["branch"]?.stringValue == branch else {
            throw AckValidationError(operation: "Switch Git branch")
        }
    }

    func removeGitWorktree(path: String, worktreePath: String, force: Bool = false) async throws {
        let response = try await restJSON(path: "api/git/worktree/remove", method: "POST", body: .object([
            "path": .string(path), "worktreePath": .string(worktreePath), "force": .bool(force),
        ]), timeout: 60)
        guard remotePathsEqual(response["removed"]?.stringValue, worktreePath) else {
            throw AckValidationError(operation: "Remove Git worktree")
        }
    }

    func gitDiff(path: String, file: String, staged: Bool = false) async throws -> String {
        let value = try await restJSON(path: "api/git/review/diff", query: [
            URLQueryItem(name: "path", value: path), URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "scope", value: "uncommitted"),
            URLQueryItem(name: "staged", value: staged ? "true" : "false"),
        ])
        return value["diff"]?.stringValue ?? ""
    }

    func mutateGitFile(path: String, file: String, action: String) async throws {
        guard ["stage", "unstage", "revert"].contains(action) else {
            throw GatewayError(code: -79, message: "Unsupported Git file action.")
        }
        let response = try await restJSON(path: "api/git/review/\(action)", method: "POST", body: .object([
            "path": .string(path), "file": .string(file),
        ]))
        try requireAccepted(response, operation: "Git \(action)")
    }

    func commitGit(path: String, message: String, push: Bool = false) async throws {
        let response = try await restJSON(path: "api/git/review/commit", method: "POST", body: .object([
            "path": .string(path), "message": .string(message), "push": .bool(push),
        ]), timeout: 120)
        try requireAccepted(response, operation: "Git commit")
    }

    func pushGit(path: String) async throws {
        let response = try await restJSON(path: "api/git/review/push", method: "POST",
                                          body: .object(["path": .string(path)]), timeout: 120)
        try requireAccepted(response, operation: "Git push")
    }

    func createPullRequest(path: String) async throws -> URL {
        let response = try await restJSON(path: "api/git/review/create-pr", method: "POST",
                                          body: .object(["path": .string(path)]), timeout: 120)
        guard let raw = response["url"]?.stringValue?.nilIfEmpty,
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AckValidationError(operation: "Create pull request",
                                     detail: "Hermes did not return a valid pull request URL.")
        }
        return url
    }

    func commandCatalog() async throws -> [HermesCommand] {
        let response = try await rpc("commands.catalog")
        let skills = Set(response["skills"]?.objectValue?.keys.map {
            WorkspaceCommandPolicy.canonicalName($0)
        } ?? [])
        let quickCommands = Set(response["categories"]?.arrayValue?.flatMap { category -> [String] in
            guard category["name"]?.stringValue == "User commands" else { return [] }
            return category["pairs"]?.arrayValue?.compactMap {
                $0.arrayValue?.first?.stringValue.map(WorkspaceCommandPolicy.canonicalName)
            } ?? []
        } ?? [])
        let categorizedBuiltIns = Set(response["categories"]?.arrayValue?.flatMap { category -> [String] in
            guard category["name"]?.stringValue != "User commands" else { return [] }
            return category["pairs"]?.arrayValue?.compactMap {
                $0.arrayValue?.first?.stringValue.map(WorkspaceCommandPolicy.canonicalName)
            } ?? []
        } ?? [])
        return response["pairs"]?.arrayValue?.compactMap { pair in
            guard let parts = pair.arrayValue, let name = parts.first?.stringValue?.nilIfEmpty else { return nil }
            let canonical = WorkspaceCommandPolicy.canonicalName(name)
            let origin: HermesCommandOrigin
            // command.dispatch checks user quick commands before skills, so a
            // collision must inherit the executable quick-command risk.
            if quickCommands.contains(canonical) { origin = .quickCommand }
            else if skills.contains(canonical) { origin = .skill }
            else if categorizedBuiltIns.contains(canonical) { origin = .builtIn }
            else { origin = .unclassified }
            return HermesCommand(name: name, summary: parts.dropFirst().first?.stringValue ?? "",
                                 origin: origin)
        } ?? []
    }

    func processes(sessionID: String) async throws -> [HermesProcess] {
        let response = try await rpc("process.list", .object(["session_id": .string(sessionID)]))
        return response["processes"]?.arrayValue?.map(HermesProcess.init) ?? []
    }

    func killProcess(sessionID: String, processID: String) async throws {
        let response = try await rpc("process.kill", .object([
            "session_id": .string(sessionID), "process_id": .string(processID),
        ]))
        guard let status = response["status"]?.stringValue else {
            throw AckValidationError(operation: "Stop background process")
        }
        guard ["killed", "already_exited"].contains(status) else {
            throw GatewayError(code: 409, message: response["error"]?.stringValue
                               ?? "Hermes refused to stop the background process.")
        }
    }

    private func requireAccepted(_ response: JSONValue, operation: String) throws {
        if response["ok"]?.boolValue == false {
            let detail = response["detail"]?.stringValue
                ?? response["message"]?.stringValue
                ?? response["error"]?.stringValue
                ?? "Hermes did not confirm acceptance."
            throw GatewayError(code: -84, message: "\(operation) was refused: \(detail)")
        }
        guard response["ok"]?.boolValue == true else {
            throw AckValidationError(operation: operation)
        }
    }

    private func remotePathsEqual(_ lhs: String?, _ rhs: String) -> Bool {
        remotePathsMatch(lhs, rhs)
    }

    private func requireManagedFence(_ response: JSONValue, target: String,
                                     operation: String) throws {
        guard let locked = response["locked_root"]?.stringValue
            .flatMap(WorkspaceRemotePath.normalized),
              WorkspaceRemotePath.isAbsolute(locked),
              !WorkspaceRemotePath.isFilesystemRoot(locked),
              let normalizedTarget = WorkspaceRemotePath.normalized(target),
              WorkspaceRemotePath.contains(normalizedTarget, in: locked),
              remotePathsMatch(response["root"]?.stringValue, locked) else {
            throw AckValidationError(
                operation: operation,
                detail: "Hermes did not echo the locked managed-files boundary for the accepted write."
            )
        }
    }
}

public enum WorkspaceSensitivePath {
    private static let basenames: Set<String> = [
        "auth.json", "auth.lock", "credentials", "config.yaml",
        ".anthropic_oauth.json", "google_token.json", "google_oauth_pending.json",
        "google_oauth.json", "webhook_subscriptions.json", "bws_cache.json",
        "bws_cache.enc.json", ".git-credentials",
    ]
    private static let directoryNames: Set<String> = ["mcp-tokens", "pairing", ".ssh", ".gnupg"]

    public static func allows(_ path: String) -> Bool {
        let parts = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").map { $0.lowercased() }
        guard let name = parts.last else { return false }
        if name == ".env" || name.hasPrefix(".env.") || name == ".envrc" { return false }
        if basenames.contains(name) { return false }
        return parts.allSatisfy { !directoryNames.contains($0) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func remotePathsMatch(_ lhs: String?, _ rhs: String) -> Bool {
    guard let lhs = lhs.flatMap(WorkspaceRemotePath.normalized),
          let rhs = WorkspaceRemotePath.normalized(rhs) else { return false }
    return WorkspaceRemotePath.contains(lhs, in: rhs)
        && WorkspaceRemotePath.contains(rhs, in: lhs)
}
