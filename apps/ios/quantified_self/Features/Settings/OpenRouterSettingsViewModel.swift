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
    var serverURL = ""
    var modelIdentifier = ""
    var costTier: OpenRouterCostTier = .low
    var providerPreference: OpenRouterProviderPreference = .balanced
    private(set) var modelOptions: [OpenRouterModelOption] = []
    private(set) var hasStoredAPIKey = false
    private(set) var isTesting = false
    private(set) var isLoadingModels = false
    private(set) var statusMessage: String?
    private(set) var testState: TestState = .idle

    var canLoadModels: Bool {
        (hasStoredAPIKey || !replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
            (try? QuantServerEndpoint.parse(serverURL)) != nil
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
        serverURL = settingsStore.serverURL
        modelIdentifier = settingsStore.modelIdentifier
        costTier = settingsStore.costTier
        providerPreference = settingsStore.providerPreference
        modelOptions = settingsStore.modelCatalogCache?.options ?? []
        selectAvailableModelIfNeeded()
        do {
            hasStoredAPIKey = try secretStore.secret(for: .openRouterAPIKey) != nil
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    func saveServerURL() {
        do {
            try persistServerURL()
            statusMessage = "Serveradresse automatisch gespeichert."
            testState = .idle
        } catch {
            report(error)
        }
    }

    func persistServerURLIfValid() {
        guard let endpoint = try? QuantServerEndpoint.parse(serverURL) else { return }
        settingsStore.serverURL = endpoint.absoluteString
    }

    func saveAPIKey() {
        guard !replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            try persistReplacementAPIKey()
            statusMessage = "API-Schlüssel sicher gespeichert."
            testState = .idle
        } catch {
            report(error)
        }
    }

    func saveModelIdentifier() {
        do {
            try persistModelConfiguration()
            statusMessage = "Modellauswahl automatisch gespeichert."
            testState = .idle
        } catch {
            report(error)
        }
    }

    func selectModel(_ identifier: String) {
        modelIdentifier = identifier
        saveModelIdentifier()
    }

    func updateCostTier(_ tier: OpenRouterCostTier) {
        costTier = tier
        settingsStore.costTier = tier
        statusMessage = "Kostenstufe automatisch gespeichert."
        testState = .idle
    }

    func updateProviderPreference(_ preference: OpenRouterProviderPreference) {
        providerPreference = preference
        settingsStore.providerPreference = preference
        statusMessage = "Provider-Auswahl automatisch gespeichert."
        testState = .idle
    }

    @discardableResult
    func finishEditing() -> Bool {
        var firstError: Error?
        func attempt(_ operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Persist independently so one malformed field cannot discard another
        // valid value, especially the API key stored in the Keychain.
        attempt { try persistReplacementAPIKey() }
        attempt { try persistServerURL() }
        attempt { try persistModelConfiguration() }

        if let firstError {
            report(firstError)
            return false
        }
        statusMessage = "Änderungen automatisch gespeichert."
        testState = .idle
        return true
    }

    func persistPendingChangesSilently() {
        try? persistReplacementAPIKey()
        if let endpoint = try? QuantServerEndpoint.parse(serverURL) {
            settingsStore.serverURL = endpoint.absoluteString
        }
        if isValidModelIdentifier(modelIdentifier) {
            settingsStore.modelIdentifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            settingsStore.costTier = costTier
            settingsStore.providerPreference = providerPreference
        }
    }

    func testConfiguration() async {
        guard !isTesting else { return }
        isTesting = true
        statusMessage = nil
        testState = .idle
        defer { isTesting = false }

        do {
            try persistReplacementAPIKey()
            try persistServerURL()
            try persistModelConfiguration()
            guard let apiKey = try secretStore.secret(for: .openRouterAPIKey) else {
                throw OpenRouterClientError.invalidAPIKey
            }
            let result = try await configurationChecker.checkConfiguration(
                apiKey: apiKey,
                modelIdentifier: settingsStore.modelIdentifier,
                serverBaseURL: try QuantServerEndpoint.parse(settingsStore.serverURL)
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
            try persistServerURL()
            guard let apiKey = try secretStore.secret(for: .openRouterAPIKey) else {
                throw OpenRouterClientError.invalidAPIKey
            }
            let refreshedOptions = try await modelCatalog.compatibleModels(
                apiKey: apiKey,
                serverBaseURL: try QuantServerEndpoint.parse(settingsStore.serverURL)
            )
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

    private func persistModelConfiguration() throws {
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidModelIdentifier(trimmedModel) else {
            throw OpenRouterClientError.invalidModelIdentifier
        }

        settingsStore.modelIdentifier = trimmedModel
        settingsStore.costTier = costTier
        settingsStore.providerPreference = providerPreference
        modelIdentifier = trimmedModel

        try persistReplacementAPIKey()
    }

    private func persistServerURL() throws {
        let endpoint = try QuantServerEndpoint.parse(serverURL)
        let normalized = endpoint.absoluteString
        settingsStore.serverURL = normalized
        serverURL = normalized
    }

    private func persistReplacementAPIKey() throws {
        let trimmedKey = replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            try secretStore.setSecret(trimmedKey, for: .openRouterAPIKey)
            replacementAPIKey = ""
            hasStoredAPIKey = true
        }
    }

    private func isValidModelIdentifier(_ identifier: String) -> Bool {
        let components = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2 && !components.contains(where: \.isEmpty)
    }

    private func report(_ error: Error) {
        statusMessage = nil
        testState = .failure(error.localizedDescription)
    }

    private func selectAvailableModelIfNeeded() {
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModel.isEmpty else {
            modelIdentifier = trimmedModel
            return
        }
        modelIdentifier = modelOptions.first?.id ?? ""
    }
}
