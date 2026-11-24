import Foundation
import Testing
@testable import Quant

@MainActor
struct OpenRouterSettingsViewModelTests {
    private let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let cachedOptions = [OpenRouterModelOption(id: "cached/model", name: "Cached")]
    private let refreshedOptions = [OpenRouterModelOption(id: "fresh/model", name: "Fresh")]

    @Test("Automatic loading reuses a model catalog fetched within 24 hours")
    func reusesFreshCache() async {
        let settings = SettingsStoreStub()
        settings.modelCatalogCache = OpenRouterModelCatalogCache(
            options: cachedOptions,
            fetchedAt: currentDate.addingTimeInterval(-(24 * 60 * 60) + 1)
        )
        let catalog = ModelCatalogStub(result: .success(refreshedOptions))
        let viewModel = makeViewModel(settings: settings, catalog: catalog)

        viewModel.load()
        await viewModel.loadModelOptions()

        #expect(viewModel.modelOptions == cachedOptions)
        #expect(catalog.requestCount == 0)
    }

    @Test("Automatic loading refreshes a catalog once it is 24 hours old")
    func refreshesStaleCache() async {
        let settings = SettingsStoreStub()
        settings.modelCatalogCache = OpenRouterModelCatalogCache(
            options: cachedOptions,
            fetchedAt: currentDate.addingTimeInterval(-(24 * 60 * 60))
        )
        let catalog = ModelCatalogStub(result: .success(refreshedOptions))
        let viewModel = makeViewModel(settings: settings, catalog: catalog)

        viewModel.load()
        await viewModel.loadModelOptions()

        #expect(viewModel.modelOptions == refreshedOptions)
        #expect(catalog.requestCount == 1)
        #expect(settings.modelCatalogCache == OpenRouterModelCatalogCache(
            options: refreshedOptions,
            fetchedAt: currentDate
        ))
    }

    @Test("Manual refresh bypasses the 24 hour cache")
    func manualRefreshBypassesCache() async {
        let settings = SettingsStoreStub()
        settings.modelCatalogCache = OpenRouterModelCatalogCache(
            options: cachedOptions,
            fetchedAt: currentDate
        )
        let catalog = ModelCatalogStub(result: .success(refreshedOptions))
        let viewModel = makeViewModel(settings: settings, catalog: catalog)

        viewModel.load()
        await viewModel.loadModelOptions(forceRefresh: true)

        #expect(viewModel.modelOptions == refreshedOptions)
        #expect(catalog.requestCount == 1)
    }

    @Test("Loading preserves a manually entered model that is absent from the catalog")
    func preservesManualStoredModel() {
        let settings = SettingsStoreStub()
        settings.modelIdentifier = "removed/model"
        settings.modelCatalogCache = OpenRouterModelCatalogCache(
            options: cachedOptions,
            fetchedAt: currentDate
        )
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )

        viewModel.load()

        #expect(viewModel.modelIdentifier == "removed/model")
    }

    @Test("A manual model identifier saves independently")
    func acceptsManualModel() {
        let settings = SettingsStoreStub()
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )
        viewModel.modelIdentifier = "invented/model"

        viewModel.saveModelIdentifier()

        #expect(settings.modelIdentifier == "invented/model")
        #expect(viewModel.statusMessage == "Modellauswahl automatisch gespeichert.")
    }

    @Test("The Quant Server URL saves independently and is normalized")
    func persistsServerURL() {
        let settings = SettingsStoreStub()
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )
        viewModel.serverURL = "  https://quant-server.example/  "
        viewModel.saveServerURL()

        #expect(settings.serverURL == "https://quant-server.example")
        #expect(viewModel.serverURL == "https://quant-server.example")
    }

    @Test("Automatic URL persistence ignores incomplete values")
    func ignoresIncompleteServerURL() {
        let settings = SettingsStoreStub()
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )
        viewModel.serverURL = "https://"

        viewModel.persistServerURLIfValid()

        #expect(settings.serverURL == "https://quant-server.example")
        #expect(viewModel.testState == .idle)
    }

    @Test("Saving the URL rejects an unencrypted non-local server")
    func rejectsPublicHTTPServerURL() {
        let settings = SettingsStoreStub()
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )
        viewModel.serverURL = "http://quant-server.example"
        viewModel.saveServerURL()

        #expect(viewModel.testState == .failure(
            "Gib eine gültige HTTPS-Adresse für den Quant Server ein."
        ))
    }

    @Test("Saving a manual model rejects a malformed identifier")
    func rejectsMalformedManualModel() {
        let settings = SettingsStoreStub()
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )
        viewModel.modelIdentifier = "invented-model"

        viewModel.saveModelIdentifier()

        #expect(settings.modelIdentifier.isEmpty)
        #expect(viewModel.testState == .failure(
            "Gib eine Modell-ID im Format anbieter/modell ein."
        ))
    }

    @Test("The API key saves even when URL and model are invalid")
    func savesAPIKeyIndependently() {
        let settings = SettingsStoreStub()
        let secrets = SecretStoreStub(secret: nil)
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions)),
            secretStore: secrets
        )
        viewModel.serverURL = "not a URL"
        viewModel.modelIdentifier = "invalid"
        viewModel.replacementAPIKey = "  phone-key  "

        let completed = viewModel.finishEditing()

        #expect(!completed)
        #expect(secrets.storedSecret == "phone-key")
        #expect(viewModel.replacementAPIKey.isEmpty)
        #expect(viewModel.hasStoredAPIKey)
    }

    @Test("Failed refresh does not postpone the next automatic attempt")
    func failedRefreshDoesNotAdvanceCache() async {
        let settings = SettingsStoreStub()
        let staleCache = OpenRouterModelCatalogCache(
            options: cachedOptions,
            fetchedAt: currentDate.addingTimeInterval(-(25 * 60 * 60))
        )
        settings.modelCatalogCache = staleCache
        let catalog = ModelCatalogStub(result: .failure(OpenRouterClientError.transportFailure))
        let viewModel = makeViewModel(settings: settings, catalog: catalog)

        viewModel.load()
        await viewModel.loadModelOptions()
        await viewModel.loadModelOptions()

        #expect(viewModel.modelOptions == cachedOptions)
        #expect(catalog.requestCount == 2)
        #expect(settings.modelCatalogCache == staleCache)
    }

    @Test("Loading and saving preserve the selected Auto Router cost tier")
    func preservesAutoRouterCostTier() {
        let settings = SettingsStoreStub()
        settings.modelIdentifier = "openrouter/auto-beta"
        settings.costTier = .high
        settings.modelCatalogCache = OpenRouterModelCatalogCache(
            options: [OpenRouterModelOption(id: "openrouter/auto-beta", name: "Auto Router (Beta)")],
            fetchedAt: currentDate
        )
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )

        viewModel.load()
        #expect(viewModel.isAutoRouterSelected)
        #expect(viewModel.costTier == .high)

        viewModel.updateCostTier(.max)

        #expect(settings.costTier == .max)
    }

    @Test("Loading and saving preserve the provider preference")
    func preservesProviderPreference() {
        let settings = SettingsStoreStub()
        settings.modelIdentifier = "cached/model"
        settings.providerPreference = .lowLatency
        settings.modelCatalogCache = OpenRouterModelCatalogCache(
            options: cachedOptions,
            fetchedAt: currentDate
        )
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )

        viewModel.load()
        #expect(viewModel.providerPreference == .lowLatency)

        viewModel.updateProviderPreference(.balanced)

        #expect(settings.providerPreference == .balanced)
    }

    private func makeViewModel(
        settings: SettingsStoreStub,
        catalog: ModelCatalogStub,
        secretStore: SecretStoreStub = SecretStoreStub()
    ) -> OpenRouterSettingsViewModel {
        let viewModel = OpenRouterSettingsViewModel(
            secretStore: secretStore,
            settingsStore: settings,
            configurationChecker: ConfigurationCheckerStub(),
            modelCatalog: catalog,
            now: { currentDate }
        )
        viewModel.serverURL = settings.serverURL
        return viewModel
    }
}

