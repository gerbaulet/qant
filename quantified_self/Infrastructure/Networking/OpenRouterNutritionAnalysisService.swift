import Foundation

struct OpenRouterNutritionAnalysisService: NutritionAnalysisProviding {
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cost: Double?

            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case cost
            }
        }

        let choices: [Choice]
        let model: String?
        let provider: String?
        let usage: Usage?
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
    private let now: @Sendable () -> Date

    init(
        secretStore: any SecretStoring = KeychainSecretStore(),
        settingsStore: any OpenRouterSettingsStoring = UserDefaultsOpenRouterSettingsStore(),
        client: any OpenRouterChatCompleting = OpenRouterAPIClient(),
        preferredLanguageIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.client = client
        self.preferredLanguageIdentifier = preferredLanguageIdentifier
        self.now = now
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

        let requestedAt = now()
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

        return NutritionAnalysisResultNormalizer.normalize(NutritionAnalysisResult(
            mealName: payload.mealName,
            estimatedTotalWeightGrams: payload.estimatedTotalWeightGrams,
            confidence: payload.confidence,
            uncertaintySummary: payload.uncertaintySummary,
            clarificationQuestion: payload.clarificationQuestion,
            nutrients: payload.nutrients,
            components: payload.components,
            modelIdentifier: response.model ?? modelIdentifier,
            providerIdentifier: response.provider,
            requestMetrics: AnalysisRequestMetrics(
                requestedAt: requestedAt,
                inputTokens: response.usage?.promptTokens,
                outputTokens: response.usage?.completionTokens,
                costUSD: response.usage?.cost
            )
        ))
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

        var body: [String: Any] = [
            "model": modelIdentifier,
            "temperature": 0,
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
        if modelIdentifier.isOpenRouterAutoRouterIdentifier {
            body["plugins"] = [[
                "id": "auto-router",
                "cost_tier": settingsStore.costTier.rawValue,
            ]]
        }
        return body
    }

    private func systemPrompt(allowsClarification: Bool) -> String {
        let clarificationRule = allowsClarification
            ? "Ask at most one concise clarification question, and only when its answer could materially change the calorie estimate."
            : "Do not ask another clarification question. Return the best complete estimate from the available evidence."
        return """
        Analyze the meal using every supplied image, the user's comment, and the locally recognized label text. Prefer explicit user quantities and readable label values over visual estimates.
        Return each distinct consumed component exactly once. For every component, provide its consumed weight and exactly these nutrients: energy, protein, carbohydrates, fat, and fiber. Use kcal for energy and g for the other four values. For readable labels or reliable standard values, return the values per 100 g and set nutrientBasis to per100Grams; the app performs the portion calculation. For a purely visual estimate, return values for the consumed amount and set nutrientBasis to consumedAmount.
        The app deterministically sums component weights and nutrients, so component values are authoritative. Also return meal totals for compatibility, using the same component values. Cross-check calories against protein, carbohydrates, fat, and fiber (4/4/9/2 kcal per gram). Do not emit duplicate components or nutrient identifiers. Nutrient provenance must distinguish label, calculatedFromLabel, visualEstimate, textProvidedByUser, mixedEstimate, or unknown. Return only the JSON object required by the schema.
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
        let recognizedLabels = request.recognizedLabelText.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !recognizedLabels.isEmpty {
            lines.append("Locally recognized packaging text (may contain OCR mistakes):")
            for (index, text) in recognizedLabels {
                lines.append("Image \(index + 1):\n\(text)")
            }
            lines.append("Use this text as reading assistance, verify it against the supplied images, and never treat package size as consumed amount unless the user says so.")
        }
        if let previousAnalysis = request.previousAnalysis,
           let data = try? JSONEncoder().encode(previousAnalysis) {
            lines.append("Baseline structured analysis (context to revise, not additional food consumed): \(String(decoding: data, as: UTF8.self))")
            lines.append("Evidence priority: current and earlier user clarifications first; then explicit original user text and readable labels; then visible image evidence; finally assumptions from the baseline analysis.")
            lines.append("Treat baseline quantities as existing assumptions, never as a second serving or extra ingredients.")
            lines.append("Baseline component names are descriptive only. Their omitted weights and nutrients must be regenerated consistently with the authoritative baseline total weight and total nutrients.")
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
            lines.append("If energy changes by both at least 100 kcal and at least 20% from the baseline, uncertaintySummary must specifically explain which newly confirmed ingredient or quantity caused the change. Do not reuse the earlier generic uncertainty text.")
        }
        if let correction = request.userCorrection {
            lines.append("User correction: \(correction)")
            lines.append("Generate a complete revised structured estimate. Apply the correction consistently across the meal name, components, total weight, and every nutrient.")
        }
        if request.requestsBestEstimate {
            lines.append("The user chose to use the best estimate without further questions.")
        }
        if let feedback = request.validationFeedback {
            lines.append("The previous response failed local validation: \(feedback)")
            lines.append("Return one corrected complete analysis. Fix the stated inconsistency and preserve all reliable image, label, and user evidence.")
        }
        return lines.joined(separator: "\n")
    }

    private var responseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "mealName": ["type": "string"],
                "estimatedTotalWeightGrams": ["type": "number", "minimum": 0],
                "confidence": enumSchema(EstimateConfidence.allCases.map(\.rawValue)),
                "uncertaintySummary": nullableStringSchema,
                "clarificationQuestion": nullableStringSchema,
                "nutrients": [
                    "type": "array",
                    "minItems": 5,
                    "maxItems": 5,
                    "items": nutrientSchema,
                ],
                "components": [
                    "type": "array",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "name": ["type": "string"],
                            "estimatedWeightGrams": ["type": "number", "minimum": 0],
                            "nutrientBasis": enumSchema(["per100Grams", "consumedAmount"]),
                            "nutrients": [
                                "type": "array",
                                "minItems": 5,
                                "maxItems": 5,
                                "items": nutrientSchema,
                            ],
                        ],
                        "required": ["name", "estimatedWeightGrams", "nutrientBasis", "nutrients"],
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
                "identifier": enumSchema(coreNutrientIdentifiers.map(\.rawValue)),
                "value": ["type": "number", "minimum": 0],
                "unit": enumSchema(NutrientUnit.allCases.map(\.rawValue)),
                "confidence": enumSchema(EstimateConfidence.allCases.map(\.rawValue)),
                "provenance": enumSchema(NutrientProvenance.allCases.map(\.rawValue)),
            ],
            "required": ["identifier", "value", "unit", "confidence", "provenance"],
        ]
    }

    private var nullableStringSchema: [String: Any] {
        ["type": ["string", "null"]]
    }

    private func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private var coreNutrientIdentifiers: [NutrientIdentifier] {
        [.energy, .protein, .carbohydrates, .fat, .fiber]
    }
}
