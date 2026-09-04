import Foundation
import Observation

@Observable
final class OpenRouterSettingsViewModel {
    private static let modelCatalogRefreshInterval: TimeInterval = 24 * 60 * 60

    enum TestState: Equatable {
        case idle
        case success(OpenRouterConfigurationCheck)
        case failure(String)
    }

    var replacementAPIKey = ""
    var modelIdentifier = ""
    var costTier: OpenRouterCostTier = .low
    private(set) var modelOptions: [OpenRouterModelOption] = []
    private(set) var hasStoredAPIKey = false
    private(set) var isTesting = false
    private(set) var isLoadingModels = false
    private(set) var statusMessage: String?
    private(set) var testState: TestState = .idle

    var canLoadModels: Bool {
        hasStoredAPIKey || !replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isAutoRouterSelected: Bool {
        modelIdentifier.isOpenRouterAutoRouterIdentifier
    }

    private let secretStore: any SecretStoring
    private let settingsStore: any OpenRouterSettingsStoring
    private let configurationChecker: any OpenRouterConfigurationChecking
    private let modelCatalog: any OpenRouterModelCatalogProviding
    private let now: () -> Date

    init(
        secretStore: any SecretStoring = KeychainSecretStore(),
        settingsStore: any OpenRouterSettingsStoring = UserDefaultsOpenRouterSettingsStore(),
        configurationChecker: any OpenRouterConfigurationChecking = OpenRouterAPIClient(),
        modelCatalog: any OpenRouterModelCatalogProviding = OpenRouterAPIClient(),
        now: @escaping () -> Date = { .now }
    ) {
        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.configurationChecker = configurationChecker
        self.modelCatalog = modelCatalog
        self.now = now
    }

    func load() {
        modelIdentifier = settingsStore.modelIdentifier
        costTier = settingsStore.costTier
        modelOptions = settingsStore.modelCatalogCache?.options ?? []
        selectAvailableModelIfNeeded()
        do {
            hasStoredAPIKey = try secretStore.secret(for: .openRouterAPIKey) != nil
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    func save() {
        do {
            try persistConfiguration()
            statusMessage = "Konfiguration gespeichert."
            testState = .idle
        } catch {
            statusMessage = nil
            testState = .failure(error.localizedDescription)
        }
    }

    func testConfiguration() async {
        guard !isTesting else { return }
        isTesting = true
        statusMessage = nil
        testState = .idle
        defer { isTesting = false }

        do {
            try persistConfiguration()
            guard let apiKey = try secretStore.secret(for: .openRouterAPIKey) else {
                throw OpenRouterClientError.invalidAPIKey
            }
            let result = try await configurationChecker.checkConfiguration(
                apiKey: apiKey,
                modelIdentifier: settingsStore.modelIdentifier
            )
            testState = .success(result)
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    func loadModelOptions(forceRefresh: Bool = false) async {
        guard !isLoadingModels else { return }

        if !forceRefresh,
           let cache = settingsStore.modelCatalogCache,
           !cache.options.isEmpty,
           now().timeIntervalSince(cache.fetchedAt) < Self.modelCatalogRefreshInterval {
            modelOptions = cache.options
            return
        }

        isLoadingModels = true
        statusMessage = nil
        defer { isLoadingModels = false }

        do {
            try persistReplacementAPIKey()
            guard let apiKey = try secretStore.secret(for: .openRouterAPIKey) else {
                throw OpenRouterClientError.invalidAPIKey
            }
            let refreshedOptions = try await modelCatalog.compatibleModels(apiKey: apiKey)
            guard !refreshedOptions.isEmpty else {
                testState = .failure("OpenRouter hat keine passenden Bildmodelle zurückgegeben.")
                return
            }
            modelOptions = refreshedOptions
            settingsStore.modelCatalogCache = OpenRouterModelCatalogCache(
                options: refreshedOptions,
                fetchedAt: now()
            )
            selectAvailableModelIfNeeded()
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    func removeAPIKey() {
        do {
            try secretStore.removeSecret(for: .openRouterAPIKey)
            replacementAPIKey = ""
            hasStoredAPIKey = false
            statusMessage = "API-Schlüssel entfernt."
            testState = .idle
        } catch {
            statusMessage = nil
            testState = .failure(error.localizedDescription)
        }
    }

    private func persistConfiguration() throws {
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelOptions.contains(where: { $0.id == trimmedModel }) else {
            throw OpenRouterClientError.modelUnavailable
        }

        settingsStore.modelIdentifier = trimmedModel
        settingsStore.costTier = costTier
        modelIdentifier = trimmedModel

        try persistReplacementAPIKey()
    }

    private func persistReplacementAPIKey() throws {
        let trimmedKey = replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            try secretStore.setSecret(trimmedKey, for: .openRouterAPIKey)
            replacementAPIKey = ""
            hasStoredAPIKey = true
        }
    }

    private func selectAvailableModelIfNeeded() {
        guard !modelOptions.contains(where: { $0.id == modelIdentifier }) else { return }
        modelIdentifier = modelOptions.first?.id ?? ""
    }
}
