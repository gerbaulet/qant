import Foundation
import SwiftData

@Model
final class Meal {
    var id: UUID
    var createdAt: Date
    var modifiedAt: Date
    var timestamp: Date
    var userComment: String?
    var categoryRawValue: String
    var mealStateRawValue: String
    var analysisStateRawValue: String
    var activeRevisionID: UUID?
    var clarificationCount: Int

    @Relationship(deleteRule: .cascade, inverse: \MealImage.meal)
    var images: [MealImage]

    @Relationship(deleteRule: .cascade, inverse: \MealAnalysisRevision.meal)
    var analysisRevisions: [MealAnalysisRevision]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        timestamp: Date = .now,
        userComment: String? = nil,
        category: MealCategory = .snack,
        mealState: MealState = .captured,
        analysisState: AnalysisState = .pending,
        activeRevisionID: UUID? = nil,
        clarificationCount: Int = 0,
        images: [MealImage] = [],
        analysisRevisions: [MealAnalysisRevision] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.timestamp = timestamp
        self.userComment = userComment
        self.categoryRawValue = category.rawValue
        self.mealStateRawValue = mealState.rawValue
        self.analysisStateRawValue = analysisState.rawValue
        self.activeRevisionID = activeRevisionID
        self.clarificationCount = clarificationCount
        self.images = images
        self.analysisRevisions = analysisRevisions
    }

    var category: MealCategory {
        get { MealCategory(rawValue: categoryRawValue) ?? .snack }
        set { categoryRawValue = newValue.rawValue }
    }

    var mealState: MealState {
        get { MealState(rawValue: mealStateRawValue) ?? .captured }
        set { mealStateRawValue = newValue.rawValue }
    }

    var analysisState: AnalysisState {
        get { AnalysisState(rawValue: analysisStateRawValue) ?? .pending }
        set { analysisStateRawValue = newValue.rawValue }
    }

    var activeRevision: MealAnalysisRevision? {
        guard let activeRevisionID else { return nil }
        return analysisRevisions.first { $0.id == activeRevisionID }
    }
}

@Model
final class MealImage {
    var id: UUID
    var createdAt: Date
    var sortIndex: Int
    var imageStorageKey: String
    var thumbnailStorageKey: String
    var pixelWidth: Int
    var pixelHeight: Int
    var meal: Meal?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sortIndex: Int,
        imageStorageKey: String,
        thumbnailStorageKey: String,
        pixelWidth: Int,
        pixelHeight: Int,
        meal: Meal? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.imageStorageKey = imageStorageKey
        self.thumbnailStorageKey = thumbnailStorageKey
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.meal = meal
    }
}

@Model
final class MealAnalysisRevision {
    var id: UUID
    var createdAt: Date
    var requestDate: Date
    var modelIdentifier: String
    var providerIdentifier: String?
    var providerMetadata: String?
    var promptVersion: Int
    var triggerRawValue: String
    var statusRawValue: String
    var mealName: String
    var estimatedTotalWeightGrams: Double?
    var confidenceRawValue: String
    var uncertaintySummary: String?
    var clarificationQuestion: String?
    var clarificationAnswer: String?
    var userCorrection: String?
    var failureMessage: String?
    var meal: Meal?

    @Relationship(deleteRule: .cascade, inverse: \FoodComponent.analysisRevision)
    var components: [FoodComponent]

