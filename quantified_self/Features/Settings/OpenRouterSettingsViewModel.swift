import Foundation
import Observation

@Observable
final class OpenRouterSettingsViewModel {
    enum TestState: Equatable {
        case idle
        case success(OpenRouterConfigurationCheck)
        case failure(String)
    }

    var replacementAPIKey = ""
    var modelIdentifier = ""
    private(set) var hasStoredAPIKey = false
    private(set) var isTesting = false
    private(set) var statusMessage: String?
    private(set) var testState: TestState = .idle

    private let secretStore: any SecretStoring
    private let settingsStore: any OpenRouterSettingsStoring
    private let configurationChecker: any OpenRouterConfigurationChecking

    init(
        secretStore: any SecretStoring = KeychainSecretStore(),
        settingsStore: any OpenRouterSettingsStoring = UserDefaultsOpenRouterSettingsStore(),
        configurationChecker: any OpenRouterConfigurationChecking = OpenRouterAPIClient()
    ) {
        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.configurationChecker = configurationChecker
    }

    func load() {
        modelIdentifier = settingsStore.modelIdentifier
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
        let trimmedKey = replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        settingsStore.modelIdentifier = trimmedModel
        modelIdentifier = trimmedModel

        if !trimmedKey.isEmpty {
            try secretStore.setSecret(trimmedKey, for: .openRouterAPIKey)
            replacementAPIKey = ""
            hasStoredAPIKey = true
        }
    }
}
