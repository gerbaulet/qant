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

    func scaled(_ value: Double, for revision: MealAnalysisRevision) -> Double {
        value * multiplier(for: revision)
    }
}
