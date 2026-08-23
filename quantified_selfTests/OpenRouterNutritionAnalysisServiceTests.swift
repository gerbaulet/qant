import Foundation
import Testing
@testable import quantified_self

@MainActor
struct OpenRouterNutritionAnalysisServiceTests {
    @Test("The service sends every image and decodes structured nutrition data")
    func sendsMultimodalStructuredRequest() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let settings = AnalysisSettingsStore(modelIdentifier: "example/vision-model")
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "test-secret"),
            settingsStore: settings,
            client: client
        )

        let result = try await service.analyze(NutritionAnalysisRequest(
            images: [
                NutritionAnalysisImage(data: Data([1, 2, 3])),
                NutritionAnalysisImage(data: Data([4, 5, 6])),
            ],
            userComment: "Etwa 480 g, leichte Kokosmilch"
        ))

        #expect(result.mealName == "Gemüsecurry mit Reis")
        #expect(result.nutrients.first?.value == 640)
        #expect(result.modelIdentifier == "resolved/vision-model")
        #expect(result.providerIdentifier == "Example Provider")
        #expect(client.receivedAPIKey == "test-secret")

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "example/vision-model")
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userMessage = try #require(messages.last)
        let content = try #require(userMessage["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect((content[1]["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AQID")
        #expect((content[2]["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,BAUG")
    }

    @Test("Missing credentials fail before a network request")
    func requiresConfiguration() async {
        let client = ChatClientStub(responseData: Data())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: nil),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/vision-model"),
            client: client
        )

        await #expect(throws: NutritionAnalysisError.missingConfiguration) {
            try await service.analyze(NutritionAnalysisRequest(images: [], userComment: nil))
        }
        #expect(client.receivedBody == nil)
    }

    @Test("Malformed assistant content is rejected")
    func rejectsMalformedContent() async {
        let response = Data(#"{"choices":[{"message":{"content":"not-json"}}]}"#.utf8)
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: ChatClientStub(responseData: response)
        )

        await #expect(throws: NutritionAnalysisError.malformedResponse) {
            try await service.analyze(NutritionAnalysisRequest(images: [], userComment: nil))
        }
    }

    private static func chatResponseData() throws -> Data {
        let payload: [String: Any] = [
            "mealName": "Gemüsecurry mit Reis",
            "estimatedTotalWeightGrams": 480,
            "confidence": "medium",
            "uncertaintySummary": "Menge des verwendeten Öls",
            "clarificationQuestion": NSNull(),
            "nutrients": NutritionAnalysisValidatorTests.coreNutrients.map { nutrient in
                [
                    "identifier": nutrient.identifier.rawValue,
                    "value": nutrient.value,
                    "unit": nutrient.unit.rawValue,
                    "confidence": nutrient.confidence.rawValue,
                    "provenance": nutrient.provenance.rawValue,
                ]
            },
            "components": [],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let content = String(decoding: payloadData, as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]],
            "model": "resolved/vision-model",
            "provider": "Example Provider",
        ])
    }
}

@MainActor
private final class ChatClientStub: OpenRouterChatCompleting {
    let responseData: Data
    var receivedAPIKey: String?
    var receivedBody: Data?

    init(responseData: Data) {
        self.responseData = responseData
    }

    func sendChatCompletion(apiKey: String, body: Data) async throws -> Data {
        receivedAPIKey = apiKey
        receivedBody = body
        return responseData
    }
}

private struct AnalysisSecretStore: SecretStoring {
    let secret: String?

    func secret(for identifier: SecretIdentifier) throws -> String? { secret }
    func setSecret(_ secret: String, for identifier: SecretIdentifier) throws {}
    func removeSecret(for identifier: SecretIdentifier) throws {}
}

private final class AnalysisSettingsStore: OpenRouterSettingsStoring {
    var modelIdentifier: String

    init(modelIdentifier: String) {
        self.modelIdentifier = modelIdentifier
    }
}
