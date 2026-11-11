import Foundation
import Testing
@testable import Quant

@MainActor
struct HealthMetricsModelTests {
    @Test("An empty Health query is cached and not repeated")
    func cachesEmptyQueryRange() async {
        let provider = StubHealthEnergyProvider(results: [[]])
        let preferences = StubHealthAccessPreferences(hasRequestedEnergyAccess: true)
        let model = HealthMetricsModel(energyProvider: provider, preferences: preferences)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: Calendar(identifier: .gregorian)
        )
        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(provider.queryCount == 1)
        #expect(model.energyStatus == .noData)
    }

    @Test("A forced refresh removes Health values that no longer exist")
    func forcedRefreshReplacesRange() async {
        let date = Date(timeIntervalSince1970: 1_200)
        let provider = StubHealthEnergyProvider(results: [
            [DailyEnergyExpenditure(
                date: date,
                activeKilocalories: 400,
                restingKilocalories: 1_600
            )],
            [],
        ])
        let preferences = StubHealthAccessPreferences(hasRequestedEnergyAccess: true)
        let model = HealthMetricsModel(energyProvider: provider, preferences: preferences)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(model.energyExpenditures.count == 1)

        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: Calendar(identifier: .gregorian),
            force: true
        )

        #expect(model.energyExpenditures.isEmpty)
        #expect(provider.queryCount == 2)
    }
}

@MainActor
private final class StubHealthEnergyProvider: HealthEnergyProviding {
    private var results: [[DailyEnergyExpenditure]]
    private(set) var queryCount = 0

    init(results: [[DailyEnergyExpenditure]]) {
        self.results = results
    }

    func isHealthDataAvailable() -> Bool { true }

    func requestEnergyAuthorization() async throws {}

    func dailyEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> [DailyEnergyExpenditure] {
        queryCount += 1
        return results.isEmpty ? [] : results.removeFirst()
    }

    func earliestAuthorizedEnergyDate() async throws -> Date? { nil }
}

@MainActor
private final class StubHealthAccessPreferences: HealthAccessPreferenceStoring {
    var hasRequestedEnergyAccess: Bool

    init(hasRequestedEnergyAccess: Bool) {
        self.hasRequestedEnergyAccess = hasRequestedEnergyAccess
    }
}
