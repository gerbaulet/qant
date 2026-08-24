import Foundation

struct NutritionAnalysisConsensus {
    static let initialSampleCount = 3
    static let maximumRelativeSpread = 0.35

    private static let comparisonNutrients: [NutrientIdentifier] = [
        .energy,
        .protein,
        .carbohydrates,
        .fat,
    ]

    static func combine(_ results: [NutritionAnalysisResult]) throws -> NutritionAnalysisResult {
        guard results.count == initialSampleCount else {
            throw NutritionAnalysisError.invalidResult("initial consensus requires three results")
        }
        for result in results {
            try NutritionAnalysisValidator.validate(result)
        }

        let representative = representativeResult(in: results)
        let weightValues = results.compactMap(\.estimatedTotalWeightGrams)
        let weightDiverges = !weightValues.isEmpty &&
            hasStrongDeviation(values: weightValues, requiredCount: results.count)
        let resultsDivergeStrongly = comparisonNutrients.contains { identifier in
            hasStrongDeviation(values: nutrientValues(identifier, in: results))
        } || weightDiverges

        let averagedNutrients = representative.nutrients.map { nutrient in
            let matching = results.compactMap { result in
                result.nutrients.first { $0.identifier == nutrient.identifier }
            }
            guard matching.count == results.count else { return nutrient }
            return AnalyzedNutrient(
                identifier: nutrient.identifier,
                value: matching.map(\.value).average,
                unit: nutrient.unit,
                confidence: lowestConfidence(matching.map(\.confidence)),
                provenance: nutrient.provenance
            )
        }

        let modelQuestion = majorityClarificationQuestion(in: results)
        let clarificationQuestion = resultsDivergeStrongly
            ? "Die drei Analysen weichen deutlich voneinander ab. Bitte beschreibe Zutaten, Mengen und Portionsgröße genauer."
            : modelQuestion
        let uncertaintySummary = resultsDivergeStrongly
            ? "Die drei unabhängigen Schätzungen waren nicht ausreichend konsistent."
            : representative.uncertaintySummary

        return NutritionAnalysisResult(
            mealName: majorityMealName(in: results) ?? representative.mealName,
            estimatedTotalWeightGrams: averagedOptional(results.map(\.estimatedTotalWeightGrams)),
            confidence: resultsDivergeStrongly ? .low : lowestConfidence(results.map(\.confidence)),
            uncertaintySummary: uncertaintySummary,
            clarificationQuestion: clarificationQuestion,
            nutrients: averagedNutrients,
            components: representative.components,
            modelIdentifier: representative.modelIdentifier,
            providerIdentifier: representative.providerIdentifier
        )
    }

    private static func representativeResult(
        in results: [NutritionAnalysisResult]
    ) -> NutritionAnalysisResult {
        let means = Dictionary(uniqueKeysWithValues: comparisonNutrients.map { identifier in
            (identifier, nutrientValues(identifier, in: results).average)
        })
        return results.min { lhs, rhs in
            distance(of: lhs, from: means) < distance(of: rhs, from: means)
        } ?? results[0]
    }

    private static func distance(
        of result: NutritionAnalysisResult,
        from means: [NutrientIdentifier: Double]
    ) -> Double {
        comparisonNutrients.reduce(0) { total, identifier in
            guard
                let value = result.nutrients.first(where: { $0.identifier == identifier })?.value,
                let mean = means[identifier]
            else { return total + 1 }
            return total + abs(value - mean) / max(abs(mean), 1)
        }
    }

    private static func nutrientValues(
        _ identifier: NutrientIdentifier,
        in results: [NutritionAnalysisResult]
    ) -> [Double] {
        results.compactMap { result in
            result.nutrients.first { $0.identifier == identifier }?.value
        }
    }

    private static func hasStrongDeviation(
        values: [Double],
        requiredCount: Int = initialSampleCount
    ) -> Bool {
        guard values.count == requiredCount, let minimum = values.min(), let maximum = values.max() else {
            return true
        }
        return (maximum - minimum) / max(abs(values.average), 1) > maximumRelativeSpread
    }

    private static func averagedOptional(_ values: [Double?]) -> Double? {
        let presentValues = values.compactMap { $0 }
        guard presentValues.count == values.count else { return nil }
        return presentValues.average
    }

    private static func lowestConfidence(_ values: [EstimateConfidence]) -> EstimateConfidence {
        values.min { confidenceRank($0) < confidenceRank($1) } ?? .low
    }

    private static func confidenceRank(_ confidence: EstimateConfidence) -> Int {
        switch confidence {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private static func majorityMealName(in results: [NutritionAnalysisResult]) -> String? {
        let groups = Dictionary(grouping: results.map(\.mealName)) {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return groups.values.first(where: { $0.count >= 2 })?.first
    }

    private static func majorityClarificationQuestion(
        in results: [NutritionAnalysisResult]
    ) -> String? {
        let questions = results.compactMap { result -> String? in
            guard let question = result.clarificationQuestion?
                .trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else { return nil }
            return question
        }
        guard questions.count >= 2 else { return nil }
        return questions.first
    }
}

private extension Collection where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
