import Foundation
import Testing
@testable import Quant

struct RestingEnergyInterpolationBuilderTests {
    @Test("A trailing overnight gap uses the personal hourly profile")
    func fillsTrailingOvernightGap() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 8, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 8,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.count == 8)
        for (hour, interval) in filled.enumerated() {
            #expect(abs((interval.kilocalories ?? 0) - Double(50 + hour)) < 0.001)
            #expect(abs(interval.estimatedKilocalories - Double(50 + hour)) < 0.001)
            #expect(interval.coverage.estimatedDuration == 3_600)
            #expect(interval.coverage.isComplete)
        }
    }

    @Test("An exact eighteen-hour gap is estimated")
    func fillsEighteenHourGap() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 18, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 18,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.allSatisfy { $0.kilocalories != nil })
        #expect(filled.allSatisfy { $0.coverage.estimatedDuration == 3_600 })
        #expect(filled.allSatisfy { !$0.coverage.hasExcessiveGap })
    }

    @Test("A gap over eighteen hours is not estimated")
    func rejectsGapOverEighteenHours() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 19, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 19,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.allSatisfy { $0.kilocalories == nil })
        #expect(filled.allSatisfy { $0.coverage.estimatedDuration == 0 })
        #expect(filled.allSatisfy { $0.coverage.hasExcessiveGap })
    }

    @Test("An exact eighteen-hour gap is estimated across a day boundary")
    func fillsEighteenHourGapAcrossDayBoundary() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 23
        )))
        let gapStart = try #require(calendar.date(byAdding: .hour, value: -1, to: targetStart))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 17, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values += hourlyIntervals(
            from: gapStart,
            hourCount: 18,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )
        let aggregate = RestingEnergyFusionBuilder.aggregate(filled)

        #expect(filled.count == 17)
        #expect(filled.allSatisfy { $0.kilocalories != nil })
        #expect(filled.allSatisfy { !$0.coverage.hasExcessiveGap })
        #expect(aggregate.coverage?.missingDuration == 0)
        #expect(aggregate.coverage?.isUsableForLiveFeatures == true)
    }

    @Test("Separate gaps below eighteen hours are estimated independently")
    func fillsSeparateShortGaps() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 21, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 10,
            kilocalories: nil,
            calendar: calendar
        )
        let measuredHour = try #require(calendar.date(byAdding: .hour, value: 10, to: targetStart))
        values.append(measuredInterval(start: measuredHour, kilocalories: 70))
        let secondGap = try #require(calendar.date(byAdding: .hour, value: 11, to: targetStart))
        values += hourlyIntervals(
            from: secondGap,
            hourCount: 10,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.filter { $0.coverage.estimatedDuration > 0 }.count == 20)
        #expect(filled.first { $0.interval.start == measuredHour }?.kilocalories == 70)
        #expect(filled.first { $0.interval.start == measuredHour }?.estimatedKilocalories == 0)
    }

    @Test("A partial measured hour is only completed proportionally")
    func fillsPartialHourProportionally() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 1, to: targetStart))
        var values = measuredProfile(
            from: start,
            dayCount: 2,
            hourlyKilocalories: { _ in 60 },
            calendar: calendar
        )
        values.append(FusedRestingEnergyInterval(
            interval: DateInterval(start: targetStart, duration: 3_600),
            kilocalories: 30,
            estimatedKilocalories: 0,
            coverage: RestingEnergyCoverage(
                expectedDuration: 3_600,
                primaryDuration: 1_800,
                iPhoneFallbackDuration: 0
            )
        ))

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        let hour = try #require(filled.first)
        #expect(hour.kilocalories == 60)
        #expect(hour.estimatedKilocalories == 30)
        #expect(hour.coverage.primaryDuration == 1_800)
        #expect(hour.coverage.estimatedDuration == 1_800)
    }

    @Test("The unpublished current partial hour is estimated from the profile")
    func fillsPendingCurrentPartialHour() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .minute, value: 30, to: targetStart))
        var values = measuredProfile(
            from: start,
            dayCount: 2,
            hourlyKilocalories: { _ in 60 },
            calendar: calendar
        )
        values.append(FusedRestingEnergyInterval(
            interval: DateInterval(start: targetStart, end: targetEnd),
            kilocalories: nil,
            coverage: RestingEnergyCoverage(
                expectedDuration: 1_800,
                primaryDuration: 0,
                iPhoneFallbackDuration: 0,
                pendingDuration: 1_800
            )
        ))

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        let hour = try #require(filled.first)
        #expect(abs((hour.kilocalories ?? 0) - 30) < 0.001)
        #expect(hour.coverage.estimatedDuration == 1_800)
    }

    @Test("Estimation needs twenty-four measured hours from two days")
    func requiresSufficientPersonalHistory() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 1, to: targetStart))
        var values = hourlyIntervals(
            from: start,
            hourCount: 24,
            kilocalories: 60,
            calendar: calendar
        )
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 1,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.first?.kilocalories == nil)
        #expect(filled.first?.coverage.estimatedDuration == 0)
    }

    @Test("The overall median fills hours without a same-hour history")
    func fallsBackToOverallMedian() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20,
            hour: 8
        )))
        let secondStart = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let targetStart = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 22)
        ))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 1, to: targetStart))
        var values = hourlyIntervals(
            from: start,
            hourCount: 12,
            kilocalories: 60,
            calendar: calendar
        )
        values += hourlyIntervals(
            from: secondStart,
            hourCount: 12,
            kilocalories: 60,
            calendar: calendar
        )
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 1,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.first?.kilocalories == 60)
        #expect(filled.first?.estimatedKilocalories == 60)
    }

    @Test("A later Health value replaces the estimate instead of being added")
    func lateHealthValueReplacesEstimate() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20
        )))
        let targetStart = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 1, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values.append(measuredInterval(start: targetStart, kilocalories: 72))

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        let hour = try #require(filled.first)
        #expect(hour.kilocalories == 72)
        #expect(hour.estimatedKilocalories == 0)
        #expect(hour.coverage.primaryDuration == 3_600)
        #expect(hour.coverage.estimatedDuration == 0)
    }

    @Test("Hourly estimates follow local calendar hours across daylight saving time")
    func followsCalendarAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 26
        )))
        let targetStart = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 29
        )))
        let targetEnd = try #require(calendar.date(byAdding: .hour, value: 4, to: targetStart))
        var values = measuredProfile(from: start, dayCount: 2, calendar: calendar)
        values += hourlyIntervals(
            from: targetStart,
            hourCount: 4,
            kilocalories: nil,
            calendar: calendar
        )

        let filled = RestingEnergyInterpolationBuilder.fillGaps(
            in: values,
            from: targetStart,
            to: targetEnd,
            calendar: calendar
        )

        #expect(filled.count == 4)
        #expect(filled.map { calendar.component(.hour, from: $0.interval.start) } == [0, 1, 3, 4])
        #expect(filled.allSatisfy { $0.coverage.estimatedDuration == 3_600 })
    }

    private func measuredProfile(
        from start: Date,
        dayCount: Int,
        hourlyKilocalories: (Int) -> Double = { Double(50 + $0) },
        calendar: Calendar
    ) -> [FusedRestingEnergyInterval] {
        (0..<dayCount).flatMap { day in
            let dayStart = calendar.date(byAdding: .day, value: day, to: start)!
            return (0..<24).map { hour in
                let hourStart = calendar.date(byAdding: .hour, value: hour, to: dayStart)!
                return measuredInterval(
                    start: hourStart,
                    kilocalories: hourlyKilocalories(hour)
                )
            }
        }
    }

    private func hourlyIntervals(
        from start: Date,
        hourCount: Int,
        kilocalories: Double?,
        calendar: Calendar
    ) -> [FusedRestingEnergyInterval] {
        (0..<hourCount).map { hour in
            let hourStart = calendar.date(byAdding: .hour, value: hour, to: start)!
            if let kilocalories {
                return measuredInterval(start: hourStart, kilocalories: kilocalories)
            }
            return FusedRestingEnergyInterval(
                interval: DateInterval(start: hourStart, duration: 3_600),
                kilocalories: nil,
                estimatedKilocalories: 0,
                coverage: RestingEnergyCoverage(
                    expectedDuration: 3_600,
                    primaryDuration: 0,
                    iPhoneFallbackDuration: 0
                )
            )
        }
    }

    private func measuredInterval(
        start: Date,
        kilocalories: Double
    ) -> FusedRestingEnergyInterval {
        FusedRestingEnergyInterval(
            interval: DateInterval(start: start, duration: 3_600),
            kilocalories: kilocalories,
            estimatedKilocalories: 0,
            coverage: RestingEnergyCoverage(
                expectedDuration: 3_600,
                primaryDuration: 3_600,
                iPhoneFallbackDuration: 0
            )
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
