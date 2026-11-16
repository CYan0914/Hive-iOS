import Foundation
import Security

/// API keys live here and nowhere else. Not UserDefaults, not the SQLite file,
/// not a plist: a key that leaks from a database backup is indistinguishable
/// from a key that leaks from a screenshot.
enum Keychain {
    private static let service = "com.cyan0914.hive"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    static func set(_ value: String, for key: String) throws {
        let query = baseQuery(key)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock: readable by a background refresh while the phone is
        // locked, which the P1 local-server mode needs, but still protected.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    static func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    static func exists(_ key: String) -> Bool {
        get(key)?.isEmpty == false
    }
}

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let code):
            return "Keychain 写入失败（状态码 \(code)）"
        }
    }
}
