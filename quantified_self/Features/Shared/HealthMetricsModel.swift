import Foundation
import Observation

@Observable
@MainActor
final class HealthMetricsModel {
    private(set) var energyStatus: HealthDataStatus
    private(set) var energyExpenditures: [DailyEnergyExpenditure] = []
    private(set) var hourlyEnergyExpenditures: [HourlyEnergyExpenditure] = []
    private(set) var weightStatus: HealthDataStatus
    private(set) var weightMeasurements: [WeightMeasurement] = []
    private(set) var dataVersion = 0
    private(set) var isLoadingEnergy = false
    private(set) var isLoadingWeight = false
    private var loadedEnergyInterval: DateInterval?
    private var lastCurrentDayEnergyLoadDate: Date?
    private var loadedWeightInterval: DateInterval?

    var hasRequestedEnergyAccess: Bool {
        preferences.hasRequestedEnergyAccess
    }

    var hasRequestedWeightAccess: Bool {
        weightPreferences.hasRequestedWeightAccess
    }

    var personalCalibrationEnabled: Bool {
        get { weightPreferences.personalCalibrationEnabled }
        set {
            guard weightPreferences.personalCalibrationEnabled != newValue else { return }
            weightPreferences.personalCalibrationEnabled = newValue
            dataVersion += 1
        }
    }

    private let energyProvider: any HealthEnergyProviding
    private let weightProvider: any HealthWeightProviding
    private let preferences: any HealthAccessPreferenceStoring
    private let weightPreferences: any HealthWeightPreferenceStoring
    private let now: () -> Date

    init(
        energyProvider: (any HealthEnergyProviding)? = nil,
        preferences: (any HealthAccessPreferenceStoring)? = nil,
        weightProvider: (any HealthWeightProviding)? = nil,
        weightPreferences: (any HealthWeightPreferenceStoring)? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        let resolvedPreferences = preferences ?? UserDefaultsHealthAccessPreferenceStore()
        let resolvedWeightPreferences = weightPreferences ?? UserDefaultsHealthAccessPreferenceStore()
        self.energyProvider = energyProvider ?? HealthKitEnergyProvider()
        self.weightProvider = weightProvider ?? HealthKitWeightProvider()
        self.preferences = resolvedPreferences
        self.weightPreferences = resolvedWeightPreferences
        self.now = now
        energyStatus = resolvedPreferences.hasRequestedEnergyAccess ? .noData : .notRequested
        weightStatus = resolvedWeightPreferences.hasRequestedWeightAccess ? .noData : .notRequested
    }

    func requestEnergyAccess(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) async {
        guard energyProvider.isHealthDataAvailable() else {
            energyStatus = .unavailable
            return
        }

        energyStatus = .loading
        do {
            try await energyProvider.requestEnergyAuthorization()
            preferences.hasRequestedEnergyAccess = true
            await loadEnergy(
                from: startDate,
                to: endDate,
                calendar: calendar,
                force: true
            )
        } catch {
            energyStatus = .failed
        }
    }

    func loadEnergy(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar,
        force: Bool = false
    ) async {
        guard preferences.hasRequestedEnergyAccess else {
            energyStatus = .notRequested
            return
        }
        guard energyProvider.isHealthDataAvailable() else {
            energyStatus = .unavailable
            return
        }
        guard !isLoadingEnergy else { return }
        let requestedInterval = DateInterval(start: startDate, end: endDate)
        guard let queryInterval = energyQueryInterval(
            for: requestedInterval,
            loadedInterval: loadedEnergyInterval,
            lastCurrentDayLoadDate: lastCurrentDayEnergyLoadDate,
            calendar: calendar,
            force: force
        ) else {
            return
        }

        isLoadingEnergy = true
        if energyExpenditures.isEmpty {
            energyStatus = .loading
        }
        defer { isLoadingEnergy = false }

        do {
            let next = try await energyProvider.energy(
                from: queryInterval.start,
                to: queryInterval.end,
                calendar: calendar
            )
            let loadDate = now()
            merge(
                next.daily,
                replacing: queryInterval,
                calendar: calendar
            )
            mergeHourlyEnergy(next.hourly, replacing: queryInterval)
            if currentDayIntersection(
                with: queryInterval,
                referenceDate: loadDate,
                calendar: calendar
            ) != nil {
                lastCurrentDayEnergyLoadDate = loadDate
            }
            if let loadedEnergyInterval {
                self.loadedEnergyInterval = DateInterval(
                    start: min(loadedEnergyInterval.start, queryInterval.start),
                    end: max(loadedEnergyInterval.end, queryInterval.end)
                )
            } else {
                loadedEnergyInterval = queryInterval
            }
            let earliestDate = try await energyProvider.earliestAuthorizedEnergyDate()
            if let earliestDate {
                energyStatus = .limited(since: earliestDate)
            } else {
                energyStatus = energyExpenditures.contains(where: { $0.totalKilocalories != nil })
                    ? .available
                    : .noData
            }
            dataVersion += 1
        } catch {
            energyStatus = .failed
        }
    }

