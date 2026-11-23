import Testing
@testable import Quant

struct AnalysisCostSummaryBuilderTests {
    @Test("Multiple known call costs produce a complete sum")
    func completeSum() throws {
        let summary = try #require(AnalysisCostSummaryBuilder.make(for: [
            call(number: 1, cost: 0.002),
            call(number: 2, cost: 0.0015),
        ]))

        #expect(abs(summary.knownCostUSD - 0.0035) < 0.000_000_001)
        #expect(summary.isComplete)
    }

    @Test("Missing call costs produce a known partial sum")
    func partialSum() throws {
        let summary = try #require(AnalysisCostSummaryBuilder.make(for: [
            call(number: 1, cost: 0.002),
            call(number: 2, cost: nil),
        ]))

        #expect(summary.knownCostUSD == 0.002)
        #expect(!summary.isComplete)
    }

    @Test("A single call does not produce a redundant sum")
    func singleCall() {
        #expect(AnalysisCostSummaryBuilder.make(for: [call(number: 1, cost: 0.002)]) == nil)
    }

    @Test("Multiple calls without known costs do not produce a misleading zero sum")
    func unknownSum() {
        #expect(AnalysisCostSummaryBuilder.make(for: [
            call(number: 1, cost: nil),
            call(number: 2, cost: nil),
        ]) == nil)
    }

    private func call(number: Int, cost: Double?) -> AnalysisCallSummary {
        AnalysisCallSummary(
            callNumber: number,
            sampleNumber: 1,
            attemptNumber: number,
            status: number == 1 ? .failed : .succeeded,
            modelIdentifier: "example/model",
            providerIdentifier: "Example",
            energyKilocalories: number == 1 ? nil : 640,
            errorMessage: number == 1 ? "Ungültige Antwort" : nil,
            costUSD: cost
        )
    }
}
