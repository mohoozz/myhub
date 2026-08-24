import Foundation
import Security

enum CredentialError: Error {
    case keychain(OSStatus)
}

/// 连接源凭据的 Keychain 存取（kSecClassGenericPassword，IOS-002）。
/// key 约定："conn.<connectionID>"（《需求分析文档》§5.3）；
/// 生物识别（Face ID / Touch ID）保护可后续叠加 SecAccessControl。
struct CredentialStore {
    private let service = "com.myhub.MyHub.credentials"

    // MARK: - 连接源便捷接口

    static func key(for connectionID: Int64) -> String { "conn.\(connectionID)" }

    func savePassword(_ password: String, for connectionID: Int64) throws {
        try save(password, for: Self.key(for: connectionID))
    }

    func loadPassword(for connectionID: Int64) throws -> String? {
        try load(for: Self.key(for: connectionID))
    }

    func deletePassword(for connectionID: Int64) {
        delete(for: Self.key(for: connectionID))
    }

    // MARK: - 通用接口

    func save(_ password: String, for key: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    func load(for key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
