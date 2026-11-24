import Foundation
import Testing
@testable import Quant

struct RestingEnergyDiagnosticsBuilderTests {
    @Test("Diagnostics always contain total, iPhone, Watch, and discovered sources")
    func buildsRequiredSeries() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 17
        )))
        let end = try #require(calendar.date(byAdding: .day, value: 7, to: start))
        let iPhoneDate = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let watchDate = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let otherDate = try #require(calendar.date(byAdding: .day, value: 3, to: start))

        let snapshot = RestingEnergyDiagnosticsBuilder.makeSnapshot(
            importedDays: [
                RestingEnergyDiagnosticImportedDay(
                    date: start,
                    kilocalories: 1_500,
                    coveredDuration: 24 * 60 * 60,
                    estimatedKilocalories: 400,
                    estimatedDuration: 8 * 60 * 60
                ),
            ],
            importedHours: [
                RestingEnergyDiagnosticImportedHour(
                    date: start,
                    kilocalories: 62,
                    coveredDuration: 60 * 60,
                    estimatedKilocalories: 20,
                    estimatedDuration: 20 * 60
                ),
            ],
            samples: [
                sample(
                    at: iPhoneDate,
                    kilocalories: 60,
                    sourceID: "iphone.local",
                    sourceTitle: "iPhone von Saskia",
                    kind: .iPhone
                ),
                sample(
                    at: watchDate,
                    kilocalories: 70,
                    sourceID: "watch.local",
                    sourceTitle: "Apple Watch",
                    kind: .appleWatch
                ),
                sample(
                    at: otherDate,
                    kilocalories: 55,
                    sourceID: "other.app",
                    sourceTitle: "Andere Energie-App",
                    kind: .other
                ),
            ],
            from: start,
            to: end,
            calendar: calendar
        )

        #expect(snapshot.series.prefix(4).map(\.id) == [
            "total",
            "estimated",
            "category.iphone",
            "category.watch",
        ])
        #expect(snapshot.series.count == 7)
        #expect(snapshot.series.allSatisfy { $0.days.count == 7 })
        #expect(snapshot.series.allSatisfy { $0.hours.count == 168 })

        let total = try #require(snapshot.series.first { $0.id == "total" })
        #expect(total.days[0].kilocalories == 1_500)
        #expect(total.days[1].kilocalories == nil)
        #expect(total.hours[0].kilocalories == 62)
        #expect(total.hours[1].kilocalories == nil)

        let estimated = try #require(snapshot.series.first { $0.id == "estimated" })
        #expect(estimated.role == .estimated)
        #expect(estimated.days[0].kilocalories == 400)
        #expect(estimated.days[0].coveredDuration == Double(8 * 60 * 60))
        #expect(estimated.days[1].kilocalories == nil)
        #expect(estimated.hours[0].kilocalories == 20)
        #expect(estimated.hours[0].coveredDuration == Double(20 * 60))
        #expect(estimated.hours[1].kilocalories == nil)

        let iPhone = try #require(snapshot.series.first { $0.id == "category.iphone" })
        #expect(iPhone.days[1].kilocalories == 60)
        #expect(iPhone.days[1].sampleCount == 1)
        #expect(iPhone.hours[24].kilocalories == 60)
        #expect(iPhone.hours[25].kilocalories == nil)

        let watch = try #require(snapshot.series.first { $0.id == "category.watch" })
        #expect(watch.days[2].kilocalories == 70)

        let source = try #require(snapshot.series.first { $0.id == "source.other.app" })
        #expect(source.title == "Andere Energie-App")
        #expect(source.days[3].kilocalories == 55)
    }

    @Test("The required source categories remain visible without raw samples")
    func keepsEmptyRequiredCategories() throws {
        let calendar = utcCalendar
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 17
        )))
        let end = try #require(calendar.date(byAdding: .day, value: 7, to: start))

        let snapshot = RestingEnergyDiagnosticsBuilder.makeSnapshot(
            importedDays: [],
            importedHours: [],
            samples: [],
            from: start,
            to: end,
            calendar: calendar
        )

        #expect(snapshot.series.map(\.id) == [
            "total",
            "estimated",
            "category.iphone",
            "category.watch",
        ])
        #expect(snapshot.series.allSatisfy { series in
            series.days.allSatisfy { $0.kilocalories == nil }
        })
        #expect(snapshot.series.allSatisfy { series in
            series.hours.count == 168 &&
                series.hours.allSatisfy { $0.kilocalories == nil }
        })
    }

    @Test("Hourly diagnostics follow calendar hours across daylight saving time")
    func followsCalendarHoursAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 23
        )))
        let end = try #require(calendar.date(byAdding: .day, value: 7, to: start))

        let snapshot = RestingEnergyDiagnosticsBuilder.makeSnapshot(
            importedDays: [],
            importedHours: [],
            samples: [],
            from: start,
            to: end,
            calendar: calendar
        )

        #expect(snapshot.series.allSatisfy { $0.days.count == 7 })
        #expect(snapshot.series.allSatisfy { $0.hours.count == 167 })
        #expect(snapshot.series.allSatisfy { series in
            Set(series.hours.map(\.date)).count == series.hours.count
        })
    }

    private func sample(
        at date: Date,
        kilocalories: Double,
        sourceID: String,
        sourceTitle: String,
        kind: RestingEnergyDiagnosticSourceKind
    ) -> RestingEnergyDiagnosticSample {
        RestingEnergyDiagnosticSample(
            interval: DateInterval(start: date, duration: 0),
            kilocalories: kilocalories,
            sourceID: sourceID,
            sourceTitle: sourceTitle,
            sourceDetails: nil,
            sourceKind: kind
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
