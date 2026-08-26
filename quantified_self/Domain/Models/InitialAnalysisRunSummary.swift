import Foundation

struct InitialAnalysisRunSummary: Codable, Identifiable, Sendable, Equatable {
    let runNumber: Int
    let modelIdentifier: String
    let providerIdentifier: String?
    let energyKilocalories: Double

    var id: Int { runNumber }
}

enum InitialAnalysisRunMetadata {
    private struct Payload: Codable {
        let version: Int
        let runs: [InitialAnalysisRunSummary]
        let portionMultiplier: Double?
    }

    static func encode(_ results: [NutritionAnalysisResult]) -> String? {
        let runs = results.enumerated().compactMap { index, result -> InitialAnalysisRunSummary? in
            guard let energy = result.nutrients.first(where: {
                $0.identifier == .energy && $0.unit == .kilocalorie
            }) else { return nil }
            return InitialAnalysisRunSummary(
                runNumber: index + 1,
                modelIdentifier: result.modelIdentifier,
                providerIdentifier: result.providerIdentifier,
                energyKilocalories: energy.value
            )
        }
        guard runs.count == NutritionAnalysisConsensus.initialSampleCount else { return nil }
        guard let data = try? JSONEncoder().encode(Payload(
            version: 1,
            runs: runs,
            portionMultiplier: nil
        )) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ metadata: String?) -> [InitialAnalysisRunSummary] {
        guard
            let metadata,
            let data = metadata.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.version == 1
        else { return [] }
        return payload.runs.sorted { $0.runNumber < $1.runNumber }
    }

    static func portionMultiplier(from metadata: String?) -> Double {
        guard let payload = payload(from: metadata),
              let multiplier = payload.portionMultiplier,
              multiplier.isFinite else {
            return 1
        }
        return min(max(multiplier, 0), 5)
    }

    static func settingPortionMultiplier(_ multiplier: Double, in metadata: String?) -> String? {
        let existingPayload = payload(from: metadata)
        let normalized = multiplier.isFinite ? min(max(multiplier, 0), 5) : 1
        let updated = Payload(
            version: 1,
            runs: existingPayload?.runs ?? [],
            portionMultiplier: normalized
        )
        guard let data = try? JSONEncoder().encode(updated) else { return metadata }
        return String(data: data, encoding: .utf8)
    }

    private static func payload(from metadata: String?) -> Payload? {
        guard
            let metadata,
            let data = metadata.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.version == 1
        else { return nil }
        return payload
    }
}
