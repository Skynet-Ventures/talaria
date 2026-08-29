import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor AdoptionTaskBox {
    private var task: Task<Void, Never>?

    func store(_ task: Task<Void, Never>) {
        self.task = task
    }

    func wait() async {
        await task?.value
    }
}

@MainActor
private func clearMaintenanceFenceForTest(_ runtime: GatewayMaintenanceRuntime) {
    guard let fence = runtime.fence else { return }
    switch fence.outcome {
    case .pending:
        runtime.releaseDefinite(source: fence.source, action: fence.action)
    case .accepted, .uncertain:
        _ = runtime.acknowledge(source: fence.source, action: fence.action)
    }
}

final class WorkspaceCommandCenterTests: XCTestCase {
    func testWorkspaceRouteDoesNotCollideAcrossGatewayOrProfile() {
        let a = GatewayWorkspaceRoute(gatewayID: "mini", profile: "default")
        let b = GatewayWorkspaceRoute(gatewayID: "lab", profile: "default")
        let c = GatewayWorkspaceRoute(gatewayID: "mini", profile: "worker")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, c.id)
    }

    func testManagedFileListingRequiresLockedCanonicalFence() throws {
        let listing = try ManagedFileListing(validatingManaged: .object([
            "path": .string("/workspace"),
            "parent": .null,
            "root": .string("/workspace"),
            "locked_root": .string("/workspace"),
            "can_change_path": .bool(false),
            "entries": .array([
                .object(["name": .string("src"), "path": .string("/workspace/src"),
                         "is_directory": .bool(true), "size": .number(0)]),
                .object(["name": .string("README.md"), "path": .string("/workspace/README.md"),
                         "is_directory": .bool(false), "size": .number(42),
                         "mime_type": .string("text/markdown")]),
            ]),
        ]))
        XCTAssertEqual(listing.path, "/workspace")
        XCTAssertEqual(listing.lockedRoot, "/workspace")
        XCTAssertFalse(listing.canChangePath)
        XCTAssertEqual(listing.entries.map(\.name), ["src", "README.md"])
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.entries[1].mimeType, "text/markdown")

        XCTAssertThrowsError(try ManagedFileListing(validatingManaged: .object([
            "path": .string("/workspace"), "root": .string("/workspace"),
            "locked_root": .string("/workspace"), "entries": .array([
                .object(["name": .string("escape"), "path": .string("/outside/escape"),
                         "is_directory": .bool(false)]),
            ]),
        ])))
        XCTAssertThrowsError(try ManagedFileListing(validatingManaged: .object([
            "path": .string("/Users/me"), "root": .null, "locked_root": .null,
            "entries": .array([]),
        ])))
    }

    func testManagedFileBodyRejectsNonBase64AndDecodesBytes() throws {
        let body = try ManagedFileBody(validatingManaged: .object([
            "name": .string("note.txt"), "path": .string("/root/note.txt"),
            "size": .number(5), "root": .string("/root"),
            "locked_root": .string("/root"),
            "mime_type": .string("text/plain"),
            "data_url": .string("data:text/plain;base64,aGVsbG8="),
        ]), requestedPath: "/root/note.txt")
        XCTAssertEqual(String(data: body.bytes, encoding: .utf8), "hello")
        XCTAssertThrowsError(try ManagedFileBody(.object([
            "data_url": .string("data:text/plain,secret"),
        ])))
        XCTAssertThrowsError(try ManagedFileBody(.object([
            "size": .number(6), "mime_type": .string("text/plain"),
            "data_url": .string("data:text/plain;base64,aGVsbG8="),
        ])))
    }

    func testManagedFileByteLimitUsesDecodedBytes() throws {
        XCTAssertTrue(WorkspaceFileSizePolicy.allows(
            byteCount: WorkspaceFileSizePolicy.maximumBytes
        ))
        XCTAssertFalse(WorkspaceFileSizePolicy.allows(
            byteCount: WorkspaceFileSizePolicy.maximumBytes + 1
        ))
        let oversized = Data(repeating: 0x61,
                             count: WorkspaceFileSizePolicy.maximumBytes + 1)
        XCTAssertThrowsError(try ManagedFileBody(.object([
            "mime_type": .string("application/octet-stream"),
            "data_url": .string("data:application/octet-stream;base64,\(oversized.base64EncodedString())"),
        ]))) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 413)
        }
    }

    func testProjectAndGitFixturesDecodeWithoutInventingIdentity() {
        let projects = HermesProjectListing(.object([
            "active_id": .string("p_1"),
            "projects": .array([.object([
                "id": .string("p_1"), "slug": .string("app"), "name": .string("App"),
                "primary_path": .string("/work/app"), "archived": .bool(false),
                "folders": .array([.object([
                    "path": .string("/work/app"), "label": .null, "is_primary": .bool(true),
                ])]),
            ])]),
        ]))
        XCTAssertEqual(projects.activeID, "p_1")
        XCTAssertEqual(projects.projects.first?.primaryPath, "/work/app")
        XCTAssertEqual(projects.projects.first?.folders.first?.id, "/work/app")

        let status = HermesGitStatus(.object([
            "branch": .string("feature"), "defaultBranch": .string("main"),
            "ahead": .number(2), "behind": .number(1), "added": .number(8), "removed": .number(3),
            "files": .array([.object([
                "path": .string("Sources/App.swift"), "staged": .bool(true),
                "unstaged": .bool(true), "untracked": .bool(false), "conflicted": .bool(false),
            ])]),
        ]))
        let review = HermesGitFile(.object([
            "path": .string("Sources/App.swift"), "status": .string("M"),
            "staged": .bool(true), "added": .number(8), "removed": .number(3),
        ]))
        XCTAssertEqual(status.branch, "feature")
        XCTAssertEqual(status.files.first?.path, "Sources/App.swift")
        XCTAssertEqual(review.added, 8)
        XCTAssertTrue(review.staged)
    }

    func testProcessFixtureUsesHermesSessionIDAsKillAuthority() {
        let process = HermesProcess(.object([
            "session_id": .string("proc_123"), "command": .string("pytest"),
            "status": .string("running"),
        ]))
        XCTAssertEqual(process.id, "proc_123")
        XCTAssertEqual(process.command, "pytest")
    }

    func testWorkspacePathFenceRejectsParentsAndCatchAllRoots() {
        let roots = WorkspacePathFence.safeRoots([
            "/work/app", "/", "C:/", "/work/app/", #"\\server\share"#,
        ])
        XCTAssertEqual(roots, ["/work/app"])
        XCTAssertTrue(WorkspacePathFence.contains("/work/app/Sources/App.swift", in: roots))
        XCTAssertTrue(WorkspacePathFence.isRoot("/work/app", in: roots))
        XCTAssertFalse(WorkspacePathFence.contains("/work/application/secret", in: roots))
        XCTAssertFalse(WorkspacePathFence.contains("/work/app/../../etc/passwd", in: roots))
        XCTAssertEqual(WorkspacePathFence.normalized(#"\\server\share\repo"#), "//server/share/repo")
        XCTAssertTrue(WorkspacePathFence.contains(#"\\server\share\repo\Sources"#,
                                                   in: [#"\\server\share\repo"#]))
        XCTAssertTrue(WorkspacePathFence.contains(#"c:\WORK\app\Sources"#,
                                                   in: [#"C:\work\App"#]))
        XCTAssertNil(WorkspacePathFence.normalized(#"\\server\share\..\secret"#))
        XCTAssertNil(WorkspacePathFence.normalized(#"C:relative\file"#))
    }

    func testRemoteParentsPreserveWindowsDriveAndUNCRootSemantics() {
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"C:\work\app\Sources"#), "C:/work/app")
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"C:\work"#), "C:/")
        XCTAssertNil(WorkspaceRemotePath.parent(of: #"C:\"#))
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"\\server\share\repo\Sources"#),
                       "//server/share/repo")
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"\\server\share\repo"#),
                       "//server/share")
        XCTAssertNil(WorkspaceRemotePath.parent(of: #"\\server\share"#))
    }

    func testProjectFilesystemListingUsesCamelCaseAndFiltersSecrets() {
        let listing = ManagedFileListing(.object([
            "entries": .array([
                .object(["name": .string("Sources"), "path": .string("/work/app/Sources"),
                         "isDirectory": .bool(true)]),
                .object(["name": .string(".env"), "path": .string("/work/app/.env"),
                         "isDirectory": .bool(false)]),
                .object(["name": .string("auth.json"), "path": .string("/work/app/auth.json"),
                         "isDirectory": .bool(false)]),
            ]),
        ]), source: .project, requestedPath: "/work/app")
        XCTAssertEqual(listing.source, .project)
        XCTAssertEqual(listing.entries.map(\.name), ["Sources"])
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.parent, "/work")
    }

    func testCommandCenterDispatchRejectsEveryCatalogOriginAndNameCollision() {
        for origin in [HermesCommandOrigin.builtIn, .skill, .quickCommand, .unclassified] {
            for name in ["/status", "/help", "/review", "/plugin-shadow"] {
                XCTAssertFalse(WorkspaceCommandPolicy.permitsCommandCenterDispatch(
                    HermesCommand(name: name, summary: "", origin: origin)
                ), "Command Center must not dispatch \(origin) \(name)")
            }
        }
    }

    func testProjectTreeRejectsMalformedNestedSessionMetadata() throws {
        let validPreview: JSONValue = .object([
            "id": .string("session-1"), "profile": .string("work"),
            "title": .string("Session"), "preview": .string("hello"),
        ])
        let validProject: JSONValue = .object([
            "id": .string("project-1"), "sessionCount": .number(1),
            "previewSessions": .array([validPreview]),
        ])
        XCTAssertNotNil(HermesProjectTree(validProject))

        XCTAssertNil(HermesProjectSessionPreview(.object([
            "id": .string("session-1"), "title": .string("No provenance"),
        ])))
        XCTAssertNil(HermesProjectSessionPreview(.object([
            "id": .string("session-1"), "profile": .string("   "),
        ])))
        XCTAssertNil(HermesProjectTree(.object([
            "id": .string("project-1"), "previewSessions": .array([]),
        ])), "sessionCount must be explicit")
        XCTAssertNil(HermesProjectTree(.object([
            "id": .string("project-1"), "sessionCount": .number(-1),
            "previewSessions": .array([]),
        ])), "sessionCount must be nonnegative")
        XCTAssertNil(HermesProjectTree(.object([
            "id": .string("project-1"), "sessionCount": .number(0),
        ])), "previewSessions must be an explicit array")
        XCTAssertNil(HermesProjectTree(.object([
            "id": .string("project-1"), "sessionCount": .number(1),
            "previewSessions": .array([.object(["id": .string("missing-profile")])]),
        ])), "a malformed nested preview must invalidate its project")
        XCTAssertNil(HermesProjectTree(.object([
            "id": .string("project-1"), "sessionCount": .number(0),
            "previewSessions": .array([validPreview]),
        ])), "preview rows cannot exceed the explicit session count")

        XCTAssertThrowsError(try HermesProjectTree.validatedList(from: .object([
            "projects": .array([validProject, .object([
                "id": .string("bad"), "sessionCount": .number(1),
                "previewSessions": .array([.object(["id": .string("missing-profile")])]),
            ])]),
        ])), "a malformed project must not be compactMap-dropped")
        XCTAssertThrowsError(try HermesProjectTree.validatedList(from: .object([
            "projects": .array([validProject]),
            "errors": .array([.string("profile unavailable")]),
        ])), "a partial project response must not publish clickable rows")
    }

    func testProjectSessionWindowRejectsSaturationBoundary() {
        XCTAssertTrue(WorkspaceProjectSessionWindowPolicy.isProvablyComplete(
            totalReportedSessions: 4_999,
            selectedReportedSessions: 12,
            selectedPreviewCount: 12
        ))
        XCTAssertFalse(WorkspaceProjectSessionWindowPolicy.isProvablyComplete(
            totalReportedSessions: 5_000,
            selectedReportedSessions: 12,
            selectedPreviewCount: 12
        ))
        XCTAssertFalse(WorkspaceProjectSessionWindowPolicy.isProvablyComplete(
            totalReportedSessions: 4_999,
            selectedReportedSessions: 12,
            selectedPreviewCount: 11
        ))
    }

    func testUpdateCheckRequiresCanApplyAndPreservesRecommendedCommand() throws {
        let blocked = try HermesUpdateCheck(.object([
            "can_apply": .bool(false),
            "update_command": .string("docker pull example/hermes:latest"),
            "message": .string("Update the managed image."),
        ]))
        XCTAssertFalse(blocked.canApply)
        XCTAssertEqual(blocked.recommendedCommand, "docker pull example/hermes:latest")
        XCTAssertEqual(blocked.message, "Update the managed image.")
        XCTAssertThrowsError(try HermesUpdateCheck(.object([
            "update_available": .bool(true),
        ])))
    }

    func testMalformedSuccessAcknowledgementsAreAmbiguousButRefusalsAreDefinite() {
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(
            AckValidationError(operation: "Create project")
        ))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: 409, message: "ok:false")
        ))
        XCTAssertEqual(AppModel.WorkspaceSystemAction.curator.expectedActionName, "curator-run")
        XCTAssertEqual(AppModel.WorkspaceSystemAction.updateHermes.expectedActionName,
                       "hermes-update")
        XCTAssertNil(AppModel.WorkspaceSystemAction.debugShare.expectedActionName)
        XCTAssertThrowsError(try HermesProjectListing(
            validatingAcknowledgement: .object(["ok": .bool(true)]),
            operation: "Delete project"
        )) { error in
            XCTAssertTrue(error is AckValidationError)
        }
    }

    func testOverlappingSameNameActionCannotCompleteOrPublishFirstBackup() {
        let acknowledgementA = JSONValue.object([
            "name": .string("backup"), "pid": .number(101),
            "archive": .string("/backups/a.zip"),
        ])
        let terminalStatusB = JSONValue.object([
            "name": .string("backup"), "pid": .number(202),
            "running": .bool(false), "exit_code": .number(0),
        ])

        let state = WorkspaceActionPollPolicy.classify(
            terminalStatusB,
            acceptedName: acknowledgementA["name"]?.stringValue ?? "",
            acceptedPID: acknowledgementA["pid"]?.intValue ?? -1
        )
        XCTAssertEqual(state, .untrackable(observedName: "backup", observedPID: 202))

        var publishedArchive: String?
        if case .terminal(exitCode: 0) = state {
            publishedArchive = acknowledgementA["archive"]?.stringValue
        }
        XCTAssertNil(publishedArchive,
                     "a replacement PID must never complete or publish action A's archive")
        XCTAssertEqual(
            WorkspaceActionPollPolicy.classify(
                .object(["name": .string("backup"), "running": .bool(false),
                         "exit_code": .number(0)]),
                acceptedName: "backup", acceptedPID: 101
            ),
            .untrackable(observedName: "backup", observedPID: nil)
        )

        XCTAssertEqual(
            WorkspaceActionPollPolicy.classify(
                .object(["name": .string("backup"), "pid": .number(101),
                         "running": .bool(false), "exit_code": .number(0)]),
                acceptedName: "backup", acceptedPID: 101
            ),
            .terminal(exitCode: 0)
        )
    }

    func testGitReviewMergePreservesMixedIndexAndWorkingTreeState() {
        let status = HermesGitStatus(.object([
            "files": .array([.object([
                "path": .string("App.swift"), "staged": .bool(true), "unstaged": .bool(true),
            ])]),
        ]))
        let review = HermesGitFile(.object([
            "path": .string("App.swift"), "status": .string("M"),
            "added": .number(4), "removed": .number(2),
        ]))
        let merged = WorkspaceGitMerge.detailed([review], status: status)
        XCTAssertEqual(merged.first?.added, 4)
        XCTAssertTrue(merged.first?.staged == true)
        XCTAssertTrue(merged.first?.unstaged == true)
    }

    @MainActor
    func testWorkspaceMutationOwnerCannotBeStrandedByReadGeneration() {
        let runtime = WorkspaceRuntime.shared
        runtime.mutationOwner = nil; runtime.mutationBusy = false
        let owner = runtime.claimMutation()
        XCTAssertNotNil(owner)
        XCTAssertNil(runtime.claimMutation(), "rapid selection/mutation must not issue a second write")
        runtime.gitRequest &+= 1
        runtime.fileRequest &+= 1
        runtime.releaseMutation(try! XCTUnwrap(owner))
        XCTAssertFalse(runtime.mutationBusy)
        XCTAssertNotNil(runtime.claimMutation())
        if let current = runtime.mutationOwner { runtime.releaseMutation(current) }
    }

    @MainActor
    func testSameGatewayRefreshClearsEveryPublishedCapabilityAndSnapshot() {
        let runtime = WorkspaceRuntime.shared
        runtime.gatewayID = "lab"
        runtime.projects = [HermesProject(.object([
            "id": .string("p1"), "name": .string("stale"),
        ]))]
        runtime.commands = [HermesCommand(name: "/status", summary: "", origin: .builtIn)]
        runtime.capability = ["projects": true, "files": true, "git": true,
                              "commands": true, "system": true]
        runtime.systemStatus = .object(["ready": .bool(true)])
        runtime.gitStatus = HermesGitStatus(.object(["branch": .string("old")]))
        runtime.fileRoots = ["/old"]
        runtime.processTargetID = "old-target"
        runtime.processesTargetID = "old-target"
        runtime.processes = [HermesProcess(.object(["session_id": .string("old-process")]))]
        let oldGeneration = runtime.generation

        let generation = runtime.begin(gatewayID: "lab")

        XCTAssertGreaterThan(generation, oldGeneration)
        XCTAssertTrue(runtime.projects.isEmpty)
        XCTAssertTrue(runtime.commands.isEmpty)
        XCTAssertNil(runtime.systemStatus)
        XCTAssertNil(runtime.gitStatus)
        XCTAssertTrue(runtime.fileRoots.isEmpty)
        XCTAssertNil(runtime.processTargetID)
        XCTAssertNil(runtime.processesTargetID)
        XCTAssertTrue(runtime.processes.isEmpty)
        for key in ["projects", "projectActivity", "managedFiles", "files",
                    "projectFiles", "roots", "git", "commands", "system",
                    "usage", "memory", "curator"] {
            XCTAssertEqual(runtime.capability[key], false, "stale capability: \(key)")
        }
        XCTAssertFalse(runtime.matches("lab", oldGeneration))
        _ = runtime.begin(gatewayID: nil)
    }

    @MainActor
    func testManagedTextRemainsReadOnlyUntilAtomicCASExistsAndCountsUTF8() async {
        let model = AppModel()
        do {
            _ = try await model.saveManagedText(path: "/managed/note.txt", source: .managed,
                                                original: Data(), updated: "draft")
            XCTFail("separate GET+POST must not be presented as conflict-safe")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 501)
        } catch { XCTFail("unexpected error: \(error)") }

        let multiByteOverflow = String(
            repeating: "é", count: WorkspaceFileSizePolicy.maximumBytes / 2 + 1
        )
        do {
            _ = try await model.saveManagedText(path: "/managed/note.txt", source: .managed,
                                                original: Data(), updated: multiByteOverflow)
            XCTFail("outbound UTF-8 bytes must be capped")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 413)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testProcessDiscriminatorIncludesEveryAuthorityDimension() {
        let target = WorkspaceProcessTarget(
            route: GatewayBotRoute(gatewayID: "homelab", profile: "research"),
            title: "Research", sessionID: "runtime-42", botID: "bot",
            storedSessionID: "stored"
        )
        XCTAssertEqual(target.discriminator,
                       "gateway homelab · profile @research · session runtime-42")
    }

    @MainActor
    func testProcessRowsRemainBoundToExactSelectedTarget() {
        let runtime = WorkspaceRuntime.shared
        let processA = HermesProcess(.object([
            "session_id": .string("process-a"), "command": .string("one"),
        ]))
        let processB = HermesProcess(.object([
            "session_id": .string("process-b"), "command": .string("two"),
        ]))

        let requestA = runtime.resetProcesses(targetID: "target-a")
        XCTAssertTrue(runtime.publishProcesses([processA], targetID: "target-a",
                                               request: requestA))
        XCTAssertTrue(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: "target-a", processesTargetID: runtime.processesTargetID
        ))

        let requestB = runtime.resetProcesses(targetID: "target-b")
        XCTAssertTrue(runtime.processes.isEmpty)
        XCTAssertNil(runtime.processesTargetID)
        XCTAssertFalse(runtime.publishProcesses([processA], targetID: "target-a",
                                                request: requestA))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: "target-b", processesTargetID: runtime.processesTargetID
        ))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: nil, processesTargetID: "target-a"
        ))

        XCTAssertTrue(runtime.publishProcesses([processB], targetID: "target-b",
                                               request: requestB))
        XCTAssertEqual(runtime.processes.map(\.id), ["process-b"])
        XCTAssertTrue(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: "target-b", processesTargetID: runtime.processesTargetID
        ))
        runtime.resetProcesses(targetID: nil)
    }

    @MainActor
    func testProcessKillCompletionFenceRequiresExactRequestGatewayAndTargets() {
        let runtime = WorkspaceRuntime.shared
        let previousGatewayID = runtime.gatewayID
        let previousGeneration = runtime.generation
        let previousRequest = runtime.processRequest
        let previousTargetID = runtime.processTargetID
        let previousProcessesTargetID = runtime.processesTargetID
        let previousProcesses = runtime.processes
        defer {
            runtime.gatewayID = previousGatewayID
            runtime.generation = previousGeneration
            runtime.processRequest = previousRequest
            runtime.processTargetID = previousTargetID
            runtime.processesTargetID = previousProcessesTargetID
            runtime.processes = previousProcesses
        }

        runtime.gatewayID = "gateway-a"
        runtime.generation = 23
        let request = runtime.resetProcesses(targetID: "target-a")
        runtime.processesTargetID = "target-a"

        XCTAssertTrue(runtime.matchesProcessKill(
            gatewayID: "gateway-a", generation: 23,
            request: request, targetID: "target-a"
        ))
        XCTAssertFalse(runtime.matchesProcessKill(
            gatewayID: "gateway-b", generation: 23,
            request: request, targetID: "target-a"
        ))
        XCTAssertFalse(runtime.matchesProcessKill(
            gatewayID: "gateway-a", generation: 24,
            request: request, targetID: "target-a"
        ))
        XCTAssertFalse(runtime.matchesProcessKill(
            gatewayID: "gateway-a", generation: 23,
            request: request &+ 1, targetID: "target-a"
        ))
        XCTAssertFalse(runtime.matchesProcessKill(
            gatewayID: "gateway-a", generation: 23,
            request: request, targetID: "target-b"
        ))

        runtime.processesTargetID = "target-b"
        XCTAssertFalse(runtime.matchesProcessKill(
            gatewayID: "gateway-a", generation: 23,
            request: request, targetID: "target-a"
        ))
    }

    func testCommandCenterDispatchSurfaceStaysUnavailableDespiteCatalogCapability() {
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.exposesDispatch(capability: nil))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.exposesDispatch(capability: false))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.exposesDispatch(capability: true))
    }

    @MainActor
    func testInitialWorkspaceLoadClearsStaleFilePublication() {
        let runtime = WorkspaceRuntime.shared
        runtime.fileListing = ManagedFileListing(.object([
            "path": .string("/old"), "entries": .array([]),
        ]))
        runtime.fileRoots = ["/old"]
        runtime.fileRootSources = ["/old": .managed]
        let request = runtime.fileRequest
        runtime.clearPublishedFiles()
        XCTAssertNil(runtime.fileListing)
        XCTAssertTrue(runtime.fileRoots.isEmpty)
        XCTAssertTrue(runtime.fileRootSources.isEmpty)
        XCTAssertGreaterThan(runtime.fileRequest, request)
    }

    func testOnlyAmbiguousTransportFailuresFenceMutations() {
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: -5, message: "timeout")
        ))
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: -7, message: "connection lost")
        ))
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(URLError(.timedOut)))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: 409, message: "refused")
        ))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: -3, message: "not connected")
        ))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(URLError(.notConnectedToInternet)))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(AppModel.GatewayRouteError.noRoute))
    }

    func testRemoteBranchWireShapeRetainsWorktreeAuthority() {
        let branch = HermesGitBranch(.object([
            "name": .string("origin/feature"), "isRemote": .bool(true),
            "checkedOut": .bool(false), "worktreePath": .null,
        ]))
        XCTAssertTrue(branch.isRemote)
        XCTAssertNil(branch.worktreePath)
        let checkedOut = HermesGitBranch(.object([
            "name": .string("feature"), "checkedOut": .bool(true),
            "isRemote": .bool(false), "worktreePath": .string("/work/.worktrees/feature"),
        ]))
        XCTAssertEqual(checkedOut.worktreePath, "/work/.worktrees/feature")
    }

    @MainActor
    func testProjectRootMutationInvalidationClearsGitBeforeHydration() {
        let runtime = WorkspaceRuntime.shared
        runtime.gitPath = "/old"
        runtime.gitStatus = HermesGitStatus(.object(["branch": .string("main")]))
        runtime.gitFiles = [HermesGitFile(.object(["path": .string("stale.swift")]))]
        runtime.gitBranches = [HermesGitBranch(.object(["name": .string("main")]))]
        runtime.gitWorktrees = [HermesGitWorktree(.object(["path": .string("/old")]))]
        runtime.capability["git"] = true
        let request = runtime.gitRequest

        let invalidated = runtime.invalidateGit(path: "/new")

        XCTAssertGreaterThan(invalidated, request)
        XCTAssertEqual(runtime.gitPath, "/new")
        XCTAssertNil(runtime.gitStatus)
        XCTAssertTrue(runtime.gitFiles.isEmpty)
        XCTAssertTrue(runtime.gitBranches.isEmpty)
        XCTAssertTrue(runtime.gitWorktrees.isEmpty)
        XCTAssertEqual(runtime.capability["git"], false)
    }

    func testProjectFilesystemContentFailsClosedWithoutRealpathProof() async {
        let client = GatewayClient(baseURL: URL(string: "https://example.invalid")!,
                                   credential: .sessionToken("unused"))
        do {
            _ = try await client.projectFiles(path: "/work/project")
            XCTFail("project listing must not reach an unproven /api/fs boundary")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 501)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        do {
            _ = try await client.projectFile(path: "/work/project/link")
            XCTFail("project content must not reach an unproven /api/fs boundary")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 501)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSafeExportNameNeverCreatesNestedOrControlPaths() {
        XCTAssertEqual(WorkspaceExportName.safe("../secret\\name\n.zip", fallback: "backup.zip"),
                       "secret-name-.zip")
    }

    func testBackupDownloadCapRejectsDeclaredOrObservedOverflow() {
        let cap = WorkspaceBackupDownloadPolicy.maximumBytes
        XCTAssertFalse(WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: NSURLSessionTransferSizeUnknown, writtenBytes: cap
        ))
        XCTAssertTrue(WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: cap + 1, writtenBytes: 0
        ))
        XCTAssertTrue(WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: NSURLSessionTransferSizeUnknown, writtenBytes: cap + 1
        ))
    }

    @MainActor
    func testWorkspaceSourceSwitchClearsOwnedBackupExportAndBinding() throws {
        let runtime = WorkspaceRuntime.shared
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let export = folder.appending(path: "backup.zip")
        try Data("backup".utf8).write(to: export)

        runtime.gatewayID = "old"
        runtime.backupExportURL = export
        runtime.backupDownloadOwner = UUID()
        runtime.backupDownloadRunning = true
        _ = runtime.begin(gatewayID: "new")

        XCTAssertNil(runtime.backupExportURL)
        XCTAssertNil(runtime.backupDownloadOwner)
        XCTAssertFalse(runtime.backupDownloadRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        _ = runtime.begin(gatewayID: nil)
    }

    @MainActor
    func testRealDisconnectDropsWorkspaceScopeAndInvalidatesOperatorReads() async throws {
        let model = AppModel()
        let workspace = WorkspaceRuntime.shared
        let live = LiveRuntime.shared
        let gatewayID = "teardown-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-backup-teardown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let export = folder.appending(path: "backup.zip")
        try Data("backup".utf8).write(to: export)

        workspace.gatewayID = gatewayID
        workspace.projects = [HermesProject(.object(["id": .string("stale")]))]
        workspace.backupExportURL = export
        live.gatewayID = gatewayID
        live.baseURL = nil
        live.generation &+= 1
        let revision = OperatorSettingsRuntime.shared.connectionRevision

        await model.disconnectGateway()

        XCTAssertNil(workspace.gatewayID)
        XCTAssertTrue(workspace.projects.isEmpty)
        XCTAssertNil(workspace.backupExportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertGreaterThan(OperatorSettingsRuntime.shared.connectionRevision, revision)
        XCTAssertNil(live.gatewayID)
    }

    @MainActor
    func testSecondaryTeardownDropsSelectedWorkspaceScopeAndBackupExport() async throws {
        let model = AppModel()
        let workspace = WorkspaceRuntime.shared
        let gatewayID = "secondary-teardown-(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-secondary-backup-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let export = folder.appending(path: "backup.zip")
        try Data("backup".utf8).write(to: export)

        workspace.gatewayID = gatewayID
        workspace.backupExportURL = export
        let revision = OperatorSettingsRuntime.shared.connectionRevision

        await model.detachRoutedEvents(gatewayID: gatewayID)

        XCTAssertNil(workspace.gatewayID)
        XCTAssertNil(workspace.backupExportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertGreaterThan(OperatorSettingsRuntime.shared.connectionRevision, revision)
    }

    @MainActor
    func testCompletedBackupExportSurvivesSectionUnmountUntilCommandCenterDismissal() throws {
        let runtime = WorkspaceRuntime.shared
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-backup-tab-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let export = folder.appending(path: "backup.zip")
        try Data("backup".utf8).write(to: export)

        runtime.gatewayID = "same-source"
        runtime.backupExportURL = export

        // A section disappearing while switching tabs has no cleanup hook.
        XCTAssertNotNil(runtime.backupExportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))

        runtime.endCommandCenter()
        XCTAssertNil(runtime.backupExportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        _ = runtime.begin(gatewayID: nil)
    }

    @MainActor
    func testWorkspaceScopeSwitchPreservesAndConsultsOperatorMaintenanceFence() {
        let maintenance = GatewayMaintenanceRuntime.shared
        let workspace = WorkspaceRuntime.shared
        clearMaintenanceFenceForTest(maintenance)
        _ = workspace.begin(gatewayID: "gateway-a")
        defer {
            clearMaintenanceFenceForTest(maintenance)
            _ = workspace.begin(gatewayID: nil)
        }

        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(maintenance.begin(source: source, action: "backup"))
        maintenance.accept(source: source, action: "backup", pid: 73)
        let owner = workspace.mutationOwner

        _ = workspace.begin(gatewayID: "gateway-b")

        XCTAssertEqual(workspace.mutationOwner, owner,
                       "scope changes must not clear another surface's no-replay owner")
        XCTAssertTrue(workspace.mutationBusy)
        XCTAssertNil(workspace.claimMutation(),
                     "Command Center must not overlap a persistent operator action")
        XCTAssertEqual(maintenance.fence?.outcome, .accepted(pid: 73))
    }

    func testOperatorStatusLateResponsesRequireSourceClientAndConnectionFence() {
        let first = GatewayClient(baseURL: URL(string: "https://first.example")!,
                                  credential: .sessionToken("unused"))
        let replacement = GatewayClient(baseURL: URL(string: "https://second.example")!,
                                        credential: .sessionToken("unused"))
        let client = ObjectIdentifier(first)
        let same = OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: "secondary\u{1f}__gateway__",
            currentScopeKey: "secondary\u{1f}__gateway__",
            capturedViewGeneration: 2, currentViewGeneration: 2,
            capturedConnectionRevision: 7, currentConnectionRevision: 7,
            capturedLiveGeneration: 11, currentLiveGeneration: 11,
            capturedClient: client, currentClient: client)
        XCTAssertTrue(same)
        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: "secondary\u{1f}__gateway__",
            currentScopeKey: "other\u{1f}__gateway__",
            capturedViewGeneration: 2, currentViewGeneration: 2,
            capturedConnectionRevision: 7, currentConnectionRevision: 7,
            capturedLiveGeneration: 11, currentLiveGeneration: 11,
            capturedClient: client, currentClient: client))
        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: "secondary\u{1f}__gateway__",
            currentScopeKey: "secondary\u{1f}__gateway__",
            capturedViewGeneration: 2, currentViewGeneration: 2,
            capturedConnectionRevision: 7, currentConnectionRevision: 8,
            capturedLiveGeneration: 11, currentLiveGeneration: 11,
            capturedClient: client, currentClient: client))
        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: "secondary\u{1f}__gateway__",
            currentScopeKey: "secondary\u{1f}__gateway__",
            capturedViewGeneration: 2, currentViewGeneration: 2,
            capturedConnectionRevision: 7, currentConnectionRevision: 7,
            capturedLiveGeneration: 11, currentLiveGeneration: 12,
            capturedClient: client, currentClient: client))
        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: "secondary\u{1f}__gateway__",
            currentScopeKey: "secondary\u{1f}__gateway__",
            capturedViewGeneration: 2, currentViewGeneration: 2,
            capturedConnectionRevision: 7, currentConnectionRevision: 7,
            capturedLiveGeneration: 11, currentLiveGeneration: 11,
            capturedClient: client, currentClient: ObjectIdentifier(replacement)))
    }

    @MainActor
    func testReconnectSuccessFencesDelayedOperatorStatusBeforeAndAfterDial() async {
        let runtime = OperatorSettingsRuntime.shared
        let sourceKey = "primary\u{1f}__gateway__"
        let client = GatewayClient(baseURL: URL(string: "https://reconnect.example")!,
                                   credential: .sessionToken("unused"))
        let clientID = ObjectIdentifier(client)
        let capturedRevision = runtime.connectionRevision

        runtime.beginReconnectAttempt()
        await Task.yield() // Model the status REST await overlapping the dial.

        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: sourceKey, currentScopeKey: sourceKey,
            capturedViewGeneration: 3, currentViewGeneration: 3,
            capturedConnectionRevision: capturedRevision,
            currentConnectionRevision: runtime.connectionRevision,
            capturedLiveGeneration: 19, currentLiveGeneration: 19,
            capturedClient: clientID, currentClient: clientID),
            "same-client status must be fenced before reconnect completes")
        XCTAssertFalse(OperatorStatusRequestPolicy.allowsPublication(
            isOffline: true, reconnecting: true,
            requestedGatewayID: nil, activeGatewayID: "primary"),
            "a status task restarted during reconnect must stay silent")

        runtime.completeReconnectAttempt()
        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: sourceKey, currentScopeKey: sourceKey,
            capturedViewGeneration: 3, currentViewGeneration: 3,
            capturedConnectionRevision: capturedRevision,
            currentConnectionRevision: runtime.connectionRevision,
            capturedLiveGeneration: 19, currentLiveGeneration: 19,
            capturedClient: clientID, currentClient: clientID),
            "a successful reconnect must keep the pre-dial response stale")
    }

    @MainActor
    func testReconnectFailureKeepsDelayedOperatorStatusFenced() async {
        let runtime = OperatorSettingsRuntime.shared
        let sourceKey = "primary\u{1f}__gateway__"
        let client = GatewayClient(baseURL: URL(string: "https://failed-reconnect.example")!,
                                   credential: .sessionToken("unused"))
        let clientID = ObjectIdentifier(client)
        let capturedRevision = runtime.connectionRevision

        runtime.beginReconnectAttempt()
        await Task.yield() // Model a failed client.connect returning later.

        XCTAssertFalse(OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: sourceKey, currentScopeKey: sourceKey,
            capturedViewGeneration: 4, currentViewGeneration: 4,
            capturedConnectionRevision: capturedRevision,
            currentConnectionRevision: runtime.connectionRevision,
            capturedLiveGeneration: 27, currentLiveGeneration: 27,
            capturedClient: clientID, currentClient: clientID),
            "a failed reconnect must not release the pre-dial status response")
        XCTAssertFalse(OperatorStatusRequestPolicy.allowsPublication(
            isOffline: true, reconnecting: false,
            requestedGatewayID: nil, activeGatewayID: "primary"),
            "offline primary status must stay unavailable after dial failure")
    }

    @MainActor
    func testRegistrySecondaryRosterFailureTearsDownWorkspaceBeforePoolDisconnect() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let workspace = WorkspaceRuntime.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://registry-secondary-\(UUID().uuidString).example",
            name: "Registry secondary", credential: .sessionToken("unused")))
        defer { registry.remove(id: gateway.id) }

        let client = GatewayClient(baseURL: try XCTUnwrap(gateway.baseURL),
                                   credential: .sessionToken("unused"))
        await registry.clientPool.adopt(client, for: gateway.id)

        workspace.gatewayID = gateway.id
        workspace.projects = [HermesProject(.object(["id": .string("stale")]))]
        let generation = workspace.generation
        let loadTask = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
        }
        workspace.loadTask = loadTask
        let revision = OperatorSettingsRuntime.shared.connectionRevision

        await registry.enumerateSecondaryRosters(excluding: [], minInterval: 0)

        XCTAssertNil(workspace.gatewayID)
        XCTAssertTrue(workspace.projects.isEmpty)
        XCTAssertGreaterThan(workspace.generation, generation)
        XCTAssertFalse(workspace.matches(gateway.id, generation),
                       "registry teardown must fence in-flight workspace loads")
        XCTAssertTrue(loadTask.isCancelled)
        XCTAssertGreaterThan(OperatorSettingsRuntime.shared.connectionRevision, revision)
        let disconnectedClient = await registry.clientPool.client(for: gateway.id)
        XCTAssertNil(disconnectedClient, "the failed roster client must still be released")
        _ = await loadTask.value
        _ = model
    }

    @MainActor
    func testStaleSecondaryRosterFailureCannotTearDownAdoptedReplacement() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let workspace = WorkspaceRuntime.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://registry-replacement-\(UUID().uuidString).example",
            name: "Registry replacement", credential: .sessionToken("unused")))
        defer { registry.remove(id: gateway.id) }

        let baseURL = try XCTUnwrap(gateway.baseURL)
        let oldClient = GatewayClient(baseURL: baseURL, credential: .sessionToken("old"))
        let replacement = GatewayClient(baseURL: baseURL, credential: .sessionToken("new"))
        await registry.clientPool.adopt(oldClient, for: gateway.id)
        let oldConnection = try await registry.clientPool.connectWithGeneration(
            gatewayID: gateway.id, baseURL: baseURL, credential: .sessionToken("old"))

        workspace.gatewayID = gateway.id
        workspace.projects = [HermesProject(.object(["id": .string("replacement-state")]))]
        let generation = workspace.generation
        let revision = OperatorSettingsRuntime.shared.connectionRevision

        // Model an old profiles.list failure arriving after primary adoption
        // has installed a replacement client in the same pool slot.
        await registry.clientPool.adopt(replacement, for: gateway.id)
        let staleTeardown = await registry.teardownSecondaryConnection(
            gatewayID: gateway.id, expected: oldConnection)
        XCTAssertFalse(staleTeardown)

        XCTAssertEqual(workspace.gatewayID, gateway.id)
        XCTAssertEqual(workspace.projects.first?.id, "replacement-state")
        XCTAssertEqual(workspace.generation, generation)
        XCTAssertEqual(OperatorSettingsRuntime.shared.connectionRevision, revision)
        let current = try await registry.clientPool.connectWithGeneration(
            gatewayID: gateway.id, baseURL: baseURL, credential: .sessionToken("new"))
        XCTAssertEqual(ObjectIdentifier(current.client), ObjectIdentifier(replacement))
        XCTAssertEqual(current.generation, oldConnection.generation &+ 1)

        await model.detachRoutedEvents(gatewayID: gateway.id)
        await registry.clientPool.disconnect(gatewayID: gateway.id)
        _ = workspace.begin(gatewayID: nil)
    }

    @MainActor
    func testSecondaryTeardownDisconnectsCapturedClientAfterMetadataRemoval() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://registry-removed-" + UUID().uuidString + ".example",
            name: "Removed registry row", credential: .sessionToken("unused")))
        let baseURL = try XCTUnwrap(gateway.baseURL)
        let client = GatewayClient(baseURL: baseURL, credential: .sessionToken("unused"))
        await registry.clientPool.adopt(client, for: gateway.id)
        let captured = try await registry.clientPool.connectWithGeneration(
            gatewayID: gateway.id, baseURL: baseURL, credential: .sessionToken("unused"))

        // Metadata can be deleted after the roster request captured its exact
        // transport. The transport still needs the guarded teardown.
        registry.remove(id: gateway.id)
        let toreDown = await registry.teardownSecondaryConnection(
            gatewayID: gateway.id, expected: captured)
        let pooled = await registry.clientPool.client(for: gateway.id)
        let connected = await client.isConnected
        XCTAssertTrue(toreDown)
        XCTAssertNil(pooled)
        XCTAssertFalse(connected)
        _ = model
    }

    @MainActor
    func testRemovedMetadataCannotLetTeardownDisconnectAnActiveCapturedClient() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://registry-removed-active-" + UUID().uuidString + ".example",
            name: "Removed active row", credential: .sessionToken("unused")))
        let baseURL = try XCTUnwrap(gateway.baseURL)
        let client = GatewayClient(baseURL: baseURL, credential: .sessionToken("unused"))
        await registry.clientPool.adopt(client, for: gateway.id)
        let captured = try await registry.clientPool.connectWithGeneration(
            gatewayID: gateway.id, baseURL: baseURL, credential: .sessionToken("unused"))
        let wasConnected = await client.isConnected

        registry.remove(id: gateway.id)
        // `noteState` still records the live-source beacon even though the
        // metadata row is gone; the stale secondary failure must not close it.
        registry.noteState(.connected, forURL: baseURL)
        let toreDown = await registry.teardownSecondaryConnection(
            gatewayID: gateway.id, expected: captured)
        let current = await registry.clientPool.client(for: gateway.id)
        let connected = await client.isConnected
        XCTAssertFalse(toreDown)
        XCTAssertEqual(ObjectIdentifier(current!), ObjectIdentifier(client))
        XCTAssertEqual(connected, wasConnected)
        await registry.clientPool.disconnect(gatewayID: gateway.id)
        _ = model
    }

    @MainActor
    func testSecondaryHealthDoesNotReplacePrimaryLiveBeacon() {
        let defaults = UserDefaults(suiteName: "talaria-health-\(UUID().uuidString)")!
        let registry = ConnectionRegistry(defaults: defaults)
        let primary = try! XCTUnwrap(registry.upsert(
            urlString: "https://health-primary-\(UUID().uuidString).example",
            name: "Primary", credential: nil))
        let secondary = try! XCTUnwrap(registry.upsert(
            urlString: "https://health-secondary-\(UUID().uuidString).example",
            name: "Secondary", credential: nil))
        let primaryURL = try! XCTUnwrap(primary.baseURL)
        let secondaryURL = try! XCTUnwrap(secondary.baseURL)

        registry.noteState(.connected, pingMS: 4, forURL: primaryURL)
        registry.noteProbeHealth(.init(state: .connected, pingMS: 21,
                                       version: "secondary", authRequired: false),
                                 forURL: secondaryURL)

        XCTAssertEqual(registry.liveGatewayURL, primaryURL)
        XCTAssertEqual(registry.health[primary.id]?.state, .connected)
        XCTAssertEqual(registry.health[secondary.id]?.state, .connected)
        XCTAssertEqual(registry.health[secondary.id]?.version, "secondary")
    }

    @MainActor
    func testSwitchingPrimaryClearsOldGatewayLiveTransportProjection() throws {
        let defaults = UserDefaults(suiteName: "talaria-primary-switch-\(UUID().uuidString)")!
        let registry = ConnectionRegistry(defaults: defaults)
        let first = try XCTUnwrap(registry.upsert(
            urlString: "https://switch-first-\(UUID().uuidString).example",
            name: "First", credential: nil))
        let second = try XCTUnwrap(registry.upsert(
            urlString: "https://switch-second-\(UUID().uuidString).example",
            name: "Second", credential: nil))
        let firstURL = try XCTUnwrap(first.baseURL)
        let secondURL = try XCTUnwrap(second.baseURL)

        registry.noteProbeHealth(.init(state: .asleep), forURL: firstURL)
        registry.noteState(.connected, forURL: firstURL)
        XCTAssertEqual(registry.health[first.id]?.state, .connected)

        registry.noteState(.connected, forURL: secondURL)

        XCTAssertEqual(registry.liveGatewayURL, secondURL)
        XCTAssertNil(registry.health[first.id]?.liveTransportState)
        XCTAssertEqual(registry.health[first.id]?.state, .asleep,
                       "the former primary must return to its host-reachability projection")
        XCTAssertEqual(registry.health[second.id]?.liveTransportState, .connected)
    }

    @MainActor
    func testRefreshConnectionHealthKeepsHealthySecondaryDiagnosticOnly() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let supervisor = ConnectionSupervisor.shared
        let runtime = LiveRuntime.shared
        let primary = try XCTUnwrap(registry.upsert(
            urlString: "https://refresh-primary-\(UUID().uuidString).example",
            name: "Refresh primary", credential: nil))
        let secondary = try XCTUnwrap(registry.upsert(
            urlString: "https://refresh-secondary-\(UUID().uuidString).example",
            name: "Refresh secondary", credential: nil))
        let primaryURL = try XCTUnwrap(primary.baseURL)
        let previousProbe = supervisor.healthProbe
        let previousPrimaryDiagnostics = supervisor.diagnostics[primary.id]
        let previousSecondaryDiagnostics = supervisor.diagnostics[secondary.id]
        let previousMode = model.mode
        let previousClient = model.client
        let previousBaseURL = runtime.baseURL
        let previousGatewayID = runtime.gatewayID

        defer {
            supervisor.healthProbe = previousProbe
            supervisor.diagnostics[primary.id] = previousPrimaryDiagnostics
            supervisor.diagnostics[secondary.id] = previousSecondaryDiagnostics
            model.mode = previousMode
            model.client = previousClient
            runtime.baseURL = previousBaseURL
            runtime.gatewayID = previousGatewayID
            registry.remove(id: primary.id)
            registry.remove(id: secondary.id)
            _ = AppModel()
        }

        model.mode = .live
        model.client = GatewayClient(baseURL: primaryURL,
                                     credential: .sessionToken("unused"))
        runtime.baseURL = primaryURL
        runtime.gatewayID = primary.id
        registry.noteState(.connected, pingMS: 3, forURL: primaryURL)
        supervisor.healthProbe = { gateway in
            if gateway.id == primary.id {
                return (.connected, GatewayDiagnostics(version: "primary",
                                                        authMode: .open,
                                                        pingMS: 5))
            }
            if gateway.id == secondary.id {
                return (.connected, GatewayDiagnostics(version: "secondary",
                                                        authMode: .oauth,
                                                        pingMS: 11))
            }
            return (.offline, GatewayDiagnostics(lastError: "test fixture"))
        }

        await model.refreshConnectionHealth()

        XCTAssertEqual(registry.liveGatewayURL, primaryURL,
                       "a healthy secondary probe must not become the active source")
        XCTAssertEqual(registry.health[primary.id]?.state, .connected)
        XCTAssertEqual(registry.health[secondary.id]?.state, .connected)
        XCTAssertEqual(registry.health[secondary.id]?.pingMS, 11)
        XCTAssertEqual(registry.health[secondary.id]?.version, "secondary")
        XCTAssertTrue(registry.health[secondary.id]?.authRequired == true)
    }

    @MainActor
    func testHealthyStatusProbeCannotRelabelOfflinePrimaryTransportConnected() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let supervisor = ConnectionSupervisor.shared
        let runtime = LiveRuntime.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://split-health-\(UUID().uuidString).example",
            name: "Split health", credential: nil))
        let baseURL = try XCTUnwrap(gateway.baseURL)
        let previousProbe = supervisor.healthProbe
        let previousDiagnostics = supervisor.diagnostics[gateway.id]
        let previousMode = model.mode
        let previousClient = model.client
        let previousOffline = model.isOffline
        let previousBaseURL = runtime.baseURL
        let previousGatewayID = runtime.gatewayID

        defer {
            supervisor.healthProbe = previousProbe
            supervisor.diagnostics[gateway.id] = previousDiagnostics
            model.mode = previousMode
            model.client = previousClient
            model.isOffline = previousOffline
            runtime.baseURL = previousBaseURL
            runtime.gatewayID = previousGatewayID
            registry.remove(id: gateway.id)
            _ = AppModel()
        }

        model.mode = .live
        model.client = GatewayClient(baseURL: baseURL,
                                     credential: .sessionToken("unused"))
        model.isOffline = true
        runtime.baseURL = baseURL
        runtime.gatewayID = gateway.id
        registry.noteState(.offline, forURL: baseURL)
        supervisor.healthProbe = { _ in
            (.connected, GatewayDiagnostics(version: "reachable-host",
                                             authMode: .oauth,
                                             pingMS: 7))
        }

        await model.refreshConnectionHealth()

        let health = try XCTUnwrap(registry.health[gateway.id])
        XCTAssertEqual(health.hostState, .connected,
                       "the diagnostics surface must retain HTTP reachability")
        XCTAssertEqual(health.liveTransportState, .offline,
                       "the active authenticated transport remains authoritative")
        XCTAssertEqual(health.state, .offline)
        XCTAssertEqual(model.connections.first { $0.id == gateway.id }?.state, .offline)
        XCTAssertTrue(model.isOffline)
    }

    @MainActor
    func testReplacementAdoptionIsBlockedDuringTeardownCallbackAndStateMutation() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let workspace = WorkspaceRuntime.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://registry-interleave-\(UUID().uuidString).example",
            name: "Registry interleave", credential: .sessionToken("unused")))
        defer {
            registry.setSecondaryTeardown(nil)
            registry.remove(id: gateway.id)
            _ = AppModel()
        }

        let baseURL = try XCTUnwrap(gateway.baseURL)
        let oldClient = GatewayClient(baseURL: baseURL, credential: .sessionToken("old"))
        let replacement = GatewayClient(baseURL: baseURL, credential: .sessionToken("new"))
        let adoption = AdoptionTaskBox()
        await registry.clientPool.adopt(oldClient, for: gateway.id)
        let oldConnection = try await registry.clientPool.connectWithGeneration(
            gatewayID: gateway.id, baseURL: baseURL, credential: .sessionToken("old"))
        workspace.gatewayID = gateway.id
        workspace.projects = [HermesProject(.object(["id": .string("interleaved")]))]

        registry.setSecondaryTeardown { gatewayID, expected in
            // Adoption is intentionally launched while teardown owns the
            // lease.  The pool must hold it until AppModel has dropped the
            // old source scope; awaiting adoption here would deadlock on the
            // same lease and would not model a real reconnect race.
            let task = Task {
                await registry.clientPool.adopt(replacement, for: gatewayID)
            }
            await adoption.store(task)
            await model.detachRoutedEvents(gatewayID: gatewayID, expected: expected)
        }
        let result = await registry.teardownSecondaryConnection(
            gatewayID: gateway.id, expected: oldConnection)

        XCTAssertTrue(result)
        XCTAssertNil(workspace.gatewayID)
        XCTAssertTrue(workspace.projects.isEmpty)
        // Let the adoption task pass the released lease before asserting the
        // replacement identity.  It must not be disconnected by the stale
        // teardown that preceded it.
        await adoption.wait()
        let current = try await registry.clientPool.connectWithGeneration(
            gatewayID: gateway.id, baseURL: baseURL, credential: .sessionToken("new"))
        XCTAssertEqual(ObjectIdentifier(current.client), ObjectIdentifier(replacement))
        await registry.clientPool.disconnect(gatewayID: gateway.id)
    }

}
