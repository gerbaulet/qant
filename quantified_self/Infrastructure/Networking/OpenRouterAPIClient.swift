import Foundation
import OSLog

struct OpenRouterConfigurationCheck: Sendable, Equatable {
    let modelIdentifier: String
    let modelName: String
    let supportsImageInput: Bool
    let supportsStructuredOutput: Bool
}

struct OpenRouterModelOption: Codable, Identifiable, Sendable, Equatable {
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
    func sendChatCompletion(
        apiKey: String,
        body: Data,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data
}

extension OpenRouterChatCompleting {
    func sendChatCompletion(
        apiKey: String,
        body: Data,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        try await sendChatCompletion(apiKey: apiKey, body: body)
    }
}

enum OpenRouterClientError: Error, LocalizedError, Equatable {
    case invalidAPIKey
    case accessForbidden
    case invalidModelIdentifier
    case modelUnavailable
    case modelNotFound
    case invalidRequest
    case insufficientCredits
    case rateLimited
    case timedOut
    case serverError
    case invalidResponse
    case transportFailure
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Der OpenRouter API-Schlüssel ist ungültig."
        case .accessForbidden:
            "Dieser API-Schlüssel darf die angeforderte Ressource nicht verwenden."
        case .invalidModelIdentifier:
            "Gib eine Modell-ID im Format anbieter/modell ein."
        case .modelUnavailable:
            "Bitte wähle ein aktuell verfügbares Modell aus der geladenen Liste."
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
        case let .apiError(statusCode, message):
            "OpenRouter-Fehler \(statusCode): \(message)"
        }
    }
}

struct OpenRouterAPIClient: OpenRouterConfigurationChecking, OpenRouterModelCatalogProviding, OpenRouterChatCompleting {
    private static let chatCompletionTimeout: TimeInterval = 5 * 60

