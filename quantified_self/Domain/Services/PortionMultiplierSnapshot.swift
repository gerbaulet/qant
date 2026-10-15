import Foundation

@MainActor
final class PortionMultiplierSnapshot {
    private var valuesByRevisionID: [UUID: Double] = [:]

    init() {}

    func multiplier(for revision: MealAnalysisRevision) -> Double {
        if let cached = valuesByRevisionID[revision.id] {
            return cached
        }
        let multiplier = revision.normalizedPortionMultiplier
        valuesByRevisionID[revision.id] = multiplier
        return multiplier
    }

    private var componentsByRevisionID: [UUID: [String: Double]] = [:]

    func scaled(_ nutrient: NutrientValue, for revision: MealAnalysisRevision) -> Double {
        let values = componentsByRevisionID[revision.id] ?? InitialAnalysisRunMetadata.componentMultipliers(from: revision.providerMetadata)
        componentsByRevisionID[revision.id] = values
        return ComponentPortionScaling.nutrient(nutrient, in: revision, multipliers: values) * multiplier(for: revision)
    }

    func scaled(_ value: Double, for revision: MealAnalysisRevision) -> Double {
        value * multiplier(for: revision)
    }
}

@MainActor
enum ComponentPortionScaling {
    static func nutrient(_ nutrient: NutrientValue, in revision: MealAnalysisRevision, multipliers: [String: Double]) -> Double {
        let delta = revision.components.reduce(0.0) { total, component in
            let factor = multipliers[component.id.uuidString] ?? 1
            let value = component.nutrients.first {
                $0.identifierRawValue == nutrient.identifierRawValue && $0.unitRawValue == nutrient.unitRawValue
            }?.value ?? 0
            return total + value * (factor - 1)
        }
        return max(0, nutrient.value + delta)
    }

    static func weight(in revision: MealAnalysisRevision, multipliers: [String: Double]) -> Double? {
        guard let weight = revision.estimatedTotalWeightGrams else { return nil }
        return max(0, weight + revision.components.reduce(0) {
            $0 + ($1.estimatedWeightGrams ?? 0) * ((multipliers[$1.id.uuidString] ?? 1) - 1)
        })
    }
}