    @Relationship(deleteRule: .cascade, inverse: \NutrientValue.analysisRevision)
    var nutrients: [NutrientValue]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        requestDate: Date = .now,
        modelIdentifier: String,
        providerIdentifier: String? = nil,
        providerMetadata: String? = nil,
        promptVersion: Int = NutritionAnalysisPrompt.currentVersion,
        trigger: AnalysisTrigger = .initial,
        status: AnalysisState,
        mealName: String,
        estimatedTotalWeightGrams: Double? = nil,
        confidence: EstimateConfidence,
        uncertaintySummary: String? = nil,
        clarificationQuestion: String? = nil,
        clarificationAnswer: String? = nil,
        userCorrection: String? = nil,
        failureMessage: String? = nil,
        meal: Meal? = nil,
        components: [FoodComponent] = [],
        nutrients: [NutrientValue] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestDate = requestDate
        self.modelIdentifier = modelIdentifier
        self.providerIdentifier = providerIdentifier
        self.providerMetadata = providerMetadata
        self.promptVersion = promptVersion
        self.triggerRawValue = trigger.rawValue
        self.statusRawValue = status.rawValue
        self.mealName = mealName
        self.estimatedTotalWeightGrams = estimatedTotalWeightGrams
        self.confidenceRawValue = confidence.rawValue
        self.uncertaintySummary = uncertaintySummary
        self.clarificationQuestion = clarificationQuestion
        self.clarificationAnswer = clarificationAnswer
        self.userCorrection = userCorrection
        self.failureMessage = failureMessage
        self.meal = meal
        self.components = components
        self.nutrients = nutrients
    }

    var trigger: AnalysisTrigger {
        get { AnalysisTrigger(rawValue: triggerRawValue) ?? .initial }
        set { triggerRawValue = newValue.rawValue }
    }

    var status: AnalysisState {
        get { AnalysisState(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    var confidence: EstimateConfidence {
        get { EstimateConfidence(rawValue: confidenceRawValue) ?? .low }
        set { confidenceRawValue = newValue.rawValue }
    }

    var normalizedPortionMultiplier: Double {
        guard portionMultiplier.isFinite else { return 1 }
        return min(max(portionMultiplier, 0), 5)
    }

    var portionMultiplier: Double {
        get { InitialAnalysisRunMetadata.portionMultiplier(from: providerMetadata) }
        set { providerMetadata = InitialAnalysisRunMetadata.settingPortionMultiplier(newValue, in: providerMetadata) }
    }

    func scaled(_ value: Double) -> Double {
        value * normalizedPortionMultiplier
    }
}

@Model
final class FoodComponent {
    var id: UUID
    var sortIndex: Int
    var name: String
    var estimatedWeightGrams: Double?
    var analysisRevision: MealAnalysisRevision?

    @Relationship(deleteRule: .cascade, inverse: \NutrientValue.foodComponent)
    var nutrients: [NutrientValue]

    init(
        id: UUID = UUID(),
        sortIndex: Int,
        name: String,
        estimatedWeightGrams: Double? = nil,
        analysisRevision: MealAnalysisRevision? = nil,
        nutrients: [NutrientValue] = []
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.name = name
        self.estimatedWeightGrams = estimatedWeightGrams
        self.analysisRevision = analysisRevision
        self.nutrients = nutrients
    }
}

@Model
final class NutrientValue {
    var id: UUID
    var identifierRawValue: String
    var value: Double
    var unitRawValue: String
    var confidenceRawValue: String
    var provenanceRawValue: String
    var analysisRevision: MealAnalysisRevision?
    var foodComponent: FoodComponent?

    init(
        id: UUID = UUID(),
        identifier: NutrientIdentifier,
        value: Double,
        unit: NutrientUnit,
        confidence: EstimateConfidence,
        provenance: NutrientProvenance,
        analysisRevision: MealAnalysisRevision? = nil,
        foodComponent: FoodComponent? = nil
    ) {
        self.id = id
        self.identifierRawValue = identifier.rawValue
        self.value = value
        self.unitRawValue = unit.rawValue
        self.confidenceRawValue = confidence.rawValue
        self.provenanceRawValue = provenance.rawValue
        self.analysisRevision = analysisRevision
        self.foodComponent = foodComponent
    }

    /// Used only when decoding a future identifier that this app version does
    /// not know yet. Normal app code should use the typed initializer above.
    init(
        id: UUID = UUID(),
        rawIdentifier: String,
        value: Double,
        rawUnit: String,
        confidence: EstimateConfidence,
        provenance: NutrientProvenance
    ) {
        self.id = id
        self.identifierRawValue = rawIdentifier
        self.value = value
        self.unitRawValue = rawUnit
        self.confidenceRawValue = confidence.rawValue
        self.provenanceRawValue = provenance.rawValue
        self.analysisRevision = nil
        self.foodComponent = nil
    }

    var knownIdentifier: NutrientIdentifier? {
        NutrientIdentifier(rawValue: identifierRawValue)
    }

    var knownUnit: NutrientUnit? {
        NutrientUnit(rawValue: unitRawValue)
    }

    var confidence: EstimateConfidence {
        EstimateConfidence(rawValue: confidenceRawValue) ?? .low
    }

    var provenance: NutrientProvenance {
        NutrientProvenance(rawValue: provenanceRawValue) ?? .unknown
    }
}

@Model
final class NutritionGoalPeriod {
    var id: UUID
    var createdAt: Date
    var modifiedAt: Date
    var validFrom: Date
    var validUntil: Date?
    var nutrientIdentifierRawValue: String
    var targetValue: Double
    var unitRawValue: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        validFrom: Date,
        validUntil: Date? = nil,
        nutrientIdentifier: NutrientIdentifier,
        targetValue: Double,
        unit: NutrientUnit
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.nutrientIdentifierRawValue = nutrientIdentifier.rawValue
        self.targetValue = targetValue
        self.unitRawValue = unit.rawValue
    }

    var nutrientIdentifier: NutrientIdentifier? {
        NutrientIdentifier(rawValue: nutrientIdentifierRawValue)
    }

    var unit: NutrientUnit? {
        NutrientUnit(rawValue: unitRawValue)
    }

    func contains(_ date: Date) -> Bool {
        validFrom <= date && (validUntil == nil || date < validUntil!)
    }
}
