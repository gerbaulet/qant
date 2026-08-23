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

enum NutritionMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [NutritionSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
