import Foundation

nonisolated struct NutritionAnalysisImage: Sendable, Equatable {
    let data: Data
    let mediaType: String

    nonisolated init(data: Data, mediaType: String = "image/jpeg") {
        self.data = data
        self.mediaType = mediaType
    }
}

struct NutritionClarificationExchange: Codable, Sendable, Equatable {
    let question: String
    let answer: String
}

struct NutritionAnalysisRequest: Sendable, Equatable {
    let requestGroupIdentifier: UUID
    let images: [NutritionAnalysisImage]
    let userComment: String?
    let previousAnalysis: NutritionAnalysisResult?
    let clarificationHistory: [NutritionClarificationExchange]
    let clarificationAnswer: String?
    let userCorrection: String?
    let requestsBestEstimate: Bool
    let allowsClarification: Bool
    let recognizedLabelText: [String]
    let validationFeedback: String?
    let independentEstimateNumber: Int?

    init(
        requestGroupIdentifier: UUID = UUID(),
        images: [NutritionAnalysisImage],
        userComment: String?,
        previousAnalysis: NutritionAnalysisResult? = nil,
        clarificationHistory: [NutritionClarificationExchange] = [],
        clarificationAnswer: String? = nil,
        userCorrection: String? = nil,
        requestsBestEstimate: Bool = false,
        allowsClarification: Bool = true,
        recognizedLabelText: [String] = [],
        validationFeedback: String? = nil,
        independentEstimateNumber: Int? = nil
    ) {
        self.requestGroupIdentifier = requestGroupIdentifier
        self.images = images
        self.userComment = userComment
        self.previousAnalysis = previousAnalysis
        self.clarificationHistory = clarificationHistory
        self.clarificationAnswer = clarificationAnswer
        self.userCorrection = userCorrection
        self.requestsBestEstimate = requestsBestEstimate
        self.allowsClarification = allowsClarification
        self.recognizedLabelText = recognizedLabelText
        self.validationFeedback = validationFeedback
        self.independentEstimateNumber = independentEstimateNumber
    }

    func repairing(
        previousAnalysis: NutritionAnalysisResult?,
        feedback: String
    ) -> NutritionAnalysisRequest {
        NutritionAnalysisRequest(
            requestGroupIdentifier: requestGroupIdentifier,
            images: images,
            userComment: userComment,
            previousAnalysis: previousAnalysis ?? self.previousAnalysis,
            clarificationHistory: clarificationHistory,
            clarificationAnswer: clarificationAnswer,
            userCorrection: userCorrection,
            requestsBestEstimate: requestsBestEstimate,
            allowsClarification: allowsClarification,
            recognizedLabelText: recognizedLabelText,
            validationFeedback: feedback,
            independentEstimateNumber: independentEstimateNumber
        )
    }

    func independentEstimate(number: Int) -> NutritionAnalysisRequest {
        NutritionAnalysisRequest(
            requestGroupIdentifier: requestGroupIdentifier,
            images: images,
            userComment: userComment,
            previousAnalysis: nil,
            clarificationHistory: [],
            clarificationAnswer: nil,
            userCorrection: nil,
            requestsBestEstimate: true,
            allowsClarification: false,
            recognizedLabelText: recognizedLabelText,
            validationFeedback: nil,
            independentEstimateNumber: number
        )
    }
}

struct AnalyzedNutrient: Codable, Sendable, Equatable {
    let identifier: NutrientIdentifier
    let value: Double
    let unit: NutrientUnit
    let confidence: EstimateConfidence
    let provenance: NutrientProvenance
}

enum ComponentNutrientBasis: String, Codable, Sendable {
    case per100Grams
    case consumedAmount
}

struct AnalyzedFoodComponent: Codable, Sendable, Equatable {
    let name: String
    let estimatedWeightGrams: Double?
    let nutrientBasis: ComponentNutrientBasis
    let nutrients: [AnalyzedNutrient]

    init(
        name: String,
        estimatedWeightGrams: Double?,
        nutrientBasis: ComponentNutrientBasis = .consumedAmount,
        nutrients: [AnalyzedNutrient]
    ) {
        self.name = name
        self.estimatedWeightGrams = estimatedWeightGrams
        self.nutrientBasis = nutrientBasis
        self.nutrients = nutrients
    }
}

struct AnalysisRequestMetrics: Codable, Sendable, Equatable {
    let requestedAt: Date
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Double?
}

