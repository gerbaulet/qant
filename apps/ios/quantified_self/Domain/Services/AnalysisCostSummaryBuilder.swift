import Foundation

struct AnalysisCostSummary: Sendable, Equatable {
    let knownCostUSD: Double
    let isComplete: Bool
}

enum AnalysisCostSummaryBuilder {
    static func make(for calls: [AnalysisCallSummary]) -> AnalysisCostSummary? {
        guard calls.count > 1 else { return nil }
        let knownCosts = calls.compactMap { call -> Double? in
            guard let cost = call.costUSD, cost.isFinite, cost >= 0 else { return nil }
            return cost
        }
        guard !knownCosts.isEmpty else { return nil }
        return AnalysisCostSummary(
            knownCostUSD: knownCosts.reduce(0, +),
            isComplete: knownCosts.count == calls.count
        )
    }
}
