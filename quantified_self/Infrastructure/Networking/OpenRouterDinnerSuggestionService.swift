import Foundation

struct OpenRouterDinnerSuggestionService: DinnerSuggestionProviding {
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }

        let choices: [Choice]
        let model: String?
        let provider: String?
    }

    private struct Payload: Decodable {
        let suggestions: [SuggestedDinner]
    }

    private let secretStore: any SecretStoring
    private let settingsStore: any OpenRouterSettingsStoring
    private let client: any OpenRouterChatCompleting

    init(
        secretStore: any SecretStoring = KeychainSecretStore(),
        settingsStore: any OpenRouterSettingsStoring = UserDefaultsOpenRouterSettingsStore(),
        client: any OpenRouterChatCompleting = OpenRouterAPIClient()
    ) {
        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.client = client
    }

    func suggestDinner(_ request: DinnerSuggestionRequest) async throws -> DinnerSuggestionResult {
        guard (1...12).contains(request.portionCount) else {
            throw DinnerSuggestionError.invalidPortionCount
        }
        let apiKey = try secretStore.secret(for: .openRouterAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settingsStore.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty, !model.isEmpty else {
            throw DinnerSuggestionError.missingConfiguration
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: requestBody(request, model: model))
        } catch {
            throw DinnerSuggestionError.invalidResponse("request encoding")
        }

        let data = try await client.sendChatCompletion(apiKey: apiKey, body: body)
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(ChatResponse.self, from: data),
              let content = response.choices.first?.message.content,
              let contentData = content.data(using: .utf8),
              let payload = try? decoder.decode(Payload.self, from: contentData) else {
            throw DinnerSuggestionError.invalidResponse("response decoding")
        }
        let result = DinnerSuggestionResult(
            suggestions: DinnerSuggestionBuilder.ranked(payload.suggestions, for: request.budgets),
            modelIdentifier: response.model ?? model,
            providerIdentifier: response.provider
        )
        try DinnerSuggestionValidator.validate(result)
        return result
    }

    private func requestBody(_ request: DinnerSuggestionRequest, model: String) -> [String: Any] {
        [
            "model": model,
            "temperature": 0.5,
            "provider": ["require_parameters": true],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(request)],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "dinner_suggestions_v\(DinnerSuggestionPrompt.currentVersion)",
                    "strict": true,
                    "schema": responseSchema,
                ],
            ],
        ]
    }

    private var systemPrompt: String {
        """
        Erstelle genau drei unterschiedliche, alltagstaugliche Abendessen auf Deutsch. Optimiere eine Portion auf das angegebene verbleibende Tagesbudget. Protein und Ballaststoffe sind nach Kalorien am wichtigsten, danach Kohlenhydrate und Fett. Kalorien dürfen um höchstens 10 Prozent abweichen, außer eine größere Abweichung schließt offene Protein- oder Ballaststoffziele deutlich besser. Wenn kein Kalorienbudget mehr übrig ist, erstelle trotzdem drei leichte Mahlzeiten und sage dies in fitSummary transparent. Verwende ausschließlich generische Lebensmittelbezeichnungen und niemals Marken- oder Produktnamen. Beachte Ernährungsweise, Allergien, ausgeschlossene Zutaten, Zeit und Küchenausstattung strikt. Zutatenmengen gelten für die gesamte angeforderte Portionszahl; Nährwerte gelten pro Portion. Verwende vorhandene Zutaten bevorzugt, erfinde aber keine vorhandenen Vorräte. Antworte ausschließlich mit dem JSON-Objekt des Schemas. Nährwerte sind realistische Schätzungen ohne falsche Genauigkeit.
        """
    }

    private func userPrompt(_ request: DinnerSuggestionRequest) -> String {
        let budgets = request.budgets.map { budget -> String in
            guard let target = budget.target else {
                return "\(budget.identifier.rawValue): verbraucht \(budget.consumed) \(budget.unit.rawValue), kein Ziel gesetzt"
            }
            return "\(budget.identifier.rawValue): verbraucht \(budget.consumed), Ziel \(target), verbleibend \(max(target - budget.consumed, 0)) \(budget.unit.rawValue), bereits erreicht/überschritten: \(budget.isExceeded)"
        }.joined(separator: "\n")
        let ingredients = request.availableIngredients.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Portionen insgesamt: \(request.portionCount)
        Die essende Person verzehrt davon genau eine Portion.
        Tageswerte enthalten vorläufige Schätzungen: \(request.hasProvisionalValues)

        Verbleibendes Budget:
        \(budgets)

        Persönliche Vorgaben:
        \(request.preferences.requestSummary)

        Vorhandene Zutaten: \(ingredients.isEmpty ? "keine angegeben" : ingredients)
        """
    }

    private var responseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "suggestions": [
                    "type": "array",
                    "minItems": 3,
                    "maxItems": 3,
                    "items": suggestionSchema,
                ],
            ],
            "required": ["suggestions"],
        ]
    }

    private var suggestionSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "name": ["type": "string"],
                "fitSummary": ["type": "string"],
                "ingredients": [
                    "type": "array",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "name": ["type": "string"],
                            "amount": ["type": ["number", "null"], "minimum": 0],
                            "unit": ["type": "string"],
                        ],
                        "required": ["name", "amount", "unit"],
                    ],
                ],
                "nutrients": [
                    "type": "array",
                    "minItems": 5,
                    "maxItems": 5,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "identifier": [
                                "type": "string",
                                "enum": ["energy", "protein", "carbohydrates", "fat", "fiber"],
                            ],
                            "valuePerServing": ["type": "number", "minimum": 0],
                            "unit": ["type": "string", "enum": ["kcal", "g"]],
                        ],
                        "required": ["identifier", "valuePerServing", "unit"],
                    ],
                ],
            ],
            "required": ["name", "fitSummary", "ingredients", "nutrients"],
        ]
    }
}