struct NutritionAnalysisResult: Codable, Sendable, Equatable {
    let mealName: String
    let estimatedTotalWeightGrams: Double?
    let confidence: EstimateConfidence
    let uncertaintySummary: String?
    let clarificationQuestion: String?
    let nutrients: [AnalyzedNutrient]
    let components: [AnalyzedFoodComponent]
    let modelIdentifier: String
    let providerIdentifier: String?
    let requestMetrics: AnalysisRequestMetrics?

    init(
        mealName: String,
        estimatedTotalWeightGrams: Double?,
        confidence: EstimateConfidence,
        uncertaintySummary: String?,
        clarificationQuestion: String?,
        nutrients: [AnalyzedNutrient],
        components: [AnalyzedFoodComponent],
        modelIdentifier: String,
        providerIdentifier: String?,
        requestMetrics: AnalysisRequestMetrics? = nil
    ) {
        self.mealName = mealName
        self.estimatedTotalWeightGrams = estimatedTotalWeightGrams
        self.confidence = confidence
        self.uncertaintySummary = uncertaintySummary
        self.clarificationQuestion = clarificationQuestion
        self.nutrients = nutrients
        self.components = components
        self.modelIdentifier = modelIdentifier
        self.providerIdentifier = providerIdentifier
        self.requestMetrics = requestMetrics
    }
}

enum NutritionAnalysisStreamEvent: Sendable, Equatable {
    case requestStarted
    case responseStarted
    case contentDelta(String)
    case responseCompleted

    var contentDelta: String? {
        guard case let .contentDelta(content) = self else { return nil }
        return content
    }
}

protocol NutritionAnalysisProviding {
    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult
    func analyze(
        _ request: NutritionAnalysisRequest,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> NutritionAnalysisResult
}

struct NutritionAnalysisOperationResult: Sendable, Equatable {
    let result: NutritionAnalysisResult
    let calls: [AnalysisCallSummary]
    let promptVersion: Int
    let policyVersion: Int
    let jobIdentifier: String
}

struct NutritionAnalysisOperationFailure: Error, LocalizedError, Sendable, Equatable {
    let message: String
    let calls: [AnalysisCallSummary]
    let promptVersion: Int?
    let jobIdentifier: String?

    var errorDescription: String? { message }
}

protocol NutritionAnalysisOperationProviding: NutritionAnalysisProviding {
    func analyzeOperation(
        _ request: NutritionAnalysisRequest,
        trigger: AnalysisTrigger,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> NutritionAnalysisOperationResult
    func acknowledgeAnalysis(jobIdentifier: String) async throws
}

extension NutritionAnalysisProviding {
    func analyze(
        _ request: NutritionAnalysisRequest,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> NutritionAnalysisResult {
        try await analyze(request)
    }
}

enum NutritionAnalysisError: Error, LocalizedError, Equatable {
    case missingConfiguration
    case malformedResponse
    case invalidResult(String)
    case invalidState

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Richte zuerst Serveradresse, API-Schlüssel und Modell in den Einstellungen ein."
        case .malformedResponse:
            "Die Ernährungsanalyse konnte nicht gelesen werden."
        case let .invalidResult(reason):
            "Die Ernährungsanalyse enthielt widersprüchliche Werte: \(reason)"
        case .invalidState:
            "Diese Aktion ist im aktuellen Analysestatus nicht möglich."
        }
    }
}

enum NutritionAnalysisValidator {
    private static let maximumUncertaintySummaryWordCount = 60

    private static let requiredNutrients: Set<NutrientIdentifier> = [
        .energy,
        .protein,
        .carbohydrates,
        .fat,
        .fiber,
        .alcohol,
    ]

    static var coreNutrients: Set<NutrientIdentifier> { requiredNutrients }

    static func validate(_ result: NutritionAnalysisResult) throws {
        guard !result.mealName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NutritionAnalysisError.invalidResult("Der Name der Mahlzeit fehlt.")
        }
        if let uncertaintySummary = result.uncertaintySummary {
            let wordCount = uncertaintySummary.split(whereSeparator: \.isWhitespace).count
            guard wordCount <= maximumUncertaintySummaryWordCount else {
                throw NutritionAnalysisError.invalidResult(
                    "Die Angabe zur Schätzsicherheit umfasst mehr als 60 Wörter."
                )
            }
        }
        try validateOptionalNonnegative(result.estimatedTotalWeightGrams, field: "Das Gesamtgewicht")
        try validateNutrients(result.nutrients, requireCoreNutrients: true)
        guard !result.components.isEmpty else {
            throw NutritionAnalysisError.invalidResult("Mindestens ein Bestandteil fehlt.")
        }

