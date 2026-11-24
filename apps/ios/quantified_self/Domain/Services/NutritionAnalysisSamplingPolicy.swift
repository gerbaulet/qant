import Foundation

enum NutritionAnalysisSamplingPolicy {
    static let targetEstimateCount = 3

    static func requiresAdditionalEstimates(
        request: NutritionAnalysisRequest,
        result: NutritionAnalysisResult
    ) -> Bool {
        guard
            !request.images.isEmpty,
            result.clarificationQuestion?.isEmpty != false,
            !containsNutritionLabel(in: request.recognizedLabelText),
            !containsMeasuredQuantity(in: request.userComment)
        else { return false }
        return true
    }

    static func medianResult(
        from results: [NutritionAnalysisResult]
    ) throws -> NutritionAnalysisResult {
        guard results.count == targetEstimateCount else {
            throw NutritionAnalysisError.invalidResult(
                "Für den Median werden genau drei gültige Schätzungen benötigt."
            )
        }
        let ranked = try results.map { result -> (NutritionAnalysisResult, Double) in
            guard let energy = result.nutrients.first(where: {
                $0.identifier == .energy && $0.unit == .kilocalorie
            })?.value else {
                throw NutritionAnalysisError.invalidResult("Eine Schätzung enthält keine Kalorien.")
            }
            return (result, energy)
        }.sorted { $0.1 < $1.1 }
        return ranked[ranked.count / 2].0
    }

    private static func containsNutritionLabel(in recognizedText: [String]) -> Bool {
        let text = recognizedText.joined(separator: "\n").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        )
        guard text.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        let evidenceGroups = [
            ["nahrwert", "nutrition"],
            ["energie", "energy", "kcal", "kj"],
            ["protein", "eiweiss"],
            ["kohlenhydrat", "carbohydrate"],
            ["fett", "fat"],
            ["pro 100", "per 100", "100 g", "100g"],
        ]
        return evidenceGroups.filter { group in group.contains { text.contains($0) } }.count >= 2
    }

    private static func containsMeasuredQuantity(in comment: String?) -> Bool {
        guard let comment else { return false }
        let pattern = #"(?i)(?:\d+(?:[.,]\d+)?|ein(?:e|en|er|em|es)?|zwei|drei|vier|fünf)\s*(?:mg|g|gramm|kg|kilogramm|ml|milliliter|cl|dl|l|liter|el|tl|esslöffel|teelöffel)\b"#
        return comment.range(of: pattern, options: .regularExpression) != nil
    }
}