    func expenditure(for date: Date, calendar: Calendar) -> DailyEnergyExpenditure? {
        let day = calendar.startOfDay(for: date)
        return energyExpenditures.first {
            calendar.startOfDay(for: $0.date) == day
        }
    }

    func expenditures(within interval: DateInterval) -> [DailyEnergyExpenditure] {
        energyExpenditures.filter {
            $0.date >= interval.start && $0.date < interval.end
        }
    }

    func hourlyExpenditures(within interval: DateInterval) -> [HourlyEnergyExpenditure] {
        hourlyEnergyExpenditures.filter {
            $0.date >= interval.start && $0.date < interval.end
        }
    }

    func requestWeightAccess(from startDate: Date, to endDate: Date) async {
        guard weightProvider.isHealthDataAvailable() else {
            weightStatus = .unavailable
            return
        }

        weightStatus = .loading
        do {
            try await weightProvider.requestWeightAuthorization()
            weightPreferences.hasRequestedWeightAccess = true
            await loadWeights(from: startDate, to: endDate, force: true)
        } catch {
            weightStatus = .failed
        }
    }

    func loadWeights(
        from startDate: Date,
        to endDate: Date,
        force: Bool = false
    ) async {
        guard weightPreferences.hasRequestedWeightAccess else {
            weightStatus = .notRequested
            return
        }
        guard weightProvider.isHealthDataAvailable() else {
            weightStatus = .unavailable
            return
        }
        guard !isLoadingWeight else { return }
        if !force,
           let loadedWeightInterval,
           loadedWeightInterval.start <= startDate,
           loadedWeightInterval.end >= endDate {
            return
        }

        isLoadingWeight = true
        if weightMeasurements.isEmpty {
            weightStatus = .loading
        }
        defer { isLoadingWeight = false }

        do {
            let next = try await weightProvider.weightMeasurements(
                from: startDate,
                to: endDate
            )
            mergeWeights(next, replacing: DateInterval(start: startDate, end: endDate))
            if let loadedWeightInterval {
                self.loadedWeightInterval = DateInterval(
                    start: min(loadedWeightInterval.start, startDate),
                    end: max(loadedWeightInterval.end, endDate)
                )
            } else {
                loadedWeightInterval = DateInterval(start: startDate, end: endDate)
            }
            weightStatus = weightMeasurements.isEmpty ? .noData : .available
            dataVersion += 1
        } catch {
            weightStatus = .failed
        }
    }

    func weights(within interval: DateInterval) -> [WeightMeasurement] {
        weightMeasurements.filter {
            $0.date >= interval.start && $0.date < interval.end
        }
    }

    private func energyQueryInterval(
        for requestedInterval: DateInterval,
        loadedInterval: DateInterval?,
        lastCurrentDayLoadDate: Date?,
        calendar: Calendar,
        force: Bool
    ) -> DateInterval? {
        guard !force, let loadedInterval else {
            return requestedInterval
        }
        guard loadedInterval.start <= requestedInterval.start,
              loadedInterval.end >= requestedInterval.end else {
            return requestedInterval
        }

        let referenceDate = now()
        guard let currentDayInterval = currentDayIntersection(
            with: requestedInterval,
            referenceDate: referenceDate,
            calendar: calendar
        ) else { return nil }
        guard let lastCurrentDayLoadDate,
              let currentHour = calendar.dateInterval(of: .hour, for: referenceDate)?.start,
              let loadedHour = calendar.dateInterval(
                of: .hour,
                for: lastCurrentDayLoadDate
              )?.start else {
            return currentDayInterval
        }
        return loadedHour == currentHour ? nil : currentDayInterval
    }

    private func currentDayIntersection(
        with interval: DateInterval,
        referenceDate: Date,
        calendar: Calendar
    ) -> DateInterval? {
        guard let currentDay = calendar.dateInterval(of: .day, for: referenceDate) else {
            return nil
        }
        let start = max(interval.start, currentDay.start)
        let end = min(interval.end, currentDay.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func merge(
        _ next: [DailyEnergyExpenditure],
        replacing interval: DateInterval,
        calendar: Calendar
    ) {
        var byDay = Dictionary(
            energyExpenditures
                .filter { !interval.contains($0.date) }
                .map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        for expenditure in next {
            byDay[calendar.startOfDay(for: expenditure.date)] = expenditure
        }
        energyExpenditures = byDay.values.sorted { $0.date < $1.date }
    }

    private func mergeHourlyEnergy(
        _ next: [HourlyEnergyExpenditure],
        replacing interval: DateInterval
    ) {
        var byHour = Dictionary(
            hourlyEnergyExpenditures
                .filter { !interval.contains($0.date) }
                .map { ($0.date, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        for expenditure in next {
            byHour[expenditure.date] = expenditure
        }
        hourlyEnergyExpenditures = byHour.values.sorted { $0.date < $1.date }
    }

    private func mergeWeights(
        _ next: [WeightMeasurement],
        replacing interval: DateInterval
    ) {
        let retained = weightMeasurements.filter { !interval.contains($0.date) }
        weightMeasurements = (retained + next).sorted { $0.date < $1.date }
    }
}
