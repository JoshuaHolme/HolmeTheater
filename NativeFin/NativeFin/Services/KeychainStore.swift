// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security

/// Minimal generic-password keychain wrapper for storing Codable values (e.g. the saved session).
///
/// Items are scoped by `service` plus a per-item `account` name, and are readable after the
/// first unlock so background work can use them.
nonisolated struct KeychainStore: Sendable {
    /// A failed Keychain call, carrying the raw `OSStatus`.
    nonisolated struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error (\(status))." }
    }

    /// Namespace for every item this store reads and writes; typically the bundle identifier.
    let service: String

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Encodes `value` as JSON and stores it under `account`, replacing any existing item.
    func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)

        // Replace any existing item so save is an upsert.
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Loads and decodes the value stored under `account`, or `nil` if there isn't one.
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

    /// Removes the item stored under `account`, if any.
    func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
