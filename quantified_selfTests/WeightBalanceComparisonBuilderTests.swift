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
            comparisonStart: day(-28, from: now),
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
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )

        let expected = try #require(comparison.expectedChangeKilograms)
        #expect(abs(expected - -2) < 0.0001)
        #expect(comparison.calibrationStatus == .disabled)
        #expect(!comparison.usesPersonalCalibration)
    }

    @Test("Personal calibration uses a fixed year of overlapping history")
    func personalCalibration() throws {
        let now = date(2026, 11, 11)
        let historicalWeights = stride(from: -80, through: -4, by: 4).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 80 + Double(offset + 80) * -0.08
            )
        }
        let historicalBalances = balances(
            from: -80,
            count: 80,
            relativeTo: now,
            dailyBalance: -770
        )

        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: historicalWeights,
            balances: historicalBalances,
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        guard case let .ready(
            factor,
            dailyBalanceAdjustmentKilocalories,
            uncappedDailyBalanceAdjustmentKilocalories
        ) =
            comparison.calibrationStatus else {
            Issue.record("Expected a ready personal calibration")
            return
        }
        #expect(abs(factor - 0.8) < 0.001)
        #expect(abs(dailyBalanceAdjustmentKilocalories - 154) < 0.001)
        #expect(abs(uncappedDailyBalanceAdjustmentKilocalories - 154) < 0.001)
        #expect(comparison.usesPersonalCalibration)
        let expected = try #require(comparison.expectedChangeKilograms)
        #expect(abs(expected - (-2.8 * factor)) < 0.001)
    }

    @Test("Personal calibration ignores weights before the first complete balance day")
    func calibrationStartsWithFirstCompleteBalanceDay() {
        let now = date(2026, 11, 11)
        let weightsBeforeBalanceHistory = (-120 ... -61).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 100
            )
        }
        let overlappingWeights = (-60 ... -1).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 80 + Double(offset + 60) * -0.1
            )
        }
        let firstProvisionalBalance = DailyEnergyBalance(
            date: day(-80, from: now),
            intakeKilocalories: 1_230,
            activeKilocalories: 400,
            restingKilocalories: 1_600,
            completeness: .provisionalIntake,
            isCurrentDay: false
        )
        let completeBalances = balances(
            from: -60,
            count: 60,
            relativeTo: now,
            dailyBalance: -770
        )

        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weightsBeforeBalanceHistory + overlappingWeights,
            balances: [firstProvisionalBalance] + completeBalances,
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        guard case let .ready(
            factor,
            dailyBalanceAdjustmentKilocalories,
            uncappedDailyBalanceAdjustmentKilocalories
        ) = comparison.calibrationStatus else {
            Issue.record("Expected a ready personal calibration")
            return
        }
        #expect(abs(factor - 1) < 0.001)
        #expect(abs(dailyBalanceAdjustmentKilocalories) < 0.001)
        #expect(abs(uncappedDailyBalanceAdjustmentKilocalories) < 0.001)
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
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        guard case let .collecting(weightCount, _, balanceDayCount, _, spanDays, _) =
            comparison.calibrationStatus else {
            Issue.record("Expected calibration to keep collecting history")
            return
        }
        #expect(weightCount == 7)
        #expect(balanceDayCount == 24)
        #expect(spanDays == 24)
    }

    @Test("Nineteen balance days enable comparison while eighteen remain insufficient")
    func minimumComparisonBalanceDays() {
        let now = date(2026, 11, 11)
        let weights = [-19, -14, -5, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let readyComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -19, count: 19, relativeTo: now, dailyBalance: -500),
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(readyComparison.readiness == .ready)

        let provisionalFirstDay = DailyEnergyBalance(
            date: day(-19, from: now),
            intakeKilocalories: 1_500,
            activeKilocalories: 400,
            restingKilocalories: 1_600,
            completeness: .provisionalIntake,
            isCurrentDay: false
        )
        let collectingComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: [provisionalFirstDay] + balances(
                from: -18,
                count: 18,
                relativeTo: now,
                dailyBalance: -500
            ),
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(collectingComparison.readiness == .needsBalanceDays(current: 18, required: 19))
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
            comparisonStart: day(-28, from: now),
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
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(collectingComparison.readiness == .needsWeights(
            current: 3,
            required: 4,
            spanDays: 28,
            requiredSpanDays: 19
        ))
    }

    @Test("Nineteen covered days enable comparison while eighteen remain insufficient")
    func minimumComparisonWeightSpan() {
        let now = date(2026, 11, 11)
        let completeBalances = balances(
            from: -28,
            count: 28,
            relativeTo: now,
            dailyBalance: -500
        )
        let nineteenDayWeights = [-19, -14, -5, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let readyComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: nineteenDayWeights,
            balances: completeBalances,
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(readyComparison.readiness == .ready)

        let eighteenDayWeights = [-18, -13, -5, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let collectingComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: eighteenDayWeights,
            balances: completeBalances,
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )
        #expect(collectingComparison.readiness == .needsWeights(
            current: 4,
            required: 4,
            spanDays: 18,
            requiredSpanDays: 19
        ))
    }

    @Test("A selected week uses its seven-day window and attainable requirements")
    func selectedWeekWindow() {
        let now = date(2026, 11, 11)
        let weights = [-10, -6, -4, -2, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -6, count: 6, relativeTo: now, dailyBalance: -500),
            comparisonStart: day(-6, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )

        #expect(comparison.interval.start == day(-6, from: now))
        #expect(comparison.dailyWeights.map(\.date) == [-6, -4, -2, 0].map {
            day($0, from: now)
        })
        #expect(comparison.evaluableBalanceDayCount == 6)
        #expect(comparison.readiness == .ready)
    }

    @Test("A selected year starts on its first day with nutrition data")
    func selectedYearStartsWithNutritionData() throws {
        let now = date(2026, 11, 11)
        let weights = [-100, -20, -15, -5, 0].map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(from: -20, count: 20, relativeTo: now, dailyBalance: -500),
            comparisonStart: day(-364, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: false
        )

        #expect(comparison.interval.start == day(-20, from: now))
        #expect(comparison.dailyWeights.map(\.date) == [-20, -15, -5, 0].map {
            day($0, from: now)
        })
        #expect(comparison.expectedTrend.first?.date == day(-20, from: now))
        #expect(comparison.evaluableBalanceDayCount == 20)
        let expectedChange = try #require(comparison.expectedChangeKilograms)
        #expect(abs(expectedChange - (-10_000 / 7_700)) < 0.0001)
    }

    @Test("Personal calibration does not change with the selected display range")
    func calibrationIsDisplayRangeIndependent() {
        let now = date(2026, 11, 11)
        let weights = (-80 ... -1).map { offset in
            WeightMeasurement(
                date: day(offset, from: now),
                kilograms: 80 - Double(offset + 80) * 0.01
            )
        }
        let history = balances(
            from: -80,
            count: 80,
            relativeTo: now,
            dailyBalance: -100
        )

        let week = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: history,
            comparisonStart: day(-6, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )
        let year = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: history,
            comparisonStart: day(-364, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        #expect(week.calibrationStatus == year.calibrationStatus)
        guard case .ready = week.calibrationStatus else {
            Issue.record("Expected a range-independent ready calibration")
            return
        }
    }

    @Test("Daily personal balance adjustment is conservatively capped")
    func calibrationAdjustmentIsCapped() {
        let now = date(2026, 11, 11)
        let weights = (-50 ... -1).map { offset in
            WeightMeasurement(date: day(offset, from: now), kilograms: 80)
        }
        let comparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: weights,
            balances: balances(
                from: -50,
                count: 50,
                relativeTo: now,
                dailyBalance: -1_000
            ),
            comparisonStart: day(-28, from: now),
            now: now,
            calendar: calendar,
            calibrationEnabled: true
        )

        guard case let .ready(
            _,
            dailyBalanceAdjustmentKilocalories,
            uncappedDailyBalanceAdjustmentKilocalories
        ) =
            comparison.calibrationStatus else {
            Issue.record("Expected a ready personal calibration")
            return
        }
        #expect(dailyBalanceAdjustmentKilocalories == 500)
        #expect(uncappedDailyBalanceAdjustmentKilocalories == 1_000)
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
