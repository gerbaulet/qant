import Foundation
import Testing
@testable import Quant

@MainActor
struct HealthMetricsModelTests {
    @Test("An empty historical Health query stays cached across hours")
    func cachesEmptyHistoricalQueryRange() async {
        var now = Date(timeIntervalSince1970: 200_000)
        let provider = StubHealthEnergyProvider(results: [[]])
        let preferences = StubHealthAccessPreferences(hasRequestedEnergyAccess: true)
        let model = HealthMetricsModel(
            energyProvider: provider,
            preferences: preferences,
            now: { now }
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: Calendar(identifier: .gregorian)
        )
        now = Date(timeIntervalSince1970: 204_000)
        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(provider.queryCount == 1)
        #expect(model.energyStatus == .noData)
    }

    @Test("The current Health day refreshes after the hour changes")
    func refreshesCurrentDayAfterHourChange() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 16
        ))!
        var now = calendar.date(byAdding: .hour, value: 8, to: day)!
        let expenditure = DailyEnergyExpenditure(
            date: day,
            activeKilocalories: 350,
            restingKilocalories: 700
        )
        let provider = StubHealthEnergyProvider(results: [[], [expenditure]])
        let preferences = StubHealthAccessPreferences(hasRequestedEnergyAccess: true)
        let model = HealthMetricsModel(
            energyProvider: provider,
            preferences: preferences,
            now: { now }
        )
        let interval = DateInterval(
            start: calendar.date(byAdding: .day, value: -7, to: day)!,
            end: calendar.date(byAdding: .day, value: 1, to: day)!
        )
        let currentDayInterval = DateInterval(
            start: day,
            end: interval.end
        )

        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: calendar
        )
        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: calendar
        )
        #expect(provider.queryCount == 1)
        #expect(model.energyExpenditures.isEmpty)

        now = calendar.date(byAdding: .hour, value: 1, to: now)!
        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: calendar
        )

        #expect(provider.queryCount == 2)
        #expect(provider.queriedIntervals == [interval, currentDayInterval])
        #expect(model.energyExpenditures == [expenditure])
        #expect(model.energyStatus == .available)
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

    @Test("Daily and hourly Health data refresh atomically after the hour changes")
    func refreshesCurrentEnergyAfterHourChange() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 16
        ))!
        var now = calendar.date(byAdding: .hour, value: 8, to: day)!
        let expenditure = HourlyEnergyExpenditure(
            date: calendar.date(byAdding: .hour, value: 7, to: day)!,
            activeKilocalories: 25,
            restingKilocalories: 65
        )
        let provider = StubHealthEnergyProvider(
            results: [[], []],
            hourlyResults: [[], [expenditure]]
        )
        let preferences = StubHealthAccessPreferences(hasRequestedEnergyAccess: true)
        let model = HealthMetricsModel(
            energyProvider: provider,
            preferences: preferences,
            now: { now }
        )
        let interval = DateInterval(
            start: calendar.date(byAdding: .day, value: -7, to: day)!,
            end: calendar.date(byAdding: .day, value: 1, to: day)!
        )
        let currentDayInterval = DateInterval(start: day, end: interval.end)

        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: calendar
        )
        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: calendar
        )
        #expect(provider.queryCount == 1)

        now = calendar.date(byAdding: .hour, value: 1, to: now)!
        await model.loadEnergy(
            from: interval.start,
            to: interval.end,
            calendar: calendar
        )

        #expect(provider.queryCount == 2)
        #expect(provider.queriedIntervals == [interval, currentDayInterval])
        #expect(model.hourlyEnergyExpenditures == [expenditure])
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
    private var hourlyResults: [[HourlyEnergyExpenditure]]
    private(set) var queryCount = 0
    private(set) var queriedIntervals: [DateInterval] = []

    init(
        results: [[DailyEnergyExpenditure]],
        hourlyResults: [[HourlyEnergyExpenditure]] = []
    ) {
        self.results = results
        self.hourlyResults = hourlyResults
    }

    func isHealthDataAvailable() -> Bool { true }

    func requestEnergyAuthorization() async throws {}

    func energy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> EnergyExpenditureSnapshot {
        queryCount += 1
        queriedIntervals.append(DateInterval(start: startDate, end: endDate))
        return EnergyExpenditureSnapshot(
            daily: results.isEmpty ? [] : results.removeFirst(),
            hourly: hourlyResults.isEmpty ? [] : hourlyResults.removeFirst()
        )
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
