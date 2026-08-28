import Foundation
import Testing
@testable import Quant

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

    @Test("Model catalog cache persists options and refresh time")
    func modelCatalogCachePersistence() throws {
        let suiteName = "quantified-self-settings-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = OpenRouterModelCatalogCache(
            options: [OpenRouterModelOption(id: "vision/model", name: "Vision Model")],
            fetchedAt: fetchedAt
        )

        UserDefaultsOpenRouterSettingsStore(defaults: defaults).modelCatalogCache = expected

        #expect(UserDefaultsOpenRouterSettingsStore(defaults: defaults).modelCatalogCache == expected)
    }
}
