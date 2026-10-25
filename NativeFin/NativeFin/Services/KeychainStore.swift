// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security

/// A minimal generic-password keychain wrapper for storing `Codable` values, such as the saved session.
///
/// Items are scoped by ``service`` plus a per-item `account` name. They're readable after the first
/// unlock since boot, and are tied to this device: they're never synced, or restored onto another
/// device from a backup.
nonisolated struct KeychainStore: Sendable {
    /// An error from a failed Keychain call.
    nonisolated struct KeychainError: LocalizedError {
        /// The result code the Keychain returned.
        let status: OSStatus

        /// A message that includes the raw result code, for diagnostics.
        var errorDescription: String? { "Keychain error (\(status))." }
    }

    /// The namespace for every item this store reads and writes; typically the bundle identifier.
    let service: String

    /// The attributes that identify one item: its class, this store's service, and the account name.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Encodes a value as JSON and stores it, replacing any existing value for the same account.
    ///
    /// - Parameters:
    ///   - value: The value to store.
    ///   - account: The name to store it under.
    /// - Throws: An `EncodingError` if the value can't be encoded, or a ``KeychainError`` if the Keychain
    ///   rejects the write.
    func save<T: Encodable>(_ value: T, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Update in place when the item exists, so there's never a moment with nothing saved.
        var status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let query = baseQuery(account: account).merging(attributes) { _, new in new }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Loads and decodes the value stored for an account.
    ///
    /// - Parameters:
    ///   - type: The type to decode the stored value as.
    ///   - account: The name the value was stored under.
    /// - Returns: The decoded value, or `nil` if nothing is stored for `account`.
    /// - Throws: A ``KeychainError`` if the Keychain can't be read, or a `DecodingError` if the stored
    ///   value isn't a `type`.
    func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Removes the value stored for an account, if there is one.
    ///
    /// - Parameter account: The name the value was stored under.
    func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