    private struct ChatCompletionStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }

            let delta: Delta
        }

        struct Usage: Decodable, Encodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cost: Double?

            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case cost
            }
        }

        struct StreamError: Decodable {
            let message: String
            let code: Int?
        }

        let choices: [Choice]?
        let model: String?
        let provider: String?
        let usage: Usage?
        let error: StreamError?
    }

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
    private let trafficLog: any OpenRouterTrafficLogging

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        trafficLog: any OpenRouterTrafficLogging = FileOpenRouterTrafficLog.shared
    ) {
        self.session = session
        self.baseURL = baseURL
        self.trafficLog = trafficLog
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
        try await sendChatCompletion(apiKey: apiKey, body: body) { _ in }
    }

    func sendChatCompletion(
        apiKey: String,
        body: Data,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }
        return try await performStreamingRequest(
            url: baseURL.appending(path: "chat/completions"),
            apiKey: trimmedKey,
            body: body,
            timeout: Self.chatCompletionTimeout,
            onStreamEvent: onStreamEvent
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

        let requestID = UUID()
        await trafficLog.recordRequest(
            id: requestID,
            method: method,
            url: url,
            headers: request.allHTTPHeaderFields?.filter { key, _ in
                key.caseInsensitiveCompare("Authorization") != .orderedSame
            } ?? [:],
            body: body
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            await trafficLog.recordFailure(id: requestID, description: "Anfrage abgebrochen")
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled {
                await trafficLog.recordFailure(id: requestID, description: "Anfrage abgebrochen")
                throw CancellationError()
            }
            if error.code == .timedOut {
                await trafficLog.recordFailure(id: requestID, description: "Zeitüberschreitung")
                throw OpenRouterClientError.timedOut
            }
            await trafficLog.recordFailure(
                id: requestID,
                description: "Transportfehler: \(error.localizedDescription)"
            )
            AppLogger.nutritionAnalysis.error("OpenRouter transport request failed")
            throw OpenRouterClientError.transportFailure
        } catch {
            await trafficLog.recordFailure(
                id: requestID,
                description: "Transportfehler: \(error.localizedDescription)"
            )
            AppLogger.nutritionAnalysis.error("OpenRouter transport request failed")
            throw OpenRouterClientError.transportFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            await trafficLog.recordFailure(id: requestID, description: "Unerwartete Netzwerkantwort")
            throw OpenRouterClientError.invalidResponse
        }
        let responseHeaders = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
        await trafficLog.recordResponse(
            id: requestID,
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            body: data
        )
        do {
            let validatedData = try validatedResponseData(data, statusCode: httpResponse.statusCode)
            AppLogger.nutritionAnalysis.debug("OpenRouter request succeeded")
            return validatedData
        } catch OpenRouterClientError.invalidResponse {
            AppLogger.nutritionAnalysis.error("OpenRouter returned an unexpected status code")
            throw OpenRouterClientError.invalidResponse
        } catch {
            throw error
        }
    }

    private func performStreamingRequest(
        url: URL,
        apiKey: String,
        body: Data,
        timeout: TimeInterval,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestID = UUID()
        await trafficLog.recordRequest(
            id: requestID,
            method: "POST",
            url: url,
            headers: request.allHTTPHeaderFields?.filter { key, _ in
                key.caseInsensitiveCompare("Authorization") != .orderedSame
            } ?? [:],
            body: body
        )

        do {
            onStreamEvent(.requestStarted)
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenRouterClientError.invalidResponse
            }
            onStreamEvent(.responseStarted)
            let responseHeaders = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
                result[String(describing: item.key)] = String(describing: item.value)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                var responseData = Data()
                for try await byte in bytes {
                    responseData.append(byte)
                }
                await trafficLog.recordResponse(
                    id: requestID,
                    statusCode: httpResponse.statusCode,
                    headers: responseHeaders,
                    body: responseData
                )
                return try validatedResponseData(responseData, statusCode: httpResponse.statusCode)
            }

            let responseData = try await assembledChatCompletion(
                from: bytes,
                onStreamEvent: onStreamEvent
            )
            onStreamEvent(.responseCompleted)
            await trafficLog.recordResponse(
                id: requestID,
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                body: responseData
            )
            AppLogger.nutritionAnalysis.debug("OpenRouter streaming request succeeded")
            return responseData
        } catch is CancellationError {
            await trafficLog.recordFailure(id: requestID, description: "Anfrage abgebrochen")
            throw CancellationError()
        } catch let error as OpenRouterClientError {
            await trafficLog.recordFailure(id: requestID, description: error.localizedDescription)
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                await trafficLog.recordFailure(id: requestID, description: "Anfrage abgebrochen")
                throw CancellationError()
            }
            if error.code == .timedOut {
                await trafficLog.recordFailure(id: requestID, description: "Zeitüberschreitung")
                throw OpenRouterClientError.timedOut
            }
            await trafficLog.recordFailure(
                id: requestID,
                description: "Transportfehler: \(error.localizedDescription)"
            )
            AppLogger.nutritionAnalysis.error("OpenRouter streaming transport request failed")
            throw OpenRouterClientError.transportFailure
        } catch {
            await trafficLog.recordFailure(
                id: requestID,
                description: "Transportfehler: \(error.localizedDescription)"
            )
            AppLogger.nutritionAnalysis.error("OpenRouter streaming request failed")
            throw OpenRouterClientError.transportFailure
        }
    }

    private func assembledChatCompletion(
        from bytes: URLSession.AsyncBytes,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        var content = ""
        var model: String?
        var provider: String?
        var usage: ChatCompletionStreamChunk.Usage?
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
            let chunk = try decoder.decode(ChatCompletionStreamChunk.self, from: data)
            if let streamError = chunk.error {
                throw OpenRouterClientError.apiError(
                    statusCode: streamError.code ?? 500,
                    message: String(streamError.message.prefix(500))
                )
            }
            let contentDelta = chunk.choices?.compactMap(\.delta.content).joined() ?? ""
            if !contentDelta.isEmpty {
                content += contentDelta
                onStreamEvent(.contentDelta(contentDelta))
            }
            model = chunk.model ?? model
            provider = chunk.provider ?? provider
            usage = chunk.usage ?? usage
        }

        guard !content.isEmpty else { throw OpenRouterClientError.invalidResponse }
        var response: [String: Any] = [
            "choices": [["message": ["content": content]]],
        ]
        if let model { response["model"] = model }
        if let provider { response["provider"] = provider }
        if let usage {
            var encodedUsage: [String: Any] = [:]
            if let promptTokens = usage.promptTokens { encodedUsage["prompt_tokens"] = promptTokens }
            if let completionTokens = usage.completionTokens { encodedUsage["completion_tokens"] = completionTokens }
            if let cost = usage.cost { encodedUsage["cost"] = cost }
            response["usage"] = encodedUsage
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func validatedResponseData(_ data: Data, statusCode: Int) throws -> Data {
        switch statusCode {
        case 200..<300:
            return data
        case 401:
            throw OpenRouterClientError.invalidAPIKey
        case 403:
            throw OpenRouterClientError.accessForbidden
        case 404:
            throw OpenRouterClientError.modelNotFound
        case 400, 422:
            throw apiError(from: data, statusCode: statusCode) ?? .invalidRequest
        case 402:
            throw OpenRouterClientError.insufficientCredits
        case 408, 524:
            throw OpenRouterClientError.timedOut
        case 413:
            throw apiError(from: data, statusCode: statusCode) ?? .invalidRequest
        case 429:
            throw apiError(from: data, statusCode: statusCode) ?? .rateLimited
        case 500...599:
            throw apiError(from: data, statusCode: statusCode) ?? .serverError
        default:
            throw OpenRouterClientError.invalidResponse
        }
    }

    private func apiError(from data: Data, statusCode: Int) -> OpenRouterClientError? {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable { let message: String }
            let error: APIError
        }

        guard
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
            !envelope.error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let message = envelope.error.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        return .apiError(statusCode: statusCode, message: String(message))
    }
}
