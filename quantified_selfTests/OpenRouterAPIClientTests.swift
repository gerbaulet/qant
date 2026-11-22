import Foundation
import Testing
@testable import Quant

@Suite(.serialized)
@MainActor
struct OpenRouterAPIClientTests {
    private let serverBaseURL = URL(string: "https://example.test")!

    @Test("Configuration check uses the Quant Server metadata proxy")
    func configurationCheck() async throws {
        let session = makeSession { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            switch request.url?.path {
            case "/api/v1/key":
                return Self.response(for: request, status: 200, json: #"{"data":{"label":"test"}}"#)
            case "/api/v1/model/google/gemini-test":
                return Self.response(
                    for: request,
                    status: 200,
                    json: #"{"data":{"id":"google/gemini-test","name":"Gemini Test","architecture":{"input_modalities":["text","image"]},"supported_parameters":["temperature","response_format"]}}"#
                )
            default:
                Issue.record("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: "{}")
            }
        }
        let client = OpenRouterAPIClient(session: session)

        let result = try await client.checkConfiguration(
            apiKey: " test-secret ",
            modelIdentifier: " google/gemini-test ",
            serverBaseURL: serverBaseURL
        )

        #expect(result.modelIdentifier == "google/gemini-test")
        #expect(result.modelName == "Gemini Test")
        #expect(result.supportsImageInput)
        #expect(result.supportsStructuredOutput)
    }

    @Test("Unauthorized responses become a safe typed error")
    func unauthorized() async {
        let session = makeSession { request in
            Self.response(for: request, status: 401, json: #"{"error":{"message":"sensitive provider detail"}}"#)
        }
        let client = OpenRouterAPIClient(session: session)

        await #expect(throws: OpenRouterClientError.invalidAPIKey) {
            try await client.checkConfiguration(
                apiKey: "invalid-secret",
                modelIdentifier: "google/gemini-test",
                serverBaseURL: serverBaseURL
            )
        }
    }

    @Test("A missing Tailscale identity gets a specific configuration error")
    func missingTailscaleIdentity() async {
        let session = makeSession { request in
            Self.response(
                for: request,
                status: 401,
                json: #"{"error":{"code":"tailscale_identity_required","message":"Tailscale-Identität fehlt."}}"#
            )
        }
        let client = OpenRouterAPIClient(session: session)

        await #expect(throws: OpenRouterClientError.serverAuthenticationRequired) {
            try await client.checkConfiguration(
                apiKey: "test-secret",
                modelIdentifier: "google/gemini-test",
                serverBaseURL: serverBaseURL
            )
        }
    }

    @Test("Invalid model identifiers fail before networking")
    func invalidModelIdentifier() async {
        let session = makeSession { request in
            Issue.record("Unexpected request: \(request)")
            return Self.response(for: request, status: 500, json: "{}")
        }
        let client = OpenRouterAPIClient(session: session)

        await #expect(throws: OpenRouterClientError.invalidModelIdentifier) {
            try await client.checkConfiguration(
                apiKey: "test-secret",
                modelIdentifier: "missing-provider",
                serverBaseURL: serverBaseURL
            )
        }
    }

    @Test("Chat completions create and poll an authenticated durable job")
    func chatCompletionJob() async throws {
        let body = Data(#"{"model":"example/model"}"#.utf8)
        let upstream = Data(#"{"choices":[{"message":{"content":"{\"mealName\":\"Test\"}"}}],"model":"example/model","provider":"Example","usage":{"prompt_tokens":12,"completion_tokens":4,"cost":0.001}}"#.utf8)
        let trafficLog = RecordingOpenRouterTrafficLog()
        let session = makeSession { request in
            if request.httpMethod == "POST" {
                #expect(request.url?.path == "/api/v1/jobs")
                #expect(Self.bodyData(for: request) == body)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "analysis-request-1")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.timeoutInterval == 30)
                return Self.response(
                    for: request,
                    status: 202,
                    json: #"{"id":"job-123","status":"running"}"#
                )
            }
            #expect(request.url?.path == "/api/v1/jobs/job-123")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return Self.response(
                for: request,
                status: 200,
                json: """
                {"id":"job-123","status":"succeeded","upstream_status":200,"response_body":"\(upstream.base64EncodedString())"}
                """
            )
        }
        let client = OpenRouterAPIClient(
            session: session,
            trafficLog: trafficLog,
            pollIntervalNanoseconds: 0
        )

        var receivedEvents: [NutritionAnalysisStreamEvent] = []
        let response = try await client.sendChatCompletion(
            apiKey: "test-secret",
            body: body,
            idempotencyKey: "analysis-request-1",
            serverBaseURL: serverBaseURL
        ) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.first == .requestStarted)
        #expect(receivedEvents.contains(.responseStarted))
        #expect(receivedEvents.compactMap(\.contentDelta).joined() == #"{"mealName":"Test"}"#)
        #expect(receivedEvents.last == .responseCompleted)
        let json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let choices = try #require(json["choices"] as? [[String: Any]])
        let message = try #require(choices.first?["message"] as? [String: Any])
        #expect(message["content"] as? String == #"{"mealName":"Test"}"#)
        #expect(json["model"] as? String == "example/model")
        #expect(json["provider"] as? String == "Example")
        let entries = await trafficLog.snapshot()
        #expect(entries.count == 2)
        #expect(entries[0].contains("REQUEST POST https://example.test/api/v1/jobs"))
        #expect(entries[0].contains(#"{"model":"example/model"}"#))
        #expect(!entries[0].localizedCaseInsensitiveContains("authorization"))
        #expect(!entries[0].contains("test-secret"))
        #expect(entries[1].contains("RESPONSE 200"))
        #expect(entries[1].contains(#"{\"mealName\":\"Test\"}"#))
    }

