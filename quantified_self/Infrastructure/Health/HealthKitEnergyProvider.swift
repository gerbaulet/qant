import Foundation
import HealthKit

@MainActor
protocol HealthEnergyProviding {
    func isHealthDataAvailable() -> Bool
    func requestEnergyAuthorization() async throws
    func dailyEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> [DailyEnergyExpenditure]
    func hourlyEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> [HourlyEnergyExpenditure]
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
        case day
        case hour

        var components: DateComponents {
            switch self {
            case .day: DateComponents(day: 1)
            case .hour: DateComponents(hour: 1)
            }
        }

        func bucketStart(for date: Date, calendar: Calendar) -> Date {
            switch self {
            case .day:
                calendar.startOfDay(for: date)
            case .hour:
                calendar.dateInterval(of: .hour, for: date)?.start ?? date
            }
        }
    }

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestEnergyAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: energyTypes)
    }

    func dailyEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> [DailyEnergyExpenditure] {
        guard startDate < endDate else { return [] }
        let activeType = HKQuantityType(.activeEnergyBurned)
        let restingType = HKQuantityType(.basalEnergyBurned)

        async let active = energySums(
            for: activeType,
            from: startDate,
            to: endDate,
            calendar: calendar,
            interval: .day
        )
        async let resting = energySums(
            for: restingType,
            from: startDate,
            to: endDate,
            calendar: calendar,
            interval: .day
        )
        let (activeByDay, restingByDay) = try await (active, resting)
        let allDays = Set(activeByDay.keys).union(restingByDay.keys)

        return allDays.sorted().map { day in
            DailyEnergyExpenditure(
                date: day,
                activeKilocalories: activeByDay[day],
                restingKilocalories: restingByDay[day]
            )
        }
    }

    func hourlyEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async throws -> [HourlyEnergyExpenditure] {
        guard startDate < endDate else { return [] }
        let activeType = HKQuantityType(.activeEnergyBurned)
        let restingType = HKQuantityType(.basalEnergyBurned)

        async let active = energySums(
            for: activeType,
            from: startDate,
            to: endDate,
            calendar: calendar,
            interval: .hour
        )
        async let resting = energySums(
            for: restingType,
            from: startDate,
            to: endDate,
            calendar: calendar,
            interval: .hour
        )
        let (activeByHour, restingByHour) = try await (active, resting)
        let allHours = Set(activeByHour.keys).union(restingByHour.keys)

        return allHours.sorted().map { hour in
            HourlyEnergyExpenditure(
                date: hour,
                activeKilocalories: activeByHour[hour],
                restingKilocalories: restingByHour[hour]
            )
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
            options: [.strictStartDate]
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