        for component in result.components {
            guard !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NutritionAnalysisError.invalidResult("Der Name eines Bestandteils fehlt.")
            }
            try validateOptionalNonnegative(component.estimatedWeightGrams, field: "Das Gewicht eines Bestandteils")
            try validateNutrients(component.nutrients, requireCoreNutrients: true)
        }
    }

    private static func validateNutrients(
        _ nutrients: [AnalyzedNutrient],
        requireCoreNutrients: Bool
    ) throws {
        let identifiers = nutrients.map(\.identifier)
        guard Set(identifiers).count == identifiers.count else {
            throw NutritionAnalysisError.invalidResult("Ein Nährwert wurde mehrfach ausgegeben.")
        }
        if requireCoreNutrients {
            guard requiredNutrients.isSubset(of: Set(identifiers)) else {
                throw NutritionAnalysisError.invalidResult("Mindestens ein erforderlicher Kernnährwert fehlt.")
            }
        }

        for nutrient in nutrients {
            guard nutrient.value.isFinite, nutrient.value >= 0 else {
                throw NutritionAnalysisError.invalidResult("Ein Nährwert ist negativ oder keine gültige Zahl.")
            }
            guard expectedUnit(for: nutrient.identifier) == nutrient.unit else {
                throw NutritionAnalysisError.invalidResult("Ein Nährwert hat die falsche Einheit.")
            }
        }
    }

    private static func validateOptionalNonnegative(_ value: Double?, field: String) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0 else {
            throw NutritionAnalysisError.invalidResult("\(field) ist negativ oder keine gültige Zahl.")
        }
    }

    static func expectedUnit(for identifier: NutrientIdentifier) -> NutrientUnit {
        switch identifier {
        case .energy:
            .kilocalorie
        case .protein, .carbohydrates, .fat, .fiber, .alcohol, .sugar, .saturatedFat, .salt:
            .gram
        case .vitaminA, .vitaminB7, .vitaminB9, .vitaminB12, .vitaminD, .vitaminK, .selenium, .iodine:
            .microgram
        case .sodium, .vitaminB1, .vitaminB2, .vitaminB3, .vitaminB5, .vitaminB6,
                .vitaminC, .vitaminE, .calcium, .iron, .magnesium, .potassium, .zinc,
                .phosphorus:
            .milligram
        }
    }
}

enum NutritionAnalysisResultNormalizer {
    static func normalize(_ result: NutritionAnalysisResult) -> NutritionAnalysisResult {
        NutritionAnalysisResult(
            mealName: result.mealName.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedTotalWeightGrams: result.estimatedTotalWeightGrams,
            confidence: result.confidence,
            uncertaintySummary: normalizedOptionalText(result.uncertaintySummary),
            clarificationQuestion: normalizedOptionalText(result.clarificationQuestion),
            nutrients: normalizedNutrients(result.nutrients),
            components: normalizedComponents(result.components),
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier,
            requestMetrics: result.requestMetrics
        )
    }

    private static func normalizedComponents(
        _ components: [AnalyzedFoodComponent]
    ) -> [AnalyzedFoodComponent] {
        var seenNames: Set<String> = []
        return components.compactMap { component in
            let name = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let comparisonName = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seenNames.insert(comparisonName).inserted else { return nil }
            return AnalyzedFoodComponent(
                name: name,
                estimatedWeightGrams: component.estimatedWeightGrams,
                nutrientBasis: component.nutrientBasis,
                nutrients: normalizedNutrients(component.nutrients)
            )
        }
    }

    private static func normalizedNutrients(
        _ nutrients: [AnalyzedNutrient]
    ) -> [AnalyzedNutrient] {
        Dictionary(grouping: nutrients, by: \.identifier)
            .compactMap { identifier, candidates in
                guard let selected = candidates.first(where: {
                    $0.unit == NutritionAnalysisValidator.expectedUnit(for: identifier)
                }) ?? candidates.first else { return nil }
                return AnalyzedNutrient(
                    identifier: identifier,
                    value: selected.value,
                    unit: NutritionAnalysisValidator.expectedUnit(for: identifier),
                    confidence: selected.confidence,
                    provenance: selected.provenance
                )
            }
            .sorted { nutrientOrder($0.identifier) < nutrientOrder($1.identifier) }
    }

    private static func nutrientOrder(_ identifier: NutrientIdentifier) -> Int {
        NutrientIdentifier.allCases.firstIndex(of: identifier) ?? .max
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
