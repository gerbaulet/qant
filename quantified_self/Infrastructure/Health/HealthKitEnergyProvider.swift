import Foundation
import HealthKit

struct EnergyExpenditureSnapshot: Sendable, Equatable {
    let daily: [DailyEnergyExpenditure]
    let hourly: [HourlyEnergyExpenditure]
}

@MainActor
protocol HealthEnergyProviding {
    func isHealthDataAvailable() -> Bool
    func requestEnergyAuthorization() async throws
    func energy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> EnergyExpenditureSnapshot
    func earliestAuthorizedEnergyDate() async throws -> Date?
}

@MainActor
protocol HealthWeightProviding {
    func isHealthDataAvailable() -> Bool
    func requestWeightAuthorization() async throws
    func weightMeasurements(from startDate: Date, to endDate: Date) async throws -> [WeightMeasurement]
}

@MainActor
final class HealthKitEnergyProvider: HealthEnergyProviding {
    private enum StatisticsInterval {
        case hour

        var components: DateComponents {
            DateComponents(hour: 1)
        }

        func bucketStart(for date: Date, calendar: Calendar) -> Date {
            calendar.dateInterval(of: .hour, for: date)?.start ?? date
        }
    }

    private let store: HKHealthStore
    private let now: () -> Date

    init(
        store: HKHealthStore = HKHealthStore(),
        now: @escaping () -> Date = { .now }
    ) {
        self.store = store
        self.now = now
    }

    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestEnergyAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: energyTypes)
    }

    func energy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> EnergyExpenditureSnapshot {
        let referenceDate = now()
        let effectiveEndDate = min(endDate, referenceDate)
        guard startDate < effectiveEndDate else {
            return EnergyExpenditureSnapshot(daily: [], hourly: [])
        }
        let pendingHour = endDate >= referenceDate
            ? calendar.dateInterval(of: .hour, for: referenceDate)
            : nil
        let activeType = HKQuantityType(.activeEnergyBurned)

        async let activeByHour = energySums(
            for: activeType,
            from: startDate,
            to: effectiveEndDate,
            calendar: calendar,
            interval: .hour
        )
        async let fusedRestingIntervals = fusedRestingEnergy(
            from: startDate,
            to: effectiveEndDate,
            calendar: calendar,
            pendingHour: pendingHour
        )
        let (active, restingIntervals) = try await (
            activeByHour,
            fusedRestingIntervals
        )

        let restingByHour = Dictionary(grouping: restingIntervals) {
            calendar.dateInterval(of: .hour, for: $0.interval.start)?.start ??
                $0.interval.start
        }
        let restingByDay = Dictionary(grouping: restingIntervals) {
            calendar.startOfDay(for: $0.interval.start)
        }
        let activeByDay = Dictionary(grouping: active.keys) {
            calendar.startOfDay(for: $0)
        }
        .mapValues { hours in
            hours.compactMap { active[$0] }.reduce(0, +)
        }

        let allHours = Set(active.keys).union(restingByHour.keys)
        let hourly = allHours.sorted().map { hour in
            let resting = RestingEnergyFusionBuilder.aggregate(
                restingByHour[hour, default: []]
            )
            return HourlyEnergyExpenditure(
                date: hour,
                activeKilocalories: active[hour],
                restingKilocalories: resting.kilocalories,
                restingEnergyCoverage: resting.coverage
            )
        }

        let allDays = Set(activeByDay.keys).union(restingByDay.keys)
        let daily = allDays.sorted().map { day in
            let resting = RestingEnergyFusionBuilder.aggregate(
                restingByDay[day, default: []]
            )
            return DailyEnergyExpenditure(
                date: day,
                activeKilocalories: activeByDay[day],
                restingKilocalories: resting.kilocalories,
                restingEnergyCoverage: resting.coverage
            )
        }

        return EnergyExpenditureSnapshot(daily: daily, hourly: hourly)
    }

    private func fusedRestingEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar,
        pendingHour: DateInterval?
    ) async throws -> [FusedRestingEnergyInterval] {
        let type = HKQuantityType(.basalEnergyBurned)
        async let primaryCollection = statisticsCollection(
            for: type,
            from: startDate,
            to: endDate,
            calendar: calendar,
            interval: .hour,
            options: [.cumulativeSum, .duration]
        )
        async let iPhoneBuckets = iPhoneRestingEnergyBuckets(
            from: startDate,
            to: endDate,
            calendar: calendar
        )
        let (primary, iPhoneByHour) = try await (primaryCollection, iPhoneBuckets)

        var values: [FusedRestingEnergyInterval] = []
        primary.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
            let intervalStart = max(statistics.startDate, startDate)
            let intervalEnd = min(statistics.endDate, endDate)
            guard intervalStart < intervalEnd else { return }
            let pendingDuration = self.overlapDuration(
                from: intervalStart,
                to: intervalEnd,
                with: pendingHour
            )

            let primaryKilocalories = statistics.sumQuantity()?.doubleValue(
                for: .kilocalorie()
            )
            let primaryDuration = statistics.duration()?.doubleValue(for: .second()) ?? 0
            let bucketStart = calendar.dateInterval(
                of: .hour,
                for: statistics.startDate
            )?.start ?? statistics.startDate
            let iPhoneValue = iPhoneByHour[bucketStart]
            let rawIPhoneKilocalories = iPhoneValue?.kilocalories
            let rawIPhoneDuration = iPhoneValue?.coveredDuration ?? 0
            let iPhoneIsAlreadyPrimary = self.valuesMatch(
                primaryKilocalories,
                rawIPhoneKilocalories
            )
            let bucketDuration = intervalEnd.timeIntervalSince(intervalStart)
            let inferredPrimaryPointCoverageDuration = primaryKilocalories != nil &&
                primaryDuration <= 1
                ? bucketDuration
                : 0

            values.append(RestingEnergyFusionBuilder.fuse(
                RestingEnergyIntervalValue(
                    interval: DateInterval(start: intervalStart, end: intervalEnd),
                    primaryKilocalories: primaryKilocalories,
                    primaryDuration: primaryDuration,
                    iPhoneKilocalories: iPhoneIsAlreadyPrimary ? nil : rawIPhoneKilocalories,
                    iPhoneDuration: iPhoneIsAlreadyPrimary ? 0 : rawIPhoneDuration,
                    pendingDuration: pendingDuration,
                    inferredPrimaryPointCoverageDuration: inferredPrimaryPointCoverageDuration,
                    inferredIPhonePointCoverageDuration: 0
                )
            ))
        }
        return values
    }

    private func overlapDuration(
        from startDate: Date,
        to endDate: Date,
        with interval: DateInterval?
    ) -> TimeInterval {
        guard let interval else { return 0 }
        let overlapStart = max(startDate, interval.start)
        let overlapEnd = min(endDate, interval.end)
        return max(overlapEnd.timeIntervalSince(overlapStart), 0)
    }

    private func iPhoneRestingEnergyBuckets(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> [Date: RestingEnergySampleBucket] {
        let type = HKQuantityType(.basalEnergyBurned)
        let samples = try await quantitySamples(
            for: type,
            from: startDate,
            to: endDate
        )
        let localIdentifier = HKDevice.local().localIdentifier
        let values = samples.compactMap { sample -> RestingEnergySampleValue? in
            let sampleIdentifier = sample.device?.localIdentifier
            guard HealthEnergySourceClassifier.isIPhone(
                productType: sample.sourceRevision.productType,
                deviceName: sample.device?.name,
                deviceModel: sample.device?.model,
                manufacturer: sample.device?.manufacturer,
                sourceName: sample.sourceRevision.source.name,
                sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                isLocalDevice: localIdentifier != nil && sampleIdentifier == localIdentifier
            ) else {
                return nil
            }
            return RestingEnergySampleValue(
                interval: DateInterval(start: sample.startDate, end: sample.endDate),
                kilocalories: sample.quantity.doubleValue(for: .kilocalorie())
            )
        }
        return RestingEnergySampleBucketBuilder.makeBuckets(
            from: values,
            within: DateInterval(start: startDate, end: endDate),
            calendar: calendar
        )
    }

    private func quantitySamples(
        for type: HKQuantityType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples?.compactMap {
                        $0 as? HKQuantitySample
                    } ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func statisticsCollection(
        for type: HKQuantityType,
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar,
        interval: StatisticsInterval,
        options: HKStatisticsOptions
    ) async throws -> HKStatisticsCollection {
        let anchor = calendar.startOfDay(for: startDate)
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: interval.components
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let collection {
                    continuation.resume(returning: collection)
                } else {
                    continuation.resume(throwing: HealthEnergyProviderError.missingStatistics)
                }
            }
            store.execute(query)
        }
    }

    func earliestAuthorizedEnergyDate() async throws -> Date? {
        guard #available(iOS 27.0, *) else {
            return nil
        }

        let dates = try await store.earliestAuthorizedSampleDate(for: energyTypes)
        return dates.values.min()
    }

    private var energyTypes: Set<HKObjectType> {
        [
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
        ]
    }

    private func energySums(
        for type: HKQuantityType,
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar,
        interval: StatisticsInterval
    ) async throws -> [Date: Double] {
        let anchor = calendar.startOfDay(for: startDate)
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: interval.components
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [:])
                    return
                }

                var values: [Date: Double] = [:]
                collection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                    guard let quantity = statistics.sumQuantity() else { return }
                    let bucket = interval.bucketStart(
                        for: statistics.startDate,
                        calendar: calendar
                    )
                    values[bucket] = quantity.doubleValue(
                        for: .kilocalorie()
                    )
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    private func valuesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs - rhs) <= max(abs(lhs) * 0.001, 0.001)
    }
}

