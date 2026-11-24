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

struct QuantServerAnalysisPayload: Decodable, Sendable, Equatable {
    let result: NutritionAnalysisResult?
    let calls: [AnalysisCallSummary]
    let promptVersion: Int
    let policyVersion: Int
    let errorMessage: String?
}

struct QuantServerAnalysisJob: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable {
        case running
        case succeeded
        case failed
    }

    let id: String
    let status: Status
    let result: QuantServerAnalysisPayload?
    let failureCode: String?
    let failureMessage: String?
    let retryable: Bool?
}

protocol OpenRouterConfigurationChecking {
    func checkConfiguration(
        apiKey: String,
        modelIdentifier: String,
        serverBaseURL: URL
    ) async throws -> OpenRouterConfigurationCheck
}

protocol OpenRouterModelCatalogProviding {
    func compatibleModels(apiKey: String, serverBaseURL: URL) async throws -> [OpenRouterModelOption]
}

protocol OpenRouterChatCompleting {
    func sendChatCompletion(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL
    ) async throws -> Data
    func sendChatCompletion(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data
    func sendNutritionAnalysis(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> QuantServerAnalysisJob
    func acknowledgeNutritionAnalysis(
        jobIdentifier: String,
        serverBaseURL: URL
    ) async throws
}

extension OpenRouterChatCompleting {
    func sendChatCompletion(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        try await sendChatCompletion(
            apiKey: apiKey,
            body: body,
            idempotencyKey: idempotencyKey,
            serverBaseURL: serverBaseURL
        )
    }

    func sendNutritionAnalysis(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> QuantServerAnalysisJob {
        throw OpenRouterClientError.serverUpdateRequired
    }

    func acknowledgeNutritionAnalysis(
        jobIdentifier: String,
        serverBaseURL: URL
    ) async throws {
        throw OpenRouterClientError.serverUpdateRequired
    }
}

enum OpenRouterClientError: Error, LocalizedError, Equatable {
    case invalidServerURL
    case serverUpdateRequired
    case serverAuthenticationRequired
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
    case networkFailure(code: Int, message: String)
    case serverJobFailure(code: String?, message: String, jobIdentifier: String)
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Gib eine gültige HTTPS-Adresse für den Quant Server ein."
        case .serverUpdateRequired:
            "Aktualisiere zuerst den Quant Server, damit er vollständige Mahlzeitenanalysen unterstützt."
        case .serverAuthenticationRequired:
            "Der Quant Server hat keine Tailscale-Identität erhalten. Prüfe Tailscale und verwende die Serve-Adresse."
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
            "Verbindung zum Quant Server fehlgeschlagen.\nUrsache: nicht verfügbar.\nPrüfe Internetverbindung, Tailscale und Serveradresse."
        case let .networkFailure(code, message):
            "Verbindung zum Quant Server fehlgeschlagen.\nUrsache: \(message)\nDiagnose: NSURLErrorDomain (\(code)).\nPrüfe Internetverbindung, Tailscale und Serveradresse."
        case let .serverJobFailure(code, message, jobIdentifier):
            "Der Quant Server konnte den Analyseauftrag nicht abschließen.\nUrsache: \(message)\nDiagnose: Servercode \(code ?? "nicht angegeben"), Auftrag \(jobIdentifier)."
        case let .apiError(statusCode, message):
            "OpenRouter-Fehler \(statusCode): \(message)"
        }
    }
}

struct OpenRouterAPIClient: OpenRouterConfigurationChecking, OpenRouterModelCatalogProviding, OpenRouterChatCompleting, Sendable {
    private static let requestTimeout: TimeInterval = 30
    private static let maximumJobWait: TimeInterval = 3 * 60
    private static let maximumAnalysisJobWait: TimeInterval = 15 * 60
    private static let analysisLongPollSeconds = 25

    private struct RelayJob: Decodable {
        enum Status: String, Decodable {
            case running
            case succeeded
            case failed
        }

        let id: String
        let status: Status
        let upstreamStatus: Int?
        let responseBody: Data?
        let failureCode: String?
        let failureMessage: String?
    }

    private struct CompletedContent: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
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
    private let trafficLog: any OpenRouterTrafficLogging
    private let pollIntervalNanoseconds: UInt64

    init(
        session: URLSession = .shared,
        trafficLog: any OpenRouterTrafficLogging = FileOpenRouterTrafficLog.shared,
        pollIntervalNanoseconds: UInt64 = 500_000_000
    ) {
        self.session = session
        self.trafficLog = trafficLog
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func checkConfiguration(
        apiKey: String,
        modelIdentifier: String,
        serverBaseURL: URL
    ) async throws -> OpenRouterConfigurationCheck {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelComponents = trimmedModel.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }
        guard modelComponents.count >= 2, !modelComponents.contains(where: \.isEmpty) else {
            throw OpenRouterClientError.invalidModelIdentifier
        }

        let baseURL = apiBaseURL(for: serverBaseURL)
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

    func sendChatCompletion(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL
    ) async throws -> Data {
        try await sendChatCompletion(
            apiKey: apiKey,
            body: body,
            idempotencyKey: idempotencyKey,
            serverBaseURL: serverBaseURL
        ) { _ in }
    }

    func sendChatCompletion(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }
        let trimmedIdempotencyKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdempotencyKey.isEmpty else { throw OpenRouterClientError.invalidRequest }
        return try await performRelayJob(
            url: apiBaseURL(for: serverBaseURL).appending(path: "jobs"),
            apiKey: trimmedKey,
            body: body,
            idempotencyKey: trimmedIdempotencyKey,
            onStreamEvent: onStreamEvent
        )
    }

