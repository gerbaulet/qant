import Foundation

struct RestingEnergyCoverage: Sendable, Equatable {
    static let maximumToleratedMissingDuration: TimeInterval = 15 * 60

    let expectedDuration: TimeInterval
    let primaryDuration: TimeInterval
    let iPhoneFallbackDuration: TimeInterval
    let pendingDuration: TimeInterval

    init(
        expectedDuration: TimeInterval,
        primaryDuration: TimeInterval,
        iPhoneFallbackDuration: TimeInterval,
        pendingDuration: TimeInterval = 0
    ) {
        self.expectedDuration = expectedDuration
        self.primaryDuration = primaryDuration
        self.iPhoneFallbackDuration = iPhoneFallbackDuration
        self.pendingDuration = pendingDuration
    }

    var coveredDuration: TimeInterval {
        min(max(primaryDuration + iPhoneFallbackDuration, 0), expectedDuration)
    }

    var missingDuration: TimeInterval {
        max(expectedDuration - coveredDuration, 0)
    }

    private var unresolvedMissingDuration: TimeInterval {
        max(missingDuration - min(max(pendingDuration, 0), expectedDuration), 0)
    }

    var isComplete: Bool {
        let proportionalTolerance = expectedDuration * 0.02
        let toleratedMissingDuration = min(
            Self.maximumToleratedMissingDuration,
            proportionalTolerance
        )
        return expectedDuration > 0 && coveredDuration > 0 &&
            unresolvedMissingDuration <= toleratedMissingDuration
    }

    var usesIPhoneFallback: Bool {
        iPhoneFallbackDuration > 0
    }
}

struct DailyEnergyExpenditure: Identifiable, Sendable, Equatable {
    let date: Date
    let activeKilocalories: Double?
    let restingKilocalories: Double?
    let restingEnergyCoverage: RestingEnergyCoverage?

    init(
        date: Date,
        activeKilocalories: Double?,
        restingKilocalories: Double?,
        restingEnergyCoverage: RestingEnergyCoverage? = nil
    ) {
        self.date = date
        self.activeKilocalories = activeKilocalories
        self.restingKilocalories = restingKilocalories
        self.restingEnergyCoverage = restingEnergyCoverage
    }

    var id: Date { date }

    var totalKilocalories: Double? {
        guard let activeKilocalories, let restingKilocalories else { return nil }
        return activeKilocalories + restingKilocalories
    }
}

struct HourlyEnergyExpenditure: Identifiable, Sendable, Equatable {
    let date: Date
    let activeKilocalories: Double?
    let restingKilocalories: Double?
    let restingEnergyCoverage: RestingEnergyCoverage?

    init(
        date: Date,
        activeKilocalories: Double?,
        restingKilocalories: Double?,
        restingEnergyCoverage: RestingEnergyCoverage? = nil
    ) {
        self.date = date
        self.activeKilocalories = activeKilocalories
        self.restingKilocalories = restingKilocalories
        self.restingEnergyCoverage = restingEnergyCoverage
    }

    var id: Date { date }
}

enum EnergyExpenditureForecastMethod: Sendable, Equatable {
    case historicalRemainder
    case dailyMedian
}

struct EnergyExpenditureForecast: Sendable, Equatable {
    let activeKilocalories: Double
    let restingKilocalories: Double
    let historicalDayCount: Int
    let method: EnergyExpenditureForecastMethod

    var totalKilocalories: Double {
        activeKilocalories + restingKilocalories
    }
}

enum EnergyBalanceCompleteness: Sendable, Equatable {
    case complete
    case provisionalIntake
    case missingIntake
    case missingActiveEnergy
    case missingRestingEnergy
    case incompleteRestingEnergy

    var isEvaluable: Bool {
        self == .complete
    }
}

struct DailyEnergyBalance: Identifiable, Sendable, Equatable {
    let date: Date
    let intakeKilocalories: Double?
    let activeKilocalories: Double?
    let restingKilocalories: Double?
    let restingEnergyCoverage: RestingEnergyCoverage?
    let completeness: EnergyBalanceCompleteness
    let isCurrentDay: Bool

    init(
        date: Date,
        intakeKilocalories: Double?,
        activeKilocalories: Double?,
        restingKilocalories: Double?,
        restingEnergyCoverage: RestingEnergyCoverage? = nil,
        completeness: EnergyBalanceCompleteness,
        isCurrentDay: Bool
    ) {
        self.date = date
        self.intakeKilocalories = intakeKilocalories
        self.activeKilocalories = activeKilocalories
        self.restingKilocalories = restingKilocalories
        self.restingEnergyCoverage = restingEnergyCoverage
        self.completeness = completeness
        self.isCurrentDay = isCurrentDay
    }

    var id: Date { date }

    var expenditureKilocalories: Double? {
        guard let activeKilocalories, let restingKilocalories else { return nil }
        return activeKilocalories + restingKilocalories
    }

    /// Positive values are a surplus; negative values are a deficit.
    var balanceKilocalories: Double? {
        guard let intakeKilocalories, let expenditureKilocalories else { return nil }
        return intakeKilocalories - expenditureKilocalories
    }

    var canDescribeBalance: Bool {
        balanceKilocalories != nil && completeness != .missingIntake
    }
}

enum HealthDataStatus: Sendable, Equatable {
    case notRequested
    case loading
    case available
    case limited(since: Date)
    case noData
    case unavailable
    case failed
}
