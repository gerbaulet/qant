import Foundation
import Testing
@testable import quantified_self

@MainActor
struct OpenRouterSettingsStoreTests {
    @Test("Model identifiers persist without involving secret storage")
    func modelPersistence() throws {
        let suiteName = "quantified-self-settings-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = UserDefaultsOpenRouterSettingsStore(defaults: defaults)
        firstStore.modelIdentifier = "google/gemini-test"

        let secondStore = UserDefaultsOpenRouterSettingsStore(defaults: defaults)
        #expect(secondStore.modelIdentifier == "google/gemini-test")
    }
}