@MainActor
private final class SettingsStoreStub: OpenRouterSettingsStoring {
    var serverURL = "https://quant-server.example"
    var modelIdentifier = ""
    var costTier: OpenRouterCostTier = .low
    var providerPreference: OpenRouterProviderPreference = .balanced
    var modelCatalogCache: OpenRouterModelCatalogCache?
}

@MainActor
private final class ModelCatalogStub: OpenRouterModelCatalogProviding {
    private let result: Result<[OpenRouterModelOption], Error>
    private(set) var requestCount = 0

    init(result: Result<[OpenRouterModelOption], Error>) {
        self.result = result
    }

    func compatibleModels(apiKey: String, serverBaseURL: URL) async throws -> [OpenRouterModelOption] {
        requestCount += 1
        return try result.get()
    }
}

private final class SecretStoreStub: SecretStoring {
    private(set) var storedSecret: String?

    init(secret: String? = "test-key") {
        storedSecret = secret
    }

    func secret(for identifier: SecretIdentifier) throws -> String? { storedSecret }
    func setSecret(_ secret: String, for identifier: SecretIdentifier) throws {
        storedSecret = secret
    }
    func removeSecret(for identifier: SecretIdentifier) throws {
        storedSecret = nil
    }
}

private struct ConfigurationCheckerStub: OpenRouterConfigurationChecking {
    func checkConfiguration(
        apiKey: String,
        modelIdentifier: String,
        serverBaseURL: URL
    ) async throws -> OpenRouterConfigurationCheck {
        OpenRouterConfigurationCheck(
            modelIdentifier: modelIdentifier,
            modelName: modelIdentifier,
            supportsImageInput: true,
            supportsStructuredOutput: true
        )
    }
}
