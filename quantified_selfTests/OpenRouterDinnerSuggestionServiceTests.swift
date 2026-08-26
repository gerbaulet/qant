import Foundation
import Testing
@testable import quantified_self

@MainActor
struct OpenRouterDinnerSuggestionServiceTests {
    @Test("One structured request asks for three generic dinners scaled to all portions")
    func sendsOneStructuredRequest() async throws {
        let client = DinnerChatClientStub(responseData: try Self.responseData())
        let service = OpenRouterDinnerSuggestionService(
            secretStore: DinnerSecretStore(secret: "secret"),
            settingsStore: DinnerModelStore(modelIdentifier: "example/model"),
            client: client
        )

        let result = try await service.suggestDinner(request())

        #expect(client.callCount == 1)
        #expect(result.suggestions.count == 3)
        #expect(result.modelIdentifier == "resolved/model")
        let body = try #require(client.receivedBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let systemPrompt = try #require(messages.first?["content"] as? String)
        let userPrompt = try #require(messages.last?["content"] as? String)
        #expect(systemPrompt.contains("niemals Marken- oder Produktnamen"))
        #expect(systemPrompt.contains("Nährwerte gelten pro Portion"))
        #expect(userPrompt.contains("Portionen insgesamt: 4"))
        #expect(userPrompt.contains("Brokkoli"))
    }

    @Test("Anything other than three valid alternatives is rejected")
    func requiresThreeSuggestions() async {
        let data = try! Self.responseData(count: 2)
        let service = OpenRouterDinnerSuggestionService(
            secretStore: DinnerSecretStore(secret: "secret"),
            settingsStore: DinnerModelStore(modelIdentifier: "example/model"),
            client: DinnerChatClientStub(responseData: data)
        )

        await #expect(throws: DinnerSuggestionError.self) {
            try await service.suggestDinner(request())
        }
    }

    private func request() -> DinnerSuggestionRequest {
        DinnerSuggestionRequest(
            portionCount: 4,
            budgets: [
                DinnerNutrientBudget(identifier: .energy, consumed: 1_600, target: 2_200, unit: .kilocalorie),
                DinnerNutrientBudget(identifier: .protein, consumed: 80, target: 130, unit: .gram),
            ],
            preferences: DinnerPreferences(dietaryStyle: .vegetarian),
            availableIngredients: "Brokkoli",
            hasProvisionalValues: true
        )
    }

    private static func responseData(count: Int = 3) throws -> Data {
        let suggestion: [String: Any] = [
            "name": "Linsenpfanne",
            "fitSummary": "Schließt die Proteinlücke.",
            "ingredients": [["name": "Linsen", "amount": 400, "unit": "g"]],
            "nutrients": [
                ["identifier": "energy", "valuePerServing": 600, "unit": "kcal"],
                ["identifier": "protein", "valuePerServing": 45, "unit": "g"],
                ["identifier": "carbohydrates", "valuePerServing": 60, "unit": "g"],
                ["identifier": "fat", "valuePerServing": 18, "unit": "g"],
                ["identifier": "fiber", "valuePerServing": 15, "unit": "g"],
            ],
        ]
        let suggestions = (0..<count).map { index -> [String: Any] in
            var copy = suggestion
            copy["name"] = "Linsenpfanne \(index + 1)"
            return copy
        }
        let payload = try JSONSerialization.data(withJSONObject: ["suggestions": suggestions])
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": String(decoding: payload, as: UTF8.self)]]],
            "model": "resolved/model",
            "provider": "Provider",
        ])
    }
}

@MainActor
private final class DinnerChatClientStub: OpenRouterChatCompleting {
    let responseData: Data
    var receivedBody: Data?
    var callCount = 0

    init(responseData: Data) { self.responseData = responseData }

    func sendChatCompletion(apiKey: String, body: Data) async throws -> Data {
        callCount += 1
        receivedBody = body
        return responseData
    }
}

private struct DinnerSecretStore: SecretStoring {
    let secret: String?
    func secret(for identifier: SecretIdentifier) throws -> String? { secret }
    func setSecret(_ secret: String, for identifier: SecretIdentifier) throws {}
    func removeSecret(for identifier: SecretIdentifier) throws {}
}

private final class DinnerModelStore: OpenRouterSettingsStoring {
    var modelIdentifier: String
    init(modelIdentifier: String) { self.modelIdentifier = modelIdentifier }
}
