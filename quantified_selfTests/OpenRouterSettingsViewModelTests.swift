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

    @Test("Loading replaces a model that is absent from the catalog")
    func replacesUnavailableStoredModel() {
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

        #expect(viewModel.modelIdentifier == "cached/model")
    }

    @Test("Saving rejects model identifiers outside the loaded catalog")
    func rejectsUnavailableModel() {
        let settings = SettingsStoreStub()
        let viewModel = makeViewModel(
            settings: settings,
            catalog: ModelCatalogStub(result: .success(refreshedOptions))
        )
        viewModel.modelIdentifier = "invented/model"

        viewModel.save()

        #expect(settings.modelIdentifier.isEmpty)
        #expect(viewModel.testState == .failure(
            "Bitte wähle ein aktuell verfügbares Modell aus der geladenen Liste."
        ))
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

        viewModel.costTier = .max
        viewModel.save()

        #expect(settings.costTier == .max)
    }

    private func makeViewModel(
        settings: SettingsStoreStub,
        catalog: ModelCatalogStub
    ) -> OpenRouterSettingsViewModel {
        OpenRouterSettingsViewModel(
            secretStore: SecretStoreStub(),
            settingsStore: settings,
            configurationChecker: ConfigurationCheckerStub(),
            modelCatalog: catalog,
            now: { currentDate }
        )
    }
}

@MainActor
private final class SettingsStoreStub: OpenRouterSettingsStoring {
    var modelIdentifier = ""
    var costTier: OpenRouterCostTier = .low
    var modelCatalogCache: OpenRouterModelCatalogCache?
}

@MainActor
private final class ModelCatalogStub: OpenRouterModelCatalogProviding {
    private let result: Result<[OpenRouterModelOption], Error>
    private(set) var requestCount = 0

    init(result: Result<[OpenRouterModelOption], Error>) {
        self.result = result
    }

    func compatibleModels(apiKey: String) async throws -> [OpenRouterModelOption] {
        requestCount += 1
        return try result.get()
    }
}

private struct SecretStoreStub: SecretStoring {
    func secret(for identifier: SecretIdentifier) throws -> String? { "test-key" }
    func setSecret(_ secret: String, for identifier: SecretIdentifier) throws {}
    func removeSecret(for identifier: SecretIdentifier) throws {}
}

private struct ConfigurationCheckerStub: OpenRouterConfigurationChecking {
    func checkConfiguration(
        apiKey: String,
        modelIdentifier: String
    ) async throws -> OpenRouterConfigurationCheck {
        OpenRouterConfigurationCheck(
            modelIdentifier: modelIdentifier,
            modelName: modelIdentifier,
            supportsImageInput: true,
            supportsStructuredOutput: true
        )
    }
}
