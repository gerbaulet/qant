import Foundation
import Testing
@testable import quantified_self

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
