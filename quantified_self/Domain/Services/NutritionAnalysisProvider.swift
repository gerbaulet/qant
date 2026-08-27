import Foundation

struct NutritionAnalysisImage: Sendable, Equatable {
    let data: Data
    let mediaType: String

    init(data: Data, mediaType: String = "image/jpeg") {
        self.data = data
        self.mediaType = mediaType
    }
}

struct NutritionClarificationExchange: Codable, Sendable, Equatable {
    let question: String
    let answer: String
}

struct NutritionAnalysisRequest: Sendable, Equatable {
    let images: [NutritionAnalysisImage]
    let userComment: String?
    let previousAnalysis: NutritionAnalysisResult?
    let clarificationHistory: [NutritionClarificationExchange]
    let clarificationAnswer: String?
    let userCorrection: String?
    let requestsBestEstimate: Bool
    let allowsClarification: Bool

    init(
        images: [NutritionAnalysisImage],
        userComment: String?,
        previousAnalysis: NutritionAnalysisResult? = nil,
        clarificationHistory: [NutritionClarificationExchange] = [],
        clarificationAnswer: String? = nil,
        userCorrection: String? = nil,
        requestsBestEstimate: Bool = false,
        allowsClarification: Bool = true
    ) {
        self.images = images
        self.userComment = userComment
        self.previousAnalysis = previousAnalysis
        self.clarificationHistory = clarificationHistory
        self.clarificationAnswer = clarificationAnswer
        self.userCorrection = userCorrection
        self.requestsBestEstimate = requestsBestEstimate
        self.allowsClarification = allowsClarification
    }
}

struct AnalyzedNutrient: Codable, Sendable, Equatable {
    let identifier: NutrientIdentifier
    let value: Double
    let unit: NutrientUnit
    let confidence: EstimateConfidence
    let provenance: NutrientProvenance
}

struct AnalyzedFoodComponent: Codable, Sendable, Equatable {
    let name: String
    let estimatedWeightGrams: Double?
    let nutrients: [AnalyzedNutrient]
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
}

protocol NutritionAnalysisProviding {
    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult
}

enum NutritionAnalysisError: Error, LocalizedError, Equatable {
    case missingConfiguration
    case malformedResponse
    case invalidResult(String)
    case invalidState

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Richte zuerst API-Schlüssel und Modell in den Einstellungen ein."
        case .malformedResponse:
            "Die Ernährungsanalyse konnte nicht gelesen werden."
        case .invalidResult:
            "Die Ernährungsanalyse enthielt ungültige Werte."
        case .invalidState:
            "Diese Aktion ist im aktuellen Analysestatus nicht möglich."
        }
    }
}

enum NutritionAnalysisValidator {
    private static let requiredNutrients: Set<NutrientIdentifier> = [
        .energy,
        .protein,
        .carbohydrates,
        .fat,
        .fiber,
        .sugar,
        .saturatedFat,
        .sodium,
    ]

    static func validate(_ result: NutritionAnalysisResult) throws {
        guard !result.mealName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NutritionAnalysisError.invalidResult("missing meal name")
        }
        try validateOptionalNonnegative(result.estimatedTotalWeightGrams, field: "total weight")
        try validateNutrients(result.nutrients, requireCoreNutrients: true)

        for component in result.components {
            guard !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NutritionAnalysisError.invalidResult("missing component name")
            }
            try validateOptionalNonnegative(component.estimatedWeightGrams, field: "component weight")
            try validateNutrients(component.nutrients, requireCoreNutrients: false)
        }
    }

    private static func validateNutrients(
        _ nutrients: [AnalyzedNutrient],
        requireCoreNutrients: Bool
    ) throws {
        let identifiers = nutrients.map(\.identifier)
        guard Set(identifiers).count == identifiers.count else {
            throw NutritionAnalysisError.invalidResult("duplicate nutrient")
        }
        if requireCoreNutrients {
            guard requiredNutrients.isSubset(of: Set(identifiers)) else {
                throw NutritionAnalysisError.invalidResult("missing core nutrient")
            }
        }

        for nutrient in nutrients {
            guard nutrient.value.isFinite, nutrient.value >= 0 else {
                throw NutritionAnalysisError.invalidResult("invalid nutrient value")
            }
            guard expectedUnit(for: nutrient.identifier) == nutrient.unit else {
                throw NutritionAnalysisError.invalidResult("invalid nutrient unit")
            }
        }
    }

    private static func validateOptionalNonnegative(_ value: Double?, field: String) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0 else {
            throw NutritionAnalysisError.invalidResult("invalid \(field)")
        }
    }

    static func expectedUnit(for identifier: NutrientIdentifier) -> NutrientUnit {
        switch identifier {
        case .energy:
            .kilocalorie
        case .protein, .carbohydrates, .fat, .fiber, .sugar, .saturatedFat, .salt:
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
