import Foundation
import Testing
@testable import Quant

@MainActor
struct SecretStoreTests {
    @Test("Keychain secrets can be stored, replaced, and removed")
    func keychainLifecycle() throws {
        let store = KeychainSecretStore(service: "quantified-self-tests.\(UUID().uuidString)")
        defer { try? store.removeSecret(for: .openRouterAPIKey) }

        #expect(try store.secret(for: .openRouterAPIKey) == nil)

        try store.setSecret("sk-or-test-first", for: .openRouterAPIKey)
        #expect(try store.secret(for: .openRouterAPIKey) == "sk-or-test-first")

        try store.setSecret("sk-or-test-replacement", for: .openRouterAPIKey)
        #expect(try store.secret(for: .openRouterAPIKey) == "sk-or-test-replacement")

        try store.removeSecret(for: .openRouterAPIKey)
        #expect(try store.secret(for: .openRouterAPIKey) == nil)
    }
}
