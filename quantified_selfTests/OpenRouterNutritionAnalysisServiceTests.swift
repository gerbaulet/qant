import Foundation
import Testing
@testable import Quant

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

    @Test("Best-estimate requests include prior context and reject another question")
    func bestEstimateContextAndQuestionLimit() async throws {
        let response = try Self.chatResponseData(
            clarificationQuestion: "Noch eine Frage?"
        )
        let client = ChatClientStub(responseData: response)
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: client
        )
        let previous = NutritionAnalysisValidatorTests.validResult(
            clarificationQuestion: "Wie viel Öl wurde verwendet?"
        )

        await #expect(throws: NutritionAnalysisError.malformedResponse) {
            try await service.analyze(NutritionAnalysisRequest(
                images: [],
                userComment: "Große Portion",
                previousAnalysis: previous,
                requestsBestEstimate: true,
                allowsClarification: false
            ))
        }

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let systemText = try #require(messages.first?["content"] as? String)
        #expect(systemText.contains("Do not ask another clarification question"))
        let userContent = try #require(messages.last?["content"] as? [[String: Any]])
        let userText = try #require(userContent.first?["text"] as? String)
        #expect(userText.contains("Baseline structured analysis"))
        #expect(userText.contains("best estimate"))
    }

    @Test("Previous estimates are labeled as a lower-priority baseline")
    func labelsPreviousEstimateAsBaseline() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: client
        )

        _ = try await service.analyze(NutritionAnalysisRequest(
            images: [],
            userComment: "Eine Portion",
            previousAnalysis: NutritionAnalysisValidatorTests.validResult(),
            clarificationAnswer: "Ohne zusätzliches Öl"
        ))

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? [[String: Any]])
        let userText = try #require(userContent.first?["text"] as? String)
        #expect(userText.contains("not additional food consumed"))
        #expect(userText.contains("Evidence priority"))
        #expect(userText.contains("never as a second serving"))
        #expect(userText.contains("Baseline component names are descriptive only"))
    }

    @Test("Correction requests include the user's correction and demand a complete estimate")
    func correctionContext() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: client
        )

        _ = try await service.analyze(NutritionAnalysisRequest(
            images: [],
            userComment: "Große Portion",
            previousAnalysis: NutritionAnalysisValidatorTests.validResult(),
            userCorrection: "Es waren nur 100 g Reis.",
            allowsClarification: false
        ))

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? [[String: Any]])
        let userText = try #require(userContent.first?["text"] as? String)
        #expect(userText.contains("User correction: Es waren nur 100 g Reis."))
        #expect(userText.contains("complete revised structured estimate"))
    }

    @Test("Clarification answers replace assumptions instead of adding another amount")
    func clarificationAnswerRevisesPriorAssumption() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: client
        )

        _ = try await service.analyze(NutritionAnalysisRequest(
            images: [],
            userComment: nil,
            previousAnalysis: NutritionAnalysisValidatorTests.validResult(
                clarificationQuestion: "Wie viel Öl wurde verwendet?"
            ),
            clarificationAnswer: "Zwei Esslöffel"
        ))

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? [[String: Any]])
        let userText = try #require(userContent.first?["text"] as? String)
        #expect(userText.contains("Replace the affected assumption"))
        #expect(userText.contains("never add the confirmed amount on top"))
        #expect(userText.contains("Keep unaffected ingredients and quantities unchanged"))
        #expect(userText.contains("mutually consistent"))
        #expect(userText.contains("at least 100 kcal and at least 20%"))
        #expect(userText.contains("uncertaintySummary must specifically explain"))
    }

    @Test("German device language localizes every user-facing analysis field")
    func requestsGermanUserFacingText() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: client,
            preferredLanguageIdentifier: "de-DE"
        )

        _ = try await service.analyze(NutritionAnalysisRequest(
            images: [],
            userComment: nil
        ))

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let systemText = try #require(messages.first?["content"] as? String)
        #expect(systemText.contains("German (de-DE)"))
        #expect(systemText.contains("mealName"))
        #expect(systemText.contains("components[].name"))
        #expect(systemText.contains("uncertaintySummary"))
        #expect(systemText.contains("clarificationQuestion"))
    }

    @Test("Earlier clarification exchanges are preserved in the prompt")
    func includesClarificationHistory() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "secret"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/model"),
            client: client
        )

        _ = try await service.analyze(NutritionAnalysisRequest(
            images: [],
            userComment: nil,
            clarificationHistory: [
                NutritionClarificationExchange(question: "Wie viel Öl?", answer: "Zwei Esslöffel"),
            ],
            clarificationAnswer: "200 Gramm Reis"
        ))

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? [[String: Any]])
        let userText = try #require(userContent.first?["text"] as? String)
        #expect(userText.contains("Earlier clarification history"))
        #expect(userText.contains("Wie viel Öl?"))
        #expect(userText.contains("Zwei Esslöffel"))
        #expect(userText.contains("Preserve every confirmed fact"))
    }

    @Test("Analysis requires a provider that supports structured output")
    func requiresStructuredOutputProvider() async throws {
        let client = ChatClientStub(responseData: try Self.chatResponseData())
        let service = OpenRouterNutritionAnalysisService(
            secretStore: AnalysisSecretStore(secret: "test-key"),
            settingsStore: AnalysisSettingsStore(modelIdentifier: "example/vision-model"),
            client: client,
            preferredLanguageIdentifier: "de-DE"
        )

        _ = try await service.analyze(NutritionAnalysisRequest(images: [], userComment: nil))

        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["require_parameters"] as? Bool == true)
    }

    private static func chatResponseData(
        clarificationQuestion: Any = NSNull()
    ) throws -> Data {
        let payload: [String: Any] = [
            "mealName": "Gemüsecurry mit Reis",
            "estimatedTotalWeightGrams": 480,
            "confidence": "medium",
            "uncertaintySummary": "Menge des verwendeten Öls",
            "clarificationQuestion": clarificationQuestion,
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
    var modelCatalogCache: OpenRouterModelCatalogCache?

    init(modelIdentifier: String) {
        self.modelIdentifier = modelIdentifier
    }
}
