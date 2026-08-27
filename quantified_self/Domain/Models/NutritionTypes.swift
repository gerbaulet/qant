import Foundation

enum MealCategory: String, Codable, CaseIterable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack
}

enum MealState: String, Codable, CaseIterable, Sendable {
    case captured
    case archived
}

enum AnalysisState: String, Codable, CaseIterable, Sendable {
    case pending
    case analyzing
    case needsClarification
    case awaitingConfirmation
    case confirmed
    case failed
}

enum AnalysisTrigger: String, Codable, CaseIterable, Sendable {
    case initial
    case retry
    case clarification
    case correction
    case bestEstimate
}

enum EstimateConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

enum NutrientProvenance: String, Codable, CaseIterable, Sendable {
    case label
    case calculatedFromLabel
    case visualEstimate
    case textProvidedByUser
    case mixedEstimate
    case unknown
}

enum NutrientUnit: String, Codable, CaseIterable, Sendable {
    case kilocalorie = "kcal"
    case gram = "g"
    case milligram = "mg"
    case microgram = "µg"
}

/// Known nutrient identifiers used by app code. The database stores the raw
/// string so a future AI response can retain new identifiers without migration.
enum NutrientIdentifier: String, Codable, CaseIterable, Sendable {
    case energy
    case protein
    case carbohydrates
    case fat
    case fiber
    case sugar
    case saturatedFat
    case sodium
    case salt
    case vitaminA
    case vitaminB1
    case vitaminB2
    case vitaminB3
    case vitaminB5
    case vitaminB6
    case vitaminB7
    case vitaminB9
    case vitaminB12
    case vitaminC
    case vitaminD
    case vitaminE
    case vitaminK
    case calcium
    case iron
    case magnesium
    case potassium
    case zinc
    case phosphorus
    case selenium
    case iodine
}

enum NutritionAnalysisPrompt {
    static let currentVersion = 4
}
