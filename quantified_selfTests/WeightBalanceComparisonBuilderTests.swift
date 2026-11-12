import Foundation
import Testing
@testable import Quant

@MainActor
struct WeightBalanceComparisonBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test("Multiple measurements on one day are reduced to their median")
    func dailyMedian() {
        let day = date(2026, 11, 10)
        let weights = WeightBalanceComparisonBuilder.dailyMedians(
            [
                WeightMeasurement(date: day, kilograms: 80),
                WeightMeasurement(date: day.addingTimeInterval(60), kilograms: 80.2),
                WeightMeasurement(date: day.addingTimeInterval(120), kilograms: 100),
            ],
            calendar: calendar
        )

        #expect(weights.count == 1)
        #expect(weights[0].kilograms == 80.2)
    }

    @Test("The robust trend resists a single weight outlier")
    func robustTrend() throws {
        let now = date(2026, 11, 11)
        let weights = stride(from: -28, through: 0, by: 4).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 80 + Double(offset) * -0.1 + (offset == -12 ? 10 : 0)
            )
        }
        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -28, count: 28, relativeTo: now, dailyBalance: -500),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )

        let observed = try #require(comparison.observedChangeKilograms)
        #expect(abs(observed - -2.8) < 0.05)
        #expect(comparison.readiness == .ready)
    }

    @Test("The standard expectation converts complete energy balance days into kilograms")
    func standardExpectedChange() throws {
        let now = date(2026, 11, 11)
        let weights = stride(from: -28, through: 0, by: 4).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 80 + Double(offset) * -0.02
            )
        }
        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -28, count: 28, relativeTo: now, dailyBalance: -550),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )

        let expected = try #require(comparison.expectedChangeKilograms)
        #expect(abs(expected - -2) < 0.0001)
        #expect(comparison.calibrationStatus == .disabled)
        #expect(!comparison.usesPersonalCalibration)
    }

    @Test("Personal calibration uses six weeks of prior weight and balance history")
    func personalCalibration() throws {
        let now = date(2026, 11, 11)
        let trainingWeights = stride(from: -80, through: -36, by: 4).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 80 + Double(offset + 80) * -0.08
            )
        }
        let comparisonWeights = stride(from: -28, through: 0, by: 4).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 76.5 + Double(offset + 28) * -0.06
            )
        }
        let trainingBalances = balances(
            from: -80,
            count: 42,
            relativeTo: now,
            dailyBalance: -770
        )
        let comparisonBalances = balances(
            from: -28,
            count: 28,
            relativeTo: now,
            dailyBalance: -770
        )
        let balancesBeforeWeightHistory = balances(
            from: -100,
            count: 10,
            relativeTo: now,
            dailyBalance: -2_000
        )

        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: trainingWeights + comparisonWeights,
            balances: balancesBeforeWeightHistory + trainingBalances + comparisonBalances,
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        guard case let .ready(factor) = comparison.calibrationStatus else {
            Issue.record("Expected a ready personal calibration")
            return
        }
        #expect(abs(factor - (3.52 / 4.2)) < 0.001)
        #expect(comparison.usesPersonalCalibration)
        let expected = try #require(comparison.expectedChangeKilograms)
        #expect(abs(expected - (-2.8 * factor)) < 0.001)
    }

    @Test("Calibration stays in collection mode below the strict history thresholds")
    func calibrationCollectsHistory() {
        let now = date(2026, 11, 11)
        let comparisonWeights = stride(from: -28, through: 0, by: 4).map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: comparisonWeights,
            balances: balances(from: -28, count: 28, relativeTo: now, dailyBalance: -500),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        guard case let .collecting(weightCount, _, balanceDayCount, _, spanDays, _) =
            comparison.calibrationStatus else {
            Issue.record("Expected calibration to keep collecting history")
            return
        }
        #expect(weightCount == 0)
        #expect(balanceDayCount == 0)
        #expect(spanDays == 0)
    }

    @Test("Twenty balance days enable comparison while nineteen remain insufficient")
    func minimumComparisonBalanceDays() {
        let now = date(2026, 11, 11)
        let weights = stride(from: -28, through: 0, by: 4).map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let readyComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -20, count: 20, relativeTo: now, dailyBalance: -500),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(readyComparison.readiness == .ready)

        let collectingComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -19, count: 19, relativeTo: now, dailyBalance: -500),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(collectingComparison.readiness == .needsBalanceDays(current: 19, required: 20))
    }

    @Test("Four weight days enable comparison while three remain insufficient")
    func minimumComparisonWeightDays() {
        let now = date(2026, 11, 11)
        let completeBalances = balances(
            from: -28,
            count: 28,
            relativeTo: now,
            dailyBalance: -500
        )
        let fourWeights = [-28, -21, -7, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let readyComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: fourWeights,
            balances: completeBalances,
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(readyComparison.readiness == .ready)

        let threeWeights = [-28, -14, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let collectingComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: threeWeights,
            balances: completeBalances,
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(collectingComparison.readiness == .needsWeights(
            current: 3,
            required: 4,
            spanDays: 28,
            requiredSpanDays: 20
        ))
    }

    @Test("Twenty covered days enable comparison while nineteen remain insufficient")
    func minimumComparisonWeightSpan() {
        let now = date(2026, 11, 11)
        let completeBalances = balances(
            from: -28,
            count: 28,
            relativeTo: now,
            dailyBalance: -500
        )
        let twentyDayWeights = [-20, -15, -5, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let readyComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: twentyDayWeights,
            balances: completeBalances,
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(readyComparison.readiness == .ready)

        let nineteenDayWeights = [-19, -14, -5, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let collectingComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: nineteenDayWeights,
            balances: completeBalances,
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(collectingComparison.readiness == .needsWeights(
            current: 4,
            required: 4,
            spanDays: 19,
            requiredSpanDays: 20
        ))
    }

    private func balances(
        from firstOffset: Int,
        count: Int,
        relativeTo now: Date,
        dailyBalance: Double
    ) -> [DailyEnergyBalance] {
        (0..<count).map { index in
            let date = day(firstOffset + index, from: now)
            return DailyEnergyBalance(
                date: date,
                intakeKilocalories: 2_000 + dailyBalance,
                activeKilocalories: 400,
                restingKilocalories: 1_600,
                completeness: .complete,
                isCurrentDay: false
            )
        }
    }

    private func day(_ offset: Int, from date: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: date)!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