    @Test("A failed job preserves the OpenRouter diagnostic")
    func failedJobDiagnostic() async {
        let upstream = Data(#"{"error":{"message":"No endpoints support response_format for this model"}}"#.utf8)
        let session = makeSession { request in
            Self.response(
                for: request,
                status: 200,
                json: """
                {"id":"job-failed","status":"failed","upstream_status":400,"response_body":"\(upstream.base64EncodedString())","failure_code":"upstream_http_error"}
                """
            )
        }
        let client = OpenRouterAPIClient(session: session, pollIntervalNanoseconds: 0)

        await #expect(throws: OpenRouterClientError.apiError(
            statusCode: 400,
            message: "No endpoints support response_format for this model"
        )) {
            try await client.sendChatCompletion(
                apiKey: "test-secret",
                body: Data(#"{"model":"example/model"}"#.utf8),
                idempotencyKey: "analysis-request-2",
                serverBaseURL: serverBaseURL
            )
        }
    }

    @Test("Network failures expose the concrete URL error")
    func networkFailureDiagnostic() async {
        let underlyingError = URLError(.cannotConnectToHost)
        let client = OpenRouterAPIClient(session: makeFailingSession(error: underlyingError))

        do {
            _ = try await client.sendChatCompletion(
                apiKey: "test-secret",
                body: Data(#"{"model":"example/model"}"#.utf8),
                idempotencyKey: "analysis-request-network-failure",
                serverBaseURL: serverBaseURL
            )
            Issue.record("Expected the request to fail")
        } catch let error as OpenRouterClientError {
            guard case let .networkFailure(code, message) = error else {
                Issue.record("Unexpected client error: \(error)")
                return
            }
            #expect(code == URLError.Code.cannotConnectToHost.rawValue)
            #expect(message == underlyingError.localizedDescription)
            #expect(error.localizedDescription.contains("Quant Server"))
            #expect(error.localizedDescription.contains("-1004"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A failed server job exposes its diagnostic code and identifier")
    func failedServerJobDiagnostic() async {
        let session = makeSession { request in
            Self.response(
                for: request,
                status: 200,
                json: #"{"id":"job-diagnostic-123","status":"failed","failure_code":"upstream_transport_error","failure_message":"OpenRouter DNS lookup failed"}"#
            )
        }
        let client = OpenRouterAPIClient(session: session, pollIntervalNanoseconds: 0)

        await #expect(throws: OpenRouterClientError.serverJobFailure(
            code: "upstream_transport_error",
            message: "OpenRouter DNS lookup failed",
            jobIdentifier: "job-diagnostic-123"
        )) {
            try await client.sendChatCompletion(
                apiKey: "test-secret",
                body: Data(#"{"model":"example/model"}"#.utf8),
                idempotencyKey: "analysis-request-server-failure",
                serverBaseURL: serverBaseURL
            )
        }
    }

    @Test("Nutrition analysis uses long polling and is acknowledged explicitly")
    func nutritionAnalysisJob() async throws {
        let privateBody = Data(#"{"user_comment":"private-meal-comment"}"#.utf8)
        let terminalJob = try analysisJobJSON()
        let trafficLog = RecordingOpenRouterTrafficLog()
        let session = makeSession { request in
            switch request.httpMethod {
            case "POST":
                #expect(request.url?.path == "/api/v2/analysis-jobs")
                #expect(Self.bodyData(for: request) == privateBody)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "analysis-v2-1")
                return Self.response(
                    for: request,
                    status: 202,
                    json: #"{"id":"analysis-job-123","status":"running"}"#
                )
            case "GET":
                #expect(request.url?.path == "/api/v2/analysis-jobs/analysis-job-123")
                #expect(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems == [URLQueryItem(name: "wait", value: "25")]
                )
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return Self.response(for: request, status: 200, json: terminalJob)
            case "DELETE":
                #expect(request.url?.path == "/api/v2/analysis-jobs/analysis-job-123")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return Self.response(for: request, status: 204, json: "")
            default:
                Issue.record("Unexpected request: \(request)")
                return Self.response(for: request, status: 405, json: "{}")
            }
        }
        let client = OpenRouterAPIClient(session: session, trafficLog: trafficLog)

        var receivedEvents: [NutritionAnalysisStreamEvent] = []
        let job = try await client.sendNutritionAnalysis(
            apiKey: "test-secret",
            body: privateBody,
            idempotencyKey: "analysis-v2-1",
            serverBaseURL: serverBaseURL
        ) { event in
            receivedEvents.append(event)
        }
        try await client.acknowledgeNutritionAnalysis(
            jobIdentifier: job.id,
            serverBaseURL: serverBaseURL
        )

        #expect(job.status == .succeeded)
        #expect(job.result?.promptVersion == 12)
        #expect(job.result?.policyVersion == 1)
        #expect(job.result?.result?.mealName == "Gemüsecurry mit Reis")
        #expect(job.result?.calls.first?.requestedAt == Date(timeIntervalSince1970: 1_788_115_200))
        #expect(receivedEvents == [.requestStarted, .responseStarted, .responseCompleted])
        let entries = await trafficLog.snapshot()
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { !$0.contains("private-meal-comment") })
        #expect(entries.allSatisfy { !$0.contains("Gemüsecurry mit Reis") })
        #expect(entries.allSatisfy { !$0.contains("test-secret") })
    }

    @Test("A server without the analysis endpoint requires an update")
    func missingNutritionAnalysisEndpoint() async {
        let session = makeSession { request in
            Self.response(for: request, status: 404, json: #"{"error":{"message":"not found"}}"#)
        }
        let client = OpenRouterAPIClient(session: session)

        await #expect(throws: OpenRouterClientError.serverUpdateRequired) {
            try await client.sendNutritionAnalysis(
                apiKey: "test-secret",
                body: Data("{}".utf8),
                idempotencyKey: "analysis-v2-missing",
                serverBaseURL: serverBaseURL
            ) { _ in }
        }
    }

    @Test("Model catalog returns image models with structured output")
    func compatibleModelCatalog() async throws {
        let session = makeSession { request in
            #expect(request.url?.path == "/api/v1/models")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.contains(URLQueryItem(name: "input_modalities", value: "image")) == true)
            return Self.response(
                for: request,
                status: 200,
                json: #"{"data":[{"id":"vision/compatible","name":"Compatible Vision","architecture":{"input_modalities":["text","image"]},"supported_parameters":["response_format"]},{"id":"text/only","name":"Text Only","architecture":{"input_modalities":["text"]},"supported_parameters":["response_format"]}]}"#
            )
        }
        let client = OpenRouterAPIClient(session: session)

        let models = try await client.compatibleModels(
            apiKey: "test-secret",
            serverBaseURL: serverBaseURL
        )

        #expect(models == [OpenRouterModelOption(id: "vision/compatible", name: "Compatible Vision")])
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func analysisJobJSON() throws -> String {
        let encodedResult = try JSONEncoder().encode(
            NutritionAnalysisValidatorTests.validResult()
        )
        let result = try #require(
            JSONSerialization.jsonObject(with: encodedResult) as? [String: Any]
        )
        let payload: [String: Any] = [
            "id": "analysis-job-123",
            "status": "succeeded",
            "result": [
                "result": result,
                "calls": [[
                    "call_number": 1,
                    "sample_number": 1,
                    "attempt_number": 1,
                    "status": "succeeded",
                    "model_identifier": "example/vision-model",
                    "provider_identifier": "Example",
                    "energy_kilocalories": 640,
                    "requested_at": "2026-08-30T18:40:00Z",
                ]],
                "prompt_version": 12,
                "policy_version": 1,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeFailingSession(error: URLError) -> URLSession {
        FailingURLProtocolStub.error = error
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func response(
        for request: URLRequest,
        status: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private nonisolated static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private actor RecordingOpenRouterTrafficLog: OpenRouterTrafficLogging {
    private var entries: [String] = []

    func recordRequest(
        id: UUID,
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) {
        entries.append("REQUEST \(method) \(url.absoluteString) \(headers) \(body.map { String(decoding: $0, as: UTF8.self) } ?? "")")
    }

    func recordResponse(
        id: UUID,
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        entries.append("RESPONSE \(statusCode) \(headers) \(String(decoding: body, as: UTF8.self))")
    }

    func recordFailure(id: UUID, description: String) {
        entries.append("FAILURE \(description)")
    }

    func snapshot() -> [String] { entries }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            fatalError("URLProtocolStub handler was not configured")
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FailingURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var error = URLError(.unknown)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: Self.error)
    }

    override func stopLoading() {}
}
