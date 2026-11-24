import Foundation
import Security

enum SecretIdentifier: String, Sendable {
    case openRouterAPIKey = "openrouter.api-key"
}

protocol SecretStoring {
    func secret(for identifier: SecretIdentifier) throws -> String?
    func setSecret(_ secret: String, for identifier: SecretIdentifier) throws
    func removeSecret(for identifier: SecretIdentifier) throws
}

enum SecretStoreError: Error, LocalizedError {
    case invalidEncoding
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "Der API-Schlüssel konnte nicht verarbeitet werden."
        case .unexpectedStatus:
            "Der API-Schlüssel konnte nicht sicher gespeichert werden."
        }
    }
}

struct KeychainSecretStore: SecretStoring, Sendable {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "de.clemensgerbaulet.quantified-self") {
        self.service = service
    }

    func secret(for identifier: SecretIdentifier) throws -> String? {
        var query = baseQuery(for: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
        guard
            let data = item as? Data,
            let secret = String(data: data, encoding: .utf8)
        else {
            throw SecretStoreError.invalidEncoding
        }
        return secret
    }

    func setSecret(_ secret: String, for identifier: SecretIdentifier) throws {
        guard let data = secret.data(using: .utf8) else {
            throw SecretStoreError.invalidEncoding
        }

        let query = baseQuery(for: identifier)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var newItem = query
            attributes.forEach { newItem[$0.key] = $0.value }
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw SecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeSecret(for identifier: SecretIdentifier) throws {
        let status = SecItemDelete(baseQuery(for: identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for identifier: SecretIdentifier) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.rawValue,
        ]
    }
}
