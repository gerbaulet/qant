import Foundation
import Testing
@testable import quantified_self

@Suite(.serialized)
@MainActor
struct OpenRouterAPIClientTests {
    @Test("Configuration check validates the key and model capabilities")
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
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        let result = try await client.checkConfiguration(
            apiKey: " test-secret ",
            modelIdentifier: " google/gemini-test "
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
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        await #expect(throws: OpenRouterClientError.invalidAPIKey) {
            try await client.checkConfiguration(
                apiKey: "invalid-secret",
                modelIdentifier: "google/gemini-test"
            )
        }
    }

    @Test("Provider request errors preserve a useful local diagnostic")
    func providerErrorDiagnostic() async {
        let session = makeSession { request in
            Self.response(
                for: request,
                status: 400,
                json: #"{"error":{"message":"No endpoints support response_format for this model"}}"#
            )
        }
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        await #expect(throws: OpenRouterClientError.apiError(
            statusCode: 400,
            message: "No endpoints support response_format for this model"
        )) {
            try await client.sendChatCompletion(apiKey: "test-secret", body: Data("{}".utf8))
        }
    }

    @Test("Malformed model metadata is rejected")
    func malformedModelMetadata() async {
        let session = makeSession { request in
            if request.url?.path == "/api/v1/key" {
                return Self.response(for: request, status: 200, json: "{}")
            }
            return Self.response(for: request, status: 200, json: #"{"data":{"unexpected":true}}"#)
        }
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        await #expect(throws: OpenRouterClientError.invalidResponse) {
            try await client.checkConfiguration(
                apiKey: "test-secret",
                modelIdentifier: "google/gemini-test"
            )
        }
    }

    @Test("Invalid model identifiers fail before networking")
    func invalidModelIdentifier() async {
        let session = makeSession { request in
            Issue.record("Unexpected request: \(request)")
            return Self.response(for: request, status: 500, json: "{}")
        }
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        await #expect(throws: OpenRouterClientError.invalidModelIdentifier) {
            try await client.checkConfiguration(
                apiKey: "test-secret",
                modelIdentifier: "missing-provider"
            )
        }
    }

    @Test("Chat completions use the authenticated JSON endpoint")
    func chatCompletionRequest() async throws {
        let body = Data(#"{"model":"example/model"}"#.utf8)
        let session = makeSession { request in
            #expect(request.url?.path == "/api/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(Self.bodyData(for: request) == body)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            return Self.response(for: request, status: 200, json: #"{"choices":[]}"#)
        }
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        let response = try await client.sendChatCompletion(apiKey: "test-secret", body: body)

        #expect(String(decoding: response, as: UTF8.self) == #"{"choices":[]}"#)
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
        let client = OpenRouterAPIClient(
            session: session,
            baseURL: URL(string: "https://example.test/api/v1")!
        )

        let models = try await client.compatibleModels(apiKey: "test-secret")

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
