import Foundation
import Security

/// Keychain-backed credential store, keyed by normalized gateway base URL —
/// the iOS analogue of desktop's safeStorage-encrypted token file. Tokens and
/// passwords never touch UserDefaults, files, or logs.
public struct KeychainStore: Sendable {
    public var service: String
    /// Focused package-test seam. Production always leaves this nil and uses
    /// the Security framework path below.
    private let saveOverrideForTesting:
        (@Sendable (GatewayCredential, URL) throws -> Void)?

    public init(service: String = "wtf.talaria.gateway-credentials") {
        self.service = service
        saveOverrideForTesting = nil
    }

    init(service: String = "wtf.talaria.gateway-credentials",
         saveOverrideForTesting: @escaping @Sendable (GatewayCredential, URL) throws -> Void) {
        self.service = service
        self.saveOverrideForTesting = saveOverrideForTesting
    }

    public func save(_ credential: GatewayCredential, for baseURL: URL) throws {
        if let saveOverrideForTesting {
            return try saveOverrideForTesting(credential, baseURL)
        }
        let data = try JSONEncoder().encode(credential)
        let account = Self.account(for: baseURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func load(for baseURL: URL) -> GatewayCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: baseURL),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GatewayCredential.self, from: data)
    }

    public func delete(for baseURL: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: baseURL),
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func account(for baseURL: URL) -> String {
        baseURL.absoluteString.lowercased()
    }
}

public enum KeychainError: Error, Sendable {
    case status(OSStatus)
}