    func sendNutritionAnalysis(
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        serverBaseURL: URL,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> QuantServerAnalysisJob {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdempotencyKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }
        guard !trimmedIdempotencyKey.isEmpty else { throw OpenRouterClientError.invalidRequest }
        return try await performAnalysisJob(
            url: serverBaseURL.appending(path: "api/v2/analysis-jobs"),
            apiKey: trimmedKey,
            body: body,
            idempotencyKey: trimmedIdempotencyKey,
            onStreamEvent: onStreamEvent
        )
    }

    func acknowledgeNutritionAnalysis(
        jobIdentifier: String,
        serverBaseURL: URL
    ) async throws {
        let trimmedIdentifier = jobIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { throw OpenRouterClientError.invalidRequest }
        var request = URLRequest(
            url: serverBaseURL
                .appending(path: "api/v2/analysis-jobs")
                .appending(path: trimmedIdentifier),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenRouterClientError.invalidResponse
            }
            guard httpResponse.statusCode == 204 else {
                if httpResponse.statusCode == 404 {
                    return
                }
                _ = try validatedResponseData(data, statusCode: httpResponse.statusCode)
                throw OpenRouterClientError.invalidResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenRouterClientError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Self.networkFailure(from: error)
        } catch {
            throw OpenRouterClientError.transportFailure
        }
    }

    func compatibleModels(apiKey: String, serverBaseURL: URL) async throws -> [OpenRouterModelOption] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenRouterClientError.invalidAPIKey }

        let baseURL = apiBaseURL(for: serverBaseURL)
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
            let clientError = Self.networkFailure(from: error)
            await trafficLog.recordFailure(
                id: requestID,
                description: clientError.localizedDescription
            )
            AppLogger.nutritionAnalysis.error("OpenRouter transport request failed")
            throw clientError
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

    private func performAnalysisJob(
        url: URL,
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> QuantServerAnalysisJob {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestID = UUID()
        await trafficLog.recordRequest(
            id: requestID,
            method: "POST",
            url: url,
            headers: [:],
            body: nil
        )

        do {
            onStreamEvent(.requestStarted)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenRouterClientError.invalidResponse
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
                await trafficLog.recordResponse(
                    id: requestID,
                    statusCode: httpResponse.statusCode,
                    headers: responseHeaders(httpResponse),
                    body: Data()
                )
                if httpResponse.statusCode == 404 {
                    throw OpenRouterClientError.serverUpdateRequired
                }
                _ = try validatedResponseData(data, statusCode: httpResponse.statusCode)
                throw OpenRouterClientError.invalidResponse
            }

            var job = try decodeAnalysisJob(data)
            onStreamEvent(.responseStarted)
            let deadline = Date.now.addingTimeInterval(Self.maximumAnalysisJobWait)
            while job.status == .running {
                guard Date.now < deadline else { throw OpenRouterClientError.timedOut }
                job = try await longPollAnalysisJob(id: job.id, jobsURL: url)
            }
            if job.status == .failed, job.result == nil {
                let description = Self.nonemptyDiagnostic(job.failureMessage)
                    ?? "Keine weitere Fehlermeldung wurde übermittelt."
                throw OpenRouterClientError.serverJobFailure(
                    code: Self.nonemptyDiagnostic(job.failureCode),
                    message: description,
                    jobIdentifier: String(job.id.prefix(200))
                )
            }
            onStreamEvent(.responseCompleted)
            await trafficLog.recordResponse(
                id: requestID,
                statusCode: httpResponse.statusCode,
                headers: ["X-Quant-Job-ID": job.id],
                body: Data()
            )
            return job
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
            let clientError = Self.networkFailure(from: error)
            await trafficLog.recordFailure(id: requestID, description: clientError.localizedDescription)
            throw clientError
        } catch {
            await trafficLog.recordFailure(
                id: requestID,
                description: "Transportfehler: \(error.localizedDescription)"
            )
            throw OpenRouterClientError.transportFailure
        }
    }

