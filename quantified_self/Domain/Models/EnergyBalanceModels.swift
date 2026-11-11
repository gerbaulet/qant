import Foundation

struct DailyEnergyExpenditure: Identifiable, Sendable, Equatable {
    let date: Date
    let activeKilocalories: Double?
    let restingKilocalories: Double?

    var id: Date { date }

    var totalKilocalories: Double? {
        guard let activeKilocalories, let restingKilocalories else { return nil }
        return activeKilocalories + restingKilocalories
    }
}

enum EnergyBalanceCompleteness: Sendable, Equatable {
    case complete
    case provisionalIntake
    case missingIntake
    case missingActiveEnergy
    case missingRestingEnergy

    var isEvaluable: Bool {
        self == .complete
    }
}

struct DailyEnergyBalance: Identifiable, Sendable, Equatable {
    let date: Date
    let intakeKilocalories: Double?
    let activeKilocalories: Double?
    let restingKilocalories: Double?
    let completeness: EnergyBalanceCompleteness
    let isCurrentDay: Bool

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
