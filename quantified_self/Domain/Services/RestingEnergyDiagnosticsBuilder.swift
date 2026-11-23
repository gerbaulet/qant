import Foundation

enum RestingEnergyDiagnosticsBuilder {
    static func makeSnapshot(
        importedDays: [RestingEnergyDiagnosticImportedDay],
        samples: [RestingEnergyDiagnosticSample],
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) -> RestingEnergyDiagnosticsSnapshot {
        let interval = DateInterval(start: startDate, end: max(endDate, startDate))
        let dayStarts = diagnosticDayStarts(
            from: startDate,
            to: endDate,
            calendar: calendar
        )
        let importedByDay = Dictionary(
            importedDays.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        let total = RestingEnergyDiagnosticSeries(
            id: "total",
            title: "Quant-Import (Gesamt)",
            details: "HealthKit-priorisiert, anschließend mit iPhone-Lücken ergänzt",
            role: .importedTotal,
            days: dayStarts.map { day in
                let imported = importedByDay[day]
                return RestingEnergyDiagnosticDay(
                    date: day,
                    kilocalories: imported?.kilocalories,
                    coveredDuration: imported?.coveredDuration,
                    sampleCount: nil
                )
            }
        )
        let iPhone = makeRawSeries(
            id: "category.iphone",
            title: "iPhone",
            details: "Alle als iPhone erkannten Ruheenergie-Samples",
            role: .iPhoneCategory,
            samples: samples.filter { $0.sourceKind == .iPhone },
            interval: interval,
            dayStarts: dayStarts,
            calendar: calendar
        )
        let watch = makeRawSeries(
            id: "category.watch",
            title: "Apple Watch",
            details: "Alle als Apple Watch erkannten Ruheenergie-Samples",
            role: .appleWatchCategory,
            samples: samples.filter { $0.sourceKind == .appleWatch },
            interval: interval,
            dayStarts: dayStarts,
            calendar: calendar
        )
        let sources = Dictionary(grouping: samples, by: \.sourceID)
            .compactMap { sourceID, sourceSamples -> RestingEnergyDiagnosticSeries? in
                guard let descriptor = sourceSamples.first else { return nil }
                return makeRawSeries(
                    id: "source.\(sourceID)",
                    title: descriptor.sourceTitle,
                    details: descriptor.sourceDetails,
                    role: .individualSource,
                    samples: sourceSamples,
                    interval: interval,
                    dayStarts: dayStarts,
                    calendar: calendar
                )
            }
            .sorted {
                let titleOrder = $0.title.localizedStandardCompare($1.title)
                return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
            }

        return RestingEnergyDiagnosticsSnapshot(
            interval: interval,
            series: [total, iPhone, watch] + sources
        )
    }

    private static func makeRawSeries(
        id: String,
        title: String,
        details: String?,
        role: RestingEnergyDiagnosticSeriesRole,
        samples: [RestingEnergyDiagnosticSample],
        interval: DateInterval,
        dayStarts: [Date],
        calendar: Calendar
    ) -> RestingEnergyDiagnosticSeries {
        let buckets = RestingEnergySampleBucketBuilder.makeBuckets(
            from: samples.map {
                RestingEnergySampleValue(
                    interval: $0.interval,
                    kilocalories: $0.kilocalories
                )
            },
            within: interval,
            calendar: calendar
        )
        let bucketsByDay = Dictionary(grouping: buckets.values) {
            calendar.startOfDay(for: $0.interval.start)
        }

        return RestingEnergyDiagnosticSeries(
            id: id,
            title: title,
            details: details,
            role: role,
            days: dayStarts.map { day in
                let dailyBuckets = bucketsByDay[day, default: []]
                let hasValue = !dailyBuckets.isEmpty
                let dayInterval = calendar.dateInterval(of: .day, for: day)
                return RestingEnergyDiagnosticDay(
                    date: day,
                    kilocalories: hasValue
                        ? dailyBuckets.reduce(0) { $0 + $1.kilocalories }
                        : nil,
                    coveredDuration: hasValue
                        ? dailyBuckets.reduce(0) { $0 + $1.coveredDuration }
                        : nil,
                    sampleCount: dayInterval.map { interval in
                        samples.filter { sampleContributes($0, to: interval) }.count
                    } ?? 0
                )
            }
        )
    }

    private static func diagnosticDayStarts(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) -> [Date] {
        guard startDate < endDate else { return [] }
        let first = calendar.startOfDay(for: startDate)
        let lastReference = endDate.addingTimeInterval(-0.001)
        let last = calendar.startOfDay(for: max(lastReference, startDate))
        var days: [Date] = []
        var current = first

        while current <= last {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current),
                  next > current else {
                break
            }
            current = next
        }
        return days
    }

    private static func sampleContributes(
        _ sample: RestingEnergyDiagnosticSample,
        to interval: DateInterval
    ) -> Bool {
        if sample.interval.duration <= 1 {
            return sample.interval.start >= interval.start && sample.interval.start < interval.end
        }
        return (sample.interval.intersection(with: interval)?.duration ?? 0) > 0
    }
}