    private func longPollAnalysisJob(id: String, jobsURL: URL) async throws -> QuantServerAnalysisJob {
        var components = URLComponents(
            url: jobsURL.appending(path: id),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "wait", value: String(Self.analysisLongPollSeconds)),
        ]
        guard let url = components?.url else { throw OpenRouterClientError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            _ = try validatedResponseData(data, statusCode: httpResponse.statusCode)
            throw OpenRouterClientError.invalidResponse
        }
        return try decodeAnalysisJob(data)
    }

    private func decodeAnalysisJob(_ data: Data) throws -> QuantServerAnalysisJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid server date"
                )
            }
            return date
        }
        guard let job = try? decoder.decode(QuantServerAnalysisJob.self, from: data) else {
            throw OpenRouterClientError.invalidResponse
        }
        return job
    }

    private func performRelayJob(
        url: URL,
        apiKey: String,
        body: Data,
        idempotencyKey: String,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenRouterClientError.invalidResponse
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
                await trafficLog.recordResponse(
                    id: requestID,
                    statusCode: httpResponse.statusCode,
                    headers: responseHeaders(httpResponse),
                    body: data
                )
                return try validatedResponseData(data, statusCode: httpResponse.statusCode)
            }
            var job = try decodeRelayJob(data)
            onStreamEvent(.responseStarted)
            let deadline = Date.now.addingTimeInterval(Self.maximumJobWait)
            while job.status == .running {
                guard Date.now < deadline else { throw OpenRouterClientError.timedOut }
                if pollIntervalNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                }
                job = try await pollJob(id: job.id, jobsURL: url)
            }
            return try await finish(
                job,
                requestID: requestID,
                onStreamEvent: onStreamEvent
            )
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
            let clientError = Self.networkFailure(from: error)
            await trafficLog.recordFailure(
                id: requestID,
                description: clientError.localizedDescription
            )
            AppLogger.nutritionAnalysis.error("Quant Server transport request failed")
            throw clientError
        } catch {
            await trafficLog.recordFailure(
                id: requestID,
                description: "Transportfehler: \(error.localizedDescription)"
            )
            AppLogger.nutritionAnalysis.error("Quant Server request failed")
            throw OpenRouterClientError.transportFailure
        }
    }

    private func pollJob(id: String, jobsURL: URL) async throws -> RelayJob {
        var request = URLRequest(
            url: jobsURL.appending(path: id),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            _ = try validatedResponseData(data, statusCode: httpResponse.statusCode)
            throw OpenRouterClientError.invalidResponse
        }
        return try decodeRelayJob(data)
    }

    private func finish(
        _ job: RelayJob,
        requestID: UUID,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> Data {
        let responseBody = job.responseBody ?? Data()
        let upstreamStatus = job.upstreamStatus ?? 500
        if job.status == .failed {
            if !responseBody.isEmpty {
                await trafficLog.recordResponse(
                    id: requestID,
                    statusCode: upstreamStatus,
                    headers: ["X-Quant-Job-ID": job.id],
                    body: responseBody
                )
                return try validatedResponseData(responseBody, statusCode: upstreamStatus)
            }
            let description = Self.nonemptyDiagnostic(job.failureMessage)
                ?? "Keine weitere Fehlermeldung wurde übermittelt."
            await trafficLog.recordFailure(id: requestID, description: description)
            throw OpenRouterClientError.serverJobFailure(
                code: Self.nonemptyDiagnostic(job.failureCode),
                message: description,
                jobIdentifier: String(job.id.prefix(200))
            )
        }
        guard job.status == .succeeded, !responseBody.isEmpty else {
            throw OpenRouterClientError.invalidResponse
        }
        if let content = try? JSONDecoder().decode(CompletedContent.self, from: responseBody)
            .choices.first?.message.content,
           !content.isEmpty {
            onStreamEvent(.contentDelta(content))
        }
        onStreamEvent(.responseCompleted)
        await trafficLog.recordResponse(
            id: requestID,
            statusCode: upstreamStatus,
            headers: ["X-Quant-Job-ID": job.id],
            body: responseBody
        )
        AppLogger.nutritionAnalysis.debug("Quant Server job succeeded")
        return try validatedResponseData(responseBody, statusCode: upstreamStatus)
    }

    private func decodeRelayJob(_ data: Data) throws -> RelayJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let job = try? decoder.decode(RelayJob.self, from: data) else {
            throw OpenRouterClientError.invalidResponse
        }
        return job
    }

    private func apiBaseURL(for serverBaseURL: URL) -> URL {
        serverBaseURL.appending(path: "api/v1")
    }

    private func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
    }

    private nonisolated static func networkFailure(from error: URLError) -> OpenRouterClientError {
        .networkFailure(
            code: error.code.rawValue,
            message: nonemptyDiagnostic(error.localizedDescription)
                ?? "Keine weitere Fehlermeldung wurde übermittelt."
        )
    }

    private nonisolated static func nonemptyDiagnostic(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(500))
    }

    private nonisolated func validatedResponseData(_ data: Data, statusCode: Int) throws -> Data {
        switch statusCode {
        case 200..<300:
            return data
        case 401:
            if relayErrorCode(from: data) == "tailscale_identity_required" {
                throw OpenRouterClientError.serverAuthenticationRequired
            }
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

    private nonisolated func apiError(from data: Data, statusCode: Int) -> OpenRouterClientError? {
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

    private nonisolated func relayErrorCode(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct RelayError: Decodable { let code: String }
            let error: RelayError
        }

        return try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.code
    }
}
