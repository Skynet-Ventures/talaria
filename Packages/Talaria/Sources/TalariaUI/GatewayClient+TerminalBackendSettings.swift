import Foundation
import TalariaKit

// Profile-scoped companion to the terminal backend catalog. The generic
// config writer below is intentionally the existing guarded/deep-merge path:
// a phone must never read-modify-write the whole `terminal` object and erase
// unknown terminal settings owned by Hermes or another client.

extension GatewayClient {
    func terminalDockerSharedContainerKey(profile: String? = nil) async throws -> String {
        let config = try await restJSON(
            path: "api/config",
            query: Self.terminalBackendProfileQuery(profile),
            timeout: 30
        )
        return config["terminal"]?["docker_shared_container_key"]?.stringValue ?? ""
    }

    /// A nonempty value is an explicit cross-profile trust decision: Hermes
    /// maps profiles with the identical value to one persistent Docker
    /// identity. Writing an empty string restores profile isolation for future
    /// containers. `setGatewayConfigValue` deep-merges only this leaf, so all
    /// unknown `terminal.*` configuration survives intact.
    func setTerminalDockerSharedContainerKey(_ value: String,
                                             profile: String? = nil) async throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try await setGatewayConfigValue(
            path: ["terminal", "docker_shared_container_key"],
            value: .string(normalized),
            profile: Self.terminalBackendProfile(profile)
        )
    }
}
