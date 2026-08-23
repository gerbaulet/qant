#if DEBUG
import Foundation

@MainActor
enum DevelopmentSampleFixtures {
    static func meals(reference: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [Meal] {
        let scenarios: [(daysAgo: Int, state: AnalysisState, name: String, energy: Double)] = [
            (0, .pending, "Neu erfasste Mahlzeit", 0),
            (1, .needsClarification, "Salat mit Dressing", 540),
            (2, .failed, "Nicht analysierte Mahlzeit", 0),
            (3, .confirmed, "Chicken Curry mit Reis", 785),
            (8, .confirmed, "Joghurt mit Beeren", 430),
            (16, .confirmed, "Pasta mit Gemüse", 690),
            (32, .confirmed, "Linsensuppe", 610),
        ]

        var meals = scenarios.map { scenario in
            let timestamp = calendar.date(
                byAdding: .day,
                value: -scenario.daysAgo,
                to: reference
            ) ?? reference
            guard scenario.state != .pending && scenario.state != .failed else {
                return Meal(
                    timestamp: timestamp,
                    userComment: scenario.state == .failed ? "Beispiel für einen Wiederholungsversuch" : nil,
                    analysisState: scenario.state
                )
            }
            let revision = revision(
                status: scenario.state,
                name: scenario.name,
                energy: scenario.energy,
                clarification: scenario.state == .needsClarification
                    ? "Wie viel Dressing wurde verwendet?"
                    : nil
            )
            return Meal(
                timestamp: timestamp,
                analysisState: scenario.state,
                activeRevisionID: revision.id,
                analysisRevisions: [revision]
            )
        }

        let previous = revision(
            status: .confirmed,
            name: "Brot mit Käse",
            energy: 620
        )
        let corrected = revision(
            status: .confirmed,
            name: "Zwei Scheiben Brot ohne Käse",
            energy: 410,
            trigger: .correction,
            correction: "Es war kein Käse dabei."
        )
        let correctedMeal = Meal(
            timestamp: calendar.date(byAdding: .day, value: -5, to: reference) ?? reference,
            analysisState: .confirmed,
            activeRevisionID: corrected.id,
            analysisRevisions: [previous, corrected]
        )
        meals.append(correctedMeal)

        let multiImageMeal = meals.first { $0.analysisState == .confirmed }
        multiImageMeal?.images = [
            sampleImage(index: 0, suffix: "overview"),
            sampleImage(index: 1, suffix: "label"),
        ]
        return meals
    }

    static func goals(reference: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [NutritionGoalPeriod] {
        let changeDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -14, to: reference) ?? reference
        )
        let originalDate = calendar.date(byAdding: .day, value: -180, to: changeDate) ?? changeDate
        return [
            NutritionGoalPeriod(
                validFrom: originalDate,
                validUntil: changeDate,
                nutrientIdentifier: .energy,
                targetValue: 2_300,
                unit: .kilocalorie
            ),
            NutritionGoalPeriod(
                validFrom: changeDate,
                nutrientIdentifier: .energy,
                targetValue: 2_200,
                unit: .kilocalorie
            ),
        ]
    }

    private static func revision(
        status: AnalysisState,
        name: String,
        energy: Double,
        trigger: AnalysisTrigger = .initial,
        clarification: String? = nil,
        correction: String? = nil
    ) -> MealAnalysisRevision {
        MealAnalysisRevision(
            modelIdentifier: "example/vision-model",
            providerIdentifier: "Example Provider",
            trigger: trigger,
            status: status,
            mealName: name,
            confidence: .medium,
            uncertaintySummary: "Beispieldaten ohne externe Analyse.",
            clarificationQuestion: clarification,
            userCorrection: correction,
            nutrients: [
                nutrient(.energy, energy, .kilocalorie),
                nutrient(.protein, energy / 20, .gram),
                nutrient(.carbohydrates, energy / 8, .gram),
                nutrient(.fat, energy / 30, .gram),
            ]
        )
    }

    private static func nutrient(
        _ identifier: NutrientIdentifier,
        _ value: Double,
        _ unit: NutrientUnit
    ) -> NutrientValue {
        NutrientValue(
            identifier: identifier,
            value: value,
            unit: unit,
            confidence: .medium,
            provenance: .mixedEstimate
        )
    }

    private static func sampleImage(index: Int, suffix: String) -> MealImage {
        MealImage(
            sortIndex: index,
            imageStorageKey: "sample/\(suffix).jpg",
            thumbnailStorageKey: "sample/\(suffix)-thumbnail.jpg",
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
    }
}
#endif
