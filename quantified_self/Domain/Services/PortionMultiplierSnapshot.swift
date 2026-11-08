import Foundation

@MainActor
final class PortionMultiplierSnapshot {
    private struct NutrientKey: Hashable {
        let identifier: String
        let unit: String
    }

    private var adjustmentsByRevisionID: [UUID: PortionAdjustmentMetadata] = [:]
    private var componentDeltasByRevisionID: [UUID: [NutrientKey: Double]] = [:]

    init() {}

    func multiplier(for revision: MealAnalysisRevision) -> Double {
        adjustment(for: revision).multiplier
    }

    func scaled(_ nutrient: NutrientValue, for revision: MealAnalysisRevision) -> Double {
        let adjustment = adjustment(for: revision)
        let deltas = componentDeltasByRevisionID[revision.id] ?? componentDeltas(
            for: revision,
            multipliers: adjustment.componentMultipliers
        )
        componentDeltasByRevisionID[revision.id] = deltas
        let key = NutrientKey(
            identifier: nutrient.identifierRawValue,
            unit: nutrient.unitRawValue
        )
        return max(0, nutrient.value + deltas[key, default: 0]) * adjustment.multiplier
    }

    func scaled(_ value: Double, for revision: MealAnalysisRevision) -> Double {
        value * multiplier(for: revision)
    }

    func scaledValue(
        for identifier: NutrientIdentifier,
        in revision: MealAnalysisRevision
    ) -> Double? {
        let stored = revision.nutrients
            .filter { $0.knownIdentifier == identifier }
            .map { scaled($0, for: revision) }
            .reduce(0, +)
        let hasStoredValue = revision.nutrients.contains { $0.knownIdentifier == identifier }
        let fallback = InitialAnalysisRunMetadata.selectedNutrient(
            identifier,
            from: revision.providerMetadata,
            trigger: revision.trigger
        ).map { max(0, $0.value) * multiplier(for: revision) }

        if hasStoredValue, stored > 0 || fallback == nil {
            return stored
        }
        return fallback
    }

    private func adjustment(for revision: MealAnalysisRevision) -> PortionAdjustmentMetadata {
        if let cached = adjustmentsByRevisionID[revision.id] {
            return cached
        }
        let adjustment = InitialAnalysisRunMetadata.portionAdjustments(
            from: revision.providerMetadata
        )
        adjustmentsByRevisionID[revision.id] = adjustment
        return adjustment
    }

    private func componentDeltas(
        for revision: MealAnalysisRevision,
        multipliers: [String: Double]
    ) -> [NutrientKey: Double] {
        var deltas: [NutrientKey: Double] = [:]
        for component in revision.components {
            let factor = multipliers[component.id.uuidString] ?? 1
            guard factor != 1 else { continue }
            var seen: Set<NutrientKey> = []
            for nutrient in component.nutrients {
                let key = NutrientKey(
                    identifier: nutrient.identifierRawValue,
                    unit: nutrient.unitRawValue
                )
                guard seen.insert(key).inserted else { continue }
                deltas[key, default: 0] += nutrient.value * (factor - 1)
            }
        }
        return deltas
    }
}

enum RevisionNutritionRecovery {
    static func needsRepair(_ revision: MealAnalysisRevision) -> Bool {
        let hasCompleteComponents = !revision.components.isEmpty && revision.components.allSatisfy { component in
            let componentIdentifiers = Set(component.nutrients.compactMap(\.knownIdentifier))
            return component.estimatedWeightGrams != nil && NutritionAnalysisValidator.coreNutrients.allSatisfy {
                componentIdentifiers.contains($0)
            }
        }
        if !hasCompleteComponents { return true }

        let storedIdentifiers = Set(revision.nutrients.compactMap(\.knownIdentifier))
        let hasCompleteCoreNutrients = NutritionAnalysisValidator.coreNutrients.allSatisfy {
            storedIdentifiers.contains($0)
        }
        let storedEnergy = revision.nutrients
            .filter { $0.knownIdentifier == .energy }
            .map(\.value)
            .reduce(0, +)
        let recordedEnergy = InitialAnalysisRunMetadata.selectedEnergyKilocalories(
            from: revision.providerMetadata,
            trigger: revision.trigger
        )

        guard let recordedEnergy, recordedEnergy > 0 else { return false }
        return !hasCompleteCoreNutrients || abs(storedEnergy - recordedEnergy) > 0.5
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

    static func nutrient(
        _ identifier: NutrientIdentifier,
        in revision: MealAnalysisRevision,
        multipliers: [String: Double]
    ) -> (value: Double, unit: NutrientUnit)? {
        if let storedNutrient = revision.nutrients.first(where: { $0.knownIdentifier == identifier }) {
            return (
                nutrient(storedNutrient, in: revision, multipliers: multipliers),
                storedNutrient.knownUnit ?? (identifier == .energy ? .kilocalorie : .gram)
            )
        }
        guard let fallback = InitialAnalysisRunMetadata.selectedNutrient(
            identifier,
            from: revision.providerMetadata,
            trigger: revision.trigger
        ) else { return nil }
        return (max(0, fallback.value), fallback.unit)
    }

    static func weight(in revision: MealAnalysisRevision, multipliers: [String: Double]) -> Double? {
        guard let weight = revision.estimatedTotalWeightGrams else { return nil }
        return max(0, weight + revision.components.reduce(0) {
            $0 + ($1.estimatedWeightGrams ?? 0) * ((multipliers[$1.id.uuidString] ?? 1) - 1)
        })
    }
}
