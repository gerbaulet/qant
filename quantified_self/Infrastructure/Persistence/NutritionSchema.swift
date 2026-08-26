import SwiftData

enum NutritionSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Meal.self,
            MealImage.self,
            MealAnalysisRevision.self,
            FoodComponent.self,
            NutrientValue.self,
            NutritionGoalPeriod.self,
        ]
    }
}

enum NutritionSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        NutritionSchemaV1.models + [
            DinnerSuggestionBatch.self,
            DinnerSuggestion.self,
            DinnerSuggestionIngredient.self,
            DinnerSuggestionNutrient.self,
        ]
    }
}

enum NutritionMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [NutritionSchemaV1.self, NutritionSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: NutritionSchemaV1.self, toVersion: NutritionSchemaV2.self),
        ]
    }
}
