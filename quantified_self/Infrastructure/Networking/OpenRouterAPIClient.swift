import Foundation
import OSLog

struct OpenRouterConfigurationCheck: Sendable, Equatable {
    let modelIdentifier: String
    let modelName: String
    let supportsImageInput: Bool
    let supportsStructuredOutput: Bool
}

struct OpenRouterModelOption: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}

protocol OpenRouterConfigurationChecking {
    func checkConfiguration(
        apiKey: String,
        modelIdentifier: String
    ) async throws -> OpenRouterConfigurationCheck
}

protocol OpenRouterModelCatalogProviding {
    func compatibleModels(apiKey: String) async throws -> [OpenRouterModelOption]
}

protocol OpenRouterChatCompleting {
    func sendChatCompletion(apiKey: String, body: Data) async throws -> Data
}

enum OpenRouterClientError: Error, LocalizedError, Equatable {
    case invalidAPIKey
    case accessForbidden
    case invalidModelIdentifier
    case modelNotFound
    case invalidRequest
    case insufficientCredits
    case rateLimited
    case timedOut
    case serverError
    case invalidResponse
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Der OpenRouter API-Schlüssel ist ungültig."
        case .accessForbidden:
            "Dieser API-Schlüssel darf die angeforderte Ressource nicht verwenden."
        case .invalidModelIdentifier:
            "Gib eine Modell-ID im Format anbieter/modell ein."
        case .modelNotFound:
            "Das konfigurierte OpenRouter-Modell wurde nicht gefunden."
        case .invalidRequest:
            "OpenRouter konnte die Analyseanfrage nicht verarbeiten."
        case .insufficientCredits:
            "Das OpenRouter-Guthaben reicht für diese Analyse nicht aus."
        case .rateLimited:
            "OpenRouter hat zu viele Anfragen erhalten. Versuche es später erneut."
        case .timedOut:
            "Die Anfrage hat zu lange gedauert. Prüfe deine Verbindung und versuche es erneut."
        case .serverError:
            "OpenRouter ist momentan nicht verfügbar."
        case .invalidResponse:
            "OpenRouter hat eine unerwartete Antwort geliefert."
        case .transportFailure:
            "OpenRouter konnte nicht erreicht werden. Prüfe deine Internetverbindung."
        }
    }
}

struct OpenRouterAPIClient: OpenRouterConfigurationChecking, OpenRouterModelCatalogProviding, OpenRouterChatCompleting {
    private struct ModelResponse: Decodable {
        struct Model: Decodable {
            struct Architecture: Decodable {
                let inputModalities: [String]
            }

            let id: String
            let name: String
            let architecture: Architecture?
            let supportedParameters: [String]?
        }

        let data: Model
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            struct Architecture: Decodable {
                let inputModalities: [String]
            }

            let id: String
            let name: String
            let architecture: Architecture?
            let supportedParameters: [String]?
        }

        let data: [Model]
    }

    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func checkConfiguration(
        apiKey: String,
        modelIdentifier: String
    ) async throws -> OpenRouterConfigurationCheck {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelComponents = trimmedModel.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }
        guard modelComponents.count >= 2, !modelComponents.contains(where: \.isEmpty) else {
            throw OpenRouterClientError.invalidModelIdentifier
        }

        _ = try await performRequest(
            url: baseURL.appending(path: "key"),
            apiKey: trimmedKey
        )

        let modelURL = modelComponents.reduce(baseURL.appending(path: "model")) {
            $0.appending(path: String($1))
        }
        let modelData = try await performRequest(url: modelURL, apiKey: trimmedKey)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(ModelResponse.self, from: modelData) else {
            throw OpenRouterClientError.invalidResponse
        }

        return OpenRouterConfigurationCheck(
            modelIdentifier: response.data.id,
            modelName: response.data.name,
            supportsImageInput: response.data.architecture?.inputModalities.contains("image") == true,
            supportsStructuredOutput: supportsStructuredOutput(response.data.supportedParameters)
        )
    }

    func sendChatCompletion(apiKey: String, body: Data) async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }
        return try await performRequest(
            url: baseURL.appending(path: "chat/completions"),
            apiKey: trimmedKey,
            method: "POST",
            body: body,
            timeout: 90
        )
    }

    func compatibleModels(apiKey: String) async throws -> [OpenRouterModelOption] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }

        var components = URLComponents(
            url: baseURL.appending(path: "models"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "input_modalities", value: "image"),
            URLQueryItem(name: "sort", value: "most-popular"),
        ]
        guard let url = components?.url else { throw OpenRouterClientError.invalidResponse }

        let data = try await performRequest(url: url, apiKey: trimmedKey)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(ModelsResponse.self, from: data) else {
            throw OpenRouterClientError.invalidResponse
        }

        return response.data
            .filter { model in
                model.architecture?.inputModalities.contains("image") == true &&
                    supportsStructuredOutput(model.supportedParameters)
            }
            .map { OpenRouterModelOption(id: $0.id, name: $0.name) }
    }

    private func supportsStructuredOutput(_ parameters: [String]?) -> Bool {
        parameters?.contains("response_format") == true ||
            parameters?.contains("structured_outputs") == true
    }

    private func performRequest(
        url: URL,
        apiKey: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw OpenRouterClientError.timedOut }
            AppLogger.nutritionAnalysis.error("OpenRouter transport request failed")
            throw OpenRouterClientError.transportFailure
        } catch {
            AppLogger.nutritionAnalysis.error("OpenRouter transport request failed")
            throw OpenRouterClientError.transportFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            AppLogger.nutritionAnalysis.debug("OpenRouter request succeeded")
            return data
        case 401:
            throw OpenRouterClientError.invalidAPIKey
        case 403:
            throw OpenRouterClientError.accessForbidden
        case 404:
            throw OpenRouterClientError.modelNotFound
        case 400, 422:
            throw OpenRouterClientError.invalidRequest
        case 402:
            throw OpenRouterClientError.insufficientCredits
        case 429:
            throw OpenRouterClientError.rateLimited
        case 500...599:
            throw OpenRouterClientError.serverError
        default:
            AppLogger.nutritionAnalysis.error("OpenRouter returned an unexpected status code")
            throw OpenRouterClientError.invalidResponse
        }
    }
}
