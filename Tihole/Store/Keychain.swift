import Foundation
import Security

/// Instance passwords live in the Keychain, one generic-password item per
/// instance id. They never touch UserDefaults, logs, or backups to other
/// devices.
enum Keychain {
    private static let service = "com.z19r.tihole.instance-password"

    struct Failure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let detail =
                SecCopyErrorMessageString(status, nil) as String?
                ?? "status \(status)"
            return "Could not save the password to the Keychain: \(detail)"
        }
    }

    private static func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// Stores (or replaces) the password for an instance. Updates in place,
    /// so a failed save never loses the password already stored.
    static func setPassword(_ password: String, for id: UUID) throws {
        let query = baseQuery(for: id)
        let data = Data(password.utf8)

        var status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw Failure(status: status)
        }
    }

    /// The stored password for an instance, or nil when there is none.
    static func password(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }
}