private enum HealthEnergyProviderError: Error {
    case missingStatistics
}

@MainActor
final class HealthKitWeightProvider: HealthWeightProviding {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestWeightAuthorization() async throws {
        try await store.requestAuthorization(
            toShare: [],
            read: [HKQuantityType(.bodyMass)]
        )
    }

    func weightMeasurements(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [WeightMeasurement] {
        guard startDate < endDate else { return [] }
        let type = HKQuantityType(.bodyMass)
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: [.strictStartDate]
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let measurements = (samples as? [HKQuantitySample] ?? []).map {
                    WeightMeasurement(
                        id: $0.uuid,
                        date: $0.startDate,
                        kilograms: $0.quantity.doubleValue(for: .gramUnit(with: .kilo))
                    )
                }
                continuation.resume(returning: measurements)
            }
            store.execute(query)
        }
    }
}

@MainActor
protocol HealthAccessPreferenceStoring: AnyObject {
    var hasRequestedEnergyAccess: Bool { get set }
}

@MainActor
protocol HealthWeightPreferenceStoring: AnyObject {
    var hasRequestedWeightAccess: Bool { get set }
    var personalCalibrationEnabled: Bool { get set }
}

@MainActor
final class UserDefaultsHealthAccessPreferenceStore:
    HealthAccessPreferenceStoring,
    HealthWeightPreferenceStoring
{
    private static let energyAccessRequestedKey = "health.energyAccessRequested"
    private static let weightAccessRequestedKey = "health.weightAccessRequested"
    private static let personalCalibrationEnabledKey = "health.personalCalibrationEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasRequestedEnergyAccess: Bool {
        get { defaults.bool(forKey: Self.energyAccessRequestedKey) }
        set { defaults.set(newValue, forKey: Self.energyAccessRequestedKey) }
    }

    var hasRequestedWeightAccess: Bool {
        get { defaults.bool(forKey: Self.weightAccessRequestedKey) }
        set { defaults.set(newValue, forKey: Self.weightAccessRequestedKey) }
    }

    var personalCalibrationEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.personalCalibrationEnabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: Self.personalCalibrationEnabledKey)
        }
        set { defaults.set(newValue, forKey: Self.personalCalibrationEnabledKey) }
    }
}
