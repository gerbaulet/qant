import Foundation

struct OpenRouterNutritionAnalysisService: NutritionAnalysisProviding {
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
        let model: String?
        let provider: String?
    }

    private struct AnalysisPayload: Decodable {
        let mealName: String
        let estimatedTotalWeightGrams: Double?
        let confidence: EstimateConfidence
        let uncertaintySummary: String?
        let clarificationQuestion: String?
        let nutrients: [AnalyzedNutrient]
        let components: [AnalyzedFoodComponent]
    }

    private let secretStore: any SecretStoring
    private let settingsStore: any OpenRouterSettingsStoring
    private let client: any OpenRouterChatCompleting
    private let preferredLanguageIdentifier: String

    init(
        secretStore: any SecretStoring = KeychainSecretStore(),
        settingsStore: any OpenRouterSettingsStoring = UserDefaultsOpenRouterSettingsStore(),
        client: any OpenRouterChatCompleting = OpenRouterAPIClient(),
        preferredLanguageIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
    ) {
        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.client = client
        self.preferredLanguageIdentifier = preferredLanguageIdentifier
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        let apiKey = try secretStore.secret(for: .openRouterAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelIdentifier = settingsStore.modelIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty, !modelIdentifier.isEmpty else {
            throw NutritionAnalysisError.missingConfiguration
        }

        let requestBody: Data
        do {
            requestBody = try JSONSerialization.data(withJSONObject: makeRequestBody(
                request,
                modelIdentifier: modelIdentifier
            ))
        } catch {
            throw NutritionAnalysisError.malformedResponse
        }

        let responseData = try await client.sendChatCompletion(apiKey: apiKey, body: requestBody)
        let decoder = JSONDecoder()
        guard
            let response = try? decoder.decode(ChatResponse.self, from: responseData),
            let content = response.choices.first?.message.content,
            let contentData = content.data(using: .utf8),
            let payload = try? decoder.decode(AnalysisPayload.self, from: contentData),
            request.allowsClarification || payload.clarificationQuestion?.isEmpty != false
        else {
            throw NutritionAnalysisError.malformedResponse
        }

        let result = NutritionAnalysisResult(
            mealName: payload.mealName,
            estimatedTotalWeightGrams: payload.estimatedTotalWeightGrams,
            confidence: payload.confidence,
            uncertaintySummary: payload.uncertaintySummary,
            clarificationQuestion: payload.clarificationQuestion,
            nutrients: payload.nutrients,
            components: payload.components,
            modelIdentifier: response.model ?? modelIdentifier,
            providerIdentifier: response.provider
        )
        try NutritionAnalysisValidator.validate(result)
        return result
    }

    private func makeRequestBody(
        _ request: NutritionAnalysisRequest,
        modelIdentifier: String
    ) -> [String: Any] {
        var content: [[String: Any]] = [[
            "type": "text",
            "text": userPrompt(request),
        ]]
        content.append(contentsOf: request.images.map { image in
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())",
                ],
            ]
        })

        return [
            "model": modelIdentifier,
            "temperature": 0.2,
            "provider": [
                "require_parameters": true,
            ],
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt(allowsClarification: request.allowsClarification),
                ],
                [
                    "role": "user",
                    "content": content,
                ],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "nutrition_analysis_v\(NutritionAnalysisPrompt.currentVersion)",
                    "strict": true,
                    "schema": responseSchema,
                ],
            ],
        ]
    }

    private func systemPrompt(allowsClarification: Bool) -> String {
        let clarificationRule = allowsClarification
            ? "Ask at most one concise clarification question, and only when its answer could materially change the calorie estimate."
            : "Do not ask another clarification question. Return the best complete estimate from the available evidence."
        return """
        Analyze the meal using every supplied image and the user's comment. Inspect packaging and nutrition labels explicitly. Prefer readable label values over visual estimates. Return realistic estimates without false precision. Always include energy, protein, carbohydrates, fat, fiber, sugar, saturatedFat, and sodium; include every additional listed micronutrient that can be responsibly estimated. Nutrient provenance must distinguish label, calculatedFromLabel, visualEstimate, textProvidedByUser, mixedEstimate, or unknown. Return only the JSON object required by the schema.
        \(outputLanguageRule)
        \(clarificationRule)
        """
    }

    private var outputLanguageRule: String {
        let normalizedIdentifier = preferredLanguageIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let identifier = normalizedIdentifier.isEmpty ? "de" : normalizedIdentifier
        let language = identifier.lowercased().hasPrefix("de")
            ? "German (\(identifier))"
            : "the language identified by BCP-47 tag \(identifier)"
        return "Write all user-facing text in \(language). This includes mealName, every components[].name, uncertaintySummary, and clarificationQuestion. Keep product and brand names unchanged. Keep schema keys and enum values exactly as specified."
    }

    private func userPrompt(_ request: NutritionAnalysisRequest) -> String {
        let trimmedComment = request.userComment?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let trimmedComment, !trimmedComment.isEmpty {
            lines.append("Original user comment: \(trimmedComment)")
        } else {
            lines.append("No original user comment was provided.")
        }
        if let previousAnalysis = request.previousAnalysis,
           let data = try? JSONEncoder().encode(previousAnalysis) {
            lines.append("Baseline structured analysis (context to revise, not additional food consumed): \(String(decoding: data, as: UTF8.self))")
            lines.append("Evidence priority: current and earlier user clarifications first; then explicit original user text and readable labels; then visible image evidence; finally assumptions from the baseline analysis.")
            lines.append("Treat baseline quantities as existing assumptions, never as a second serving or extra ingredients.")
        }
        if !request.clarificationHistory.isEmpty,
           let data = try? JSONEncoder().encode(request.clarificationHistory) {
            lines.append("Earlier clarification history: \(String(decoding: data, as: UTF8.self))")
            lines.append("Preserve every confirmed fact in this history while applying the current answer.")
        }
        if let answer = request.clarificationAnswer {
            lines.append("User's clarification answer: \(answer)")
            lines.append("Revise the previous estimate using this answer. Replace the affected assumption; never add the confirmed amount on top of an amount already estimated for the same ingredient or portion.")
            lines.append("Keep unaffected ingredients and quantities unchanged. Recalculate the complete result so total weight, components, total nutrients, and component nutrients remain mutually consistent.")
        }
        if let correction = request.userCorrection {
            lines.append("User correction: \(correction)")
            lines.append("Generate a complete revised structured estimate. Apply the correction consistently across the meal name, components, total weight, and every nutrient.")
        }
        if request.requestsBestEstimate {
            lines.append("The user chose to use the best estimate without further questions.")
        }
        return lines.joined(separator: "\n")
    }

    private var responseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "mealName": ["type": "string"],
                "estimatedTotalWeightGrams": nullableNumberSchema,
                "confidence": enumSchema(EstimateConfidence.allCases.map(\.rawValue)),
                "uncertaintySummary": nullableStringSchema,
                "clarificationQuestion": nullableStringSchema,
                "nutrients": [
                    "type": "array",
                    "minItems": 8,
                    "items": nutrientSchema,
                ],
                "components": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "name": ["type": "string"],
                            "estimatedWeightGrams": nullableNumberSchema,
                            "nutrients": [
                                "type": "array",
                                "items": nutrientSchema,
                            ],
                        ],
                        "required": ["name", "estimatedWeightGrams", "nutrients"],
                    ],
                ],
            ],
            "required": [
                "mealName",
                "estimatedTotalWeightGrams",
                "confidence",
                "uncertaintySummary",
                "clarificationQuestion",
                "nutrients",
                "components",
            ],
        ]
    }

    private var nutrientSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "identifier": enumSchema(NutrientIdentifier.allCases.map(\.rawValue)),
                "value": ["type": "number", "minimum": 0],
                "unit": enumSchema(NutrientUnit.allCases.map(\.rawValue)),
                "confidence": enumSchema(EstimateConfidence.allCases.map(\.rawValue)),
                "provenance": enumSchema(NutrientProvenance.allCases.map(\.rawValue)),
            ],
            "required": ["identifier", "value", "unit", "confidence", "provenance"],
        ]
    }

    private var nullableNumberSchema: [String: Any] {
        ["type": ["number", "null"], "minimum": 0]
    }

    private var nullableStringSchema: [String: Any] {
        ["type": ["string", "null"]]
    }

    private func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }
}
