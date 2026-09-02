import Foundation

struct InitialAnalysisRunSummary: Codable, Identifiable, Sendable, Equatable {
    let runNumber: Int
    let modelIdentifier: String
    let providerIdentifier: String?
    let energyKilocalories: Double

    var id: Int { runNumber }
}

enum AnalysisCallStatus: String, Codable, Sendable {
    case succeeded
    case failed
}

struct AnalysisCallSummary: Codable, Identifiable, Sendable, Equatable {
    let callNumber: Int
    let sampleNumber: Int?
    let attemptNumber: Int
    let status: AnalysisCallStatus
    let modelIdentifier: String?
    let providerIdentifier: String?
    let energyKilocalories: Double?
    let errorMessage: String?

    var id: Int { callNumber }
}

enum InitialAnalysisRunMetadata {
    private struct PayloadV1: Codable {
        let version: Int
        let runs: [InitialAnalysisRunSummary]
        let portionMultiplier: Double?
    }

    private struct PayloadV2: Codable {
        let version: Int
        let calls: [AnalysisCallSummary]
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
        guard let data = try? JSONEncoder().encode(PayloadV1(
            version: 1,
            runs: runs,
            portionMultiplier: nil
        )) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ metadata: String?) -> [InitialAnalysisRunSummary] {
        let calls = decodeCalls(metadata)
        if !calls.isEmpty {
            return calls.compactMap { call in
                guard call.status == .succeeded,
                      let model = call.modelIdentifier,
                      let energy = call.energyKilocalories else { return nil }
                return InitialAnalysisRunSummary(
                    runNumber: call.sampleNumber ?? call.callNumber,
                    modelIdentifier: model,
                    providerIdentifier: call.providerIdentifier,
                    energyKilocalories: energy
                )
            }
        }
        guard
            let metadata,
            let data = metadata.data(using: .utf8),
            let payload = try? JSONDecoder().decode(PayloadV1.self, from: data),
            payload.version == 1
        else { return [] }
        return payload.runs.sorted { $0.runNumber < $1.runNumber }
    }

    static func encodeCalls(_ calls: [AnalysisCallSummary]) -> String? {
        guard !calls.isEmpty,
              let data = try? JSONEncoder().encode(PayloadV2(
                version: 2,
                calls: calls,
                portionMultiplier: nil
              )) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeCalls(_ metadata: String?) -> [AnalysisCallSummary] {
        guard let payload = payloadV2(from: metadata), payload.version == 2 else { return [] }
        return payload.calls.sorted { $0.callNumber < $1.callNumber }
    }

    static func portionMultiplier(from metadata: String?) -> Double {
        let multiplier = payloadV2(from: metadata)?.portionMultiplier ?? payloadV1(from: metadata)?.portionMultiplier
        guard let multiplier,
              multiplier.isFinite else {
            return 1
        }
        return min(max(multiplier, 0), 5)
    }

    static func settingPortionMultiplier(_ multiplier: Double, in metadata: String?) -> String? {
        let normalized = multiplier.isFinite ? min(max(multiplier, 0), 5) : 1
        let data: Data?
        if let existing = payloadV2(from: metadata) {
            data = try? JSONEncoder().encode(PayloadV2(
                version: 2,
                calls: existing.calls,
                portionMultiplier: normalized
            ))
        } else {
            data = try? JSONEncoder().encode(PayloadV1(
                version: 1,
                runs: payloadV1(from: metadata)?.runs ?? [],
                portionMultiplier: normalized
            ))
        }
        guard let data else { return metadata }
        return String(data: data, encoding: .utf8)
    }

    private static func payloadV1(from metadata: String?) -> PayloadV1? {
        guard
            let metadata,
            let data = metadata.data(using: .utf8),
            let payload = try? JSONDecoder().decode(PayloadV1.self, from: data),
            payload.version == 1
        else { return nil }
        return payload
    }

    private static func payloadV2(from metadata: String?) -> PayloadV2? {
        guard let metadata, let data = metadata.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PayloadV2.self, from: data)
    }
}
