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
    let requestedAt: Date?
    let clarificationQuestion: String?
    let clarificationAnswer: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Double?

    init(
        callNumber: Int,
        sampleNumber: Int?,
        attemptNumber: Int,
        status: AnalysisCallStatus,
        modelIdentifier: String?,
        providerIdentifier: String?,
        energyKilocalories: Double?,
        errorMessage: String?,
        requestedAt: Date? = nil,
        clarificationQuestion: String? = nil,
        clarificationAnswer: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.callNumber = callNumber
        self.sampleNumber = sampleNumber
        self.attemptNumber = attemptNumber
        self.status = status
        self.modelIdentifier = modelIdentifier
        self.providerIdentifier = providerIdentifier
        self.energyKilocalories = energyKilocalories
        self.errorMessage = errorMessage
        self.requestedAt = requestedAt
        self.clarificationQuestion = clarificationQuestion
        self.clarificationAnswer = clarificationAnswer
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }

    var id: Int { callNumber }
}

struct PortionAdjustmentMetadata: Sendable, Equatable {
    let multiplier: Double
    let componentMultipliers: [String: Double]
}

enum InitialAnalysisRunMetadata {
    private struct PayloadV1: Codable {
        let version: Int
        let runs: [InitialAnalysisRunSummary]
        let portionMultiplier: Double?
        var componentMultipliers: [String: Double]? = nil
    }

    private struct PayloadV2: Codable {
        let version: Int
        let calls: [AnalysisCallSummary]
        let portionMultiplier: Double?
        var componentMultipliers: [String: Double]? = nil
        var selectedNutrients: [AnalyzedNutrient]? = nil
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
        guard !runs.isEmpty else { return nil }
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

    static func encodeCalls(
        _ calls: [AnalysisCallSummary],
        selectedNutrients: [AnalyzedNutrient]? = nil
    ) -> String? {
        guard !calls.isEmpty,
              let data = try? JSONEncoder().encode(PayloadV2(
                version: 2,
                calls: calls,
                portionMultiplier: nil,
                selectedNutrients: selectedNutrients
              )) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeCalls(_ metadata: String?) -> [AnalysisCallSummary] {
        guard let payload = payloadV2(from: metadata), payload.version == 2 else { return [] }
        return payload.calls.sorted { $0.callNumber < $1.callNumber }
    }

    static func selectedNutrient(
        _ identifier: NutrientIdentifier,
        from metadata: String?,
        trigger: AnalysisTrigger
    ) -> AnalyzedNutrient? {
        if let nutrient = payloadV2(from: metadata)?.selectedNutrients?.first(where: {
            $0.identifier == identifier
        }) {
            return nutrient
        }
        guard identifier == .energy,
              let energy = selectedEnergyKilocalories(from: metadata, trigger: trigger) else {
            return nil
        }
        return AnalyzedNutrient(
            identifier: .energy,
            value: energy,
            unit: .kilocalorie,
            confidence: .medium,
            provenance: .unknown
        )
    }

    static func selectedEnergyKilocalories(
        from metadata: String?,
        trigger: AnalysisTrigger
    ) -> Double? {
        let calls = decodeCalls(metadata)
        if !calls.isEmpty {
            let successful = calls.filter {
                $0.status == .succeeded && $0.energyKilocalories != nil
            }
            guard !successful.isEmpty else { return nil }
            if trigger == .initial {
                let resultsBySample = Dictionary(grouping: successful) {
                    $0.sampleNumber ?? $0.callNumber
                }.compactMapValues { calls in
                    calls.max(by: { $0.attemptNumber < $1.attemptNumber })?.energyKilocalories
                }
                if resultsBySample.count == 3 {
                    return resultsBySample.values.sorted()[1]
                }
                return resultsBySample[1] ?? successful.last?.energyKilocalories
            }
            return successful.last?.energyKilocalories
        }

        let runs = decodeLegacyRuns(metadata)
        guard !runs.isEmpty else { return nil }
        if trigger == .initial, runs.count == 3 {
            return runs.map(\.energyKilocalories).sorted()[1]
        }
        return runs.first?.energyKilocalories
    }

    static func portionMultiplier(from metadata: String?) -> Double {
        portionAdjustments(from: metadata).multiplier
    }

    static func portionAdjustments(from metadata: String?) -> PortionAdjustmentMetadata {
        let v2 = payloadV2(from: metadata)
        let v1 = v2 == nil ? payloadV1(from: metadata) : nil
        let multiplier = v2?.portionMultiplier ?? v1?.portionMultiplier
        guard let multiplier,
              multiplier.isFinite else {
            return PortionAdjustmentMetadata(
                multiplier: 1,
                componentMultipliers: v2?.componentMultipliers ?? v1?.componentMultipliers ?? [:]
            )
        }
        return PortionAdjustmentMetadata(
            multiplier: min(max(multiplier, 0), 4),
            componentMultipliers: v2?.componentMultipliers ?? v1?.componentMultipliers ?? [:]
        )
    }

    static func settingPortionMultiplier(_ multiplier: Double, in metadata: String?) -> String? {
        let normalized = multiplier.isFinite ? min(max(multiplier, 0), 4) : 1
        let data: Data?
        if let existing = payloadV2(from: metadata) {
            data = try? JSONEncoder().encode(PayloadV2(
                version: 2,
                calls: existing.calls,
                portionMultiplier: normalized,
                componentMultipliers: componentMultipliers(from: metadata),
                selectedNutrients: existing.selectedNutrients
            ))
        } else {
            data = try? JSONEncoder().encode(PayloadV1(
                version: 1,
                runs: payloadV1(from: metadata)?.runs ?? [],
                portionMultiplier: normalized,
                componentMultipliers: componentMultipliers(from: metadata)
            ))
        }
        guard let data else { return metadata }
        return String(data: data, encoding: .utf8)
    }

    static func componentMultipliers(from metadata: String?) -> [String: Double] {
        portionAdjustments(from: metadata).componentMultipliers
    }

    static func settingComponentMultipliers(_ values: [String: Double], in metadata: String?) -> String? {
        let base = settingPortionMultiplier(portionMultiplier(from: metadata), in: metadata)
        guard let data = base?.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return metadata }
        object["componentMultipliers"] = values.mapValues { $0.isFinite ? min(max($0, 0), 4) : 1 }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return metadata }
        return String(data: encoded, encoding: .utf8)
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

    private static func decodeLegacyRuns(_ metadata: String?) -> [InitialAnalysisRunSummary] {
        guard let payload = payloadV1(from: metadata) else { return [] }
        return payload.runs.sorted { $0.runNumber < $1.runNumber }
    }
}
