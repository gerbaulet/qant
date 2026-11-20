import Foundation
import Testing
@testable import Quant

@MainActor
struct OpenRouterSettingsStoreTests {
    @Test("Server URL persists in user defaults")
    func serverURLPersistence() throws {
        let suiteName = "quantified-self-settings-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstStore = UserDefaultsOpenRouterSettingsStore(defaults: defaults)

        firstStore.serverURL = "https://quant-server.example"

        #expect(UserDefaultsOpenRouterSettingsStore(defaults: defaults).serverURL == "https://quant-server.example")
    }

    @Test("Server URLs reject credentials, paths, query strings, and fragments")
    func serverURLRejectsAmbiguousDestinations() {
        let invalidValues = [
            "https://user@quant-server.example",
            "https://quant-server.example/api/v1",
            "https://quant-server.example?target=other",
            "https://quant-server.example#fragment",
        ]

        for value in invalidValues {
            #expect(throws: OpenRouterClientError.invalidServerURL) {
                try QuantServerEndpoint.parse(value)
            }
        }
    }

    @Test("Plain HTTP is limited to local development")
    func localDevelopmentServerURL() throws {
        #expect(try QuantServerEndpoint.parse("http://127.0.0.1:8080/").absoluteString == "http://127.0.0.1:8080")
        #expect(throws: OpenRouterClientError.invalidServerURL) {
            try QuantServerEndpoint.parse("http://192.168.1.2:8080")
        }
    }

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

    @Test("The Auto Router cost tier persists and defaults to low")
    func costTierPersistence() throws {
        let suiteName = "quantified-self-settings-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = UserDefaultsOpenRouterSettingsStore(defaults: defaults)
        #expect(firstStore.costTier == .low)
        firstStore.costTier = .xhigh

        #expect(UserDefaultsOpenRouterSettingsStore(defaults: defaults).costTier == .xhigh)
    }

    @Test("Provider preference persists and defaults to balanced")
    func providerPreferencePersistence() throws {
        let suiteName = "quantified-self-settings-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = UserDefaultsOpenRouterSettingsStore(defaults: defaults)
        #expect(firstStore.providerPreference == .balanced)
        firstStore.providerPreference = .lowLatency

        #expect(defaults.string(forKey: "openrouter.provider-preference") == "faster")
        #expect(UserDefaultsOpenRouterSettingsStore(defaults: defaults).providerPreference == .lowLatency)
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
