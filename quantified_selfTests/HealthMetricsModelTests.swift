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

    @Test("Weight queries are cached and personal calibration can be toggled")
    func cachesWeightsAndUpdatesCalibrationPreference() async {
        let energyProvider = StubHealthEnergyProvider(results: [])
        let weightProvider = StubHealthWeightProvider(results: [[]])
        let energyPreferences = StubHealthAccessPreferences(hasRequestedEnergyAccess: false)
        let weightPreferences = StubHealthWeightPreferences(
            hasRequestedWeightAccess: true,
            personalCalibrationEnabled: true
        )
        let model = HealthMetricsModel(
            energyProvider: energyProvider,
            preferences: energyPreferences,
            weightProvider: weightProvider,
            weightPreferences: weightPreferences
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        await model.loadWeights(from: interval.start, to: interval.end)
        await model.loadWeights(from: interval.start, to: interval.end)
        model.personalCalibrationEnabled = false

        #expect(weightProvider.queryCount == 1)
        #expect(model.weightStatus == .noData)
        #expect(!weightPreferences.personalCalibrationEnabled)
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

@MainActor
private final class StubHealthWeightProvider: HealthWeightProviding {
    private var results: [[WeightMeasurement]]
    private(set) var queryCount = 0

    init(results: [[WeightMeasurement]]) {
        self.results = results
    }

    func isHealthDataAvailable() -> Bool { true }

    func requestWeightAuthorization() async throws {}

    func weightMeasurements(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [WeightMeasurement] {
        queryCount += 1
        return results.isEmpty ? [] : results.removeFirst()
    }
}

@MainActor
private final class StubHealthWeightPreferences: HealthWeightPreferenceStoring {
    var hasRequestedWeightAccess: Bool
    var personalCalibrationEnabled: Bool

    init(hasRequestedWeightAccess: Bool, personalCalibrationEnabled: Bool) {
        self.hasRequestedWeightAccess = hasRequestedWeightAccess
        self.personalCalibrationEnabled = personalCalibrationEnabled
    }
}
