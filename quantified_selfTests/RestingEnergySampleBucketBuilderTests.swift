import Foundation
import Testing
@testable import Quant

struct RestingEnergySampleBucketBuilderTests {
    @Test("An hourly iPhone point represents its complete hour")
    func hourlyPointValue() throws {
        let calendar = utcCalendar
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 23
        )))
        let interval = DateInterval(start: day, duration: 2 * 60 * 60)

        let buckets = RestingEnergySampleBucketBuilder.makeBuckets(
            from: [RestingEnergySampleValue(
                interval: DateInterval(start: day, duration: 0),
                kilocalories: 62
            )],
            within: interval,
            calendar: calendar
        )

        let bucket = try #require(buckets[day])
        #expect(bucket.kilocalories == 62)
        #expect(bucket.coveredDuration == 60 * 60)
    }

    @Test("A sample crossing an hour boundary is split proportionally")
    func splitsIntervalAcrossHours() throws {
        let calendar = utcCalendar
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 23
        )))
        let firstHour = try #require(calendar.date(byAdding: .minute, value: 30, to: day))
        let secondHour = try #require(calendar.date(byAdding: .hour, value: 1, to: day))
        let sample = RestingEnergySampleValue(
            interval: DateInterval(start: firstHour, duration: 60 * 60),
            kilocalories: 60
        )

        let buckets = RestingEnergySampleBucketBuilder.makeBuckets(
            from: [sample],
            within: DateInterval(start: day, duration: 2 * 60 * 60),
            calendar: calendar
        )

        let first = try #require(buckets[day])
        let second = try #require(buckets[secondHour])
        #expect(first.kilocalories == 30)
        #expect(first.coveredDuration == 30 * 60)
        #expect(second.kilocalories == 30)
        #expect(second.coveredDuration == 30 * 60)
    }

    @Test("Overlapping samples do not overstate time coverage")
    func unionsCoverage() throws {
        let calendar = utcCalendar
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 23
        )))
        let secondStart = try #require(calendar.date(byAdding: .minute, value: 15, to: day))
        let samples = [
            RestingEnergySampleValue(
                interval: DateInterval(start: day, duration: 30 * 60),
                kilocalories: 20
            ),
            RestingEnergySampleValue(
                interval: DateInterval(start: secondStart, duration: 30 * 60),
                kilocalories: 20
            ),
        ]

        let buckets = RestingEnergySampleBucketBuilder.makeBuckets(
            from: samples,
            within: DateInterval(start: day, duration: 60 * 60),
            calendar: calendar
        )

        let bucket = try #require(buckets[day])
        #expect(bucket.kilocalories == 40)
        #expect(bucket.coveredDuration == 45 * 60)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
