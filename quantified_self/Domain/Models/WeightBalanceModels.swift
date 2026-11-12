import Foundation

struct WeightMeasurement: Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    let kilograms: Double

    init(id: UUID = UUID(), date: Date, kilograms: Double) {
        self.id = id
        self.date = date
        self.kilograms = kilograms
    }
}

struct WeightChartPoint: Identifiable, Sendable, Equatable {
    let date: Date
    let kilograms: Double

    var id: Date { date }
}

enum WeightComparisonReadiness: Sendable, Equatable {
    case ready
    case needsWeights(current: Int, required: Int, spanDays: Int, requiredSpanDays: Int)
    case needsBalanceDays(current: Int, required: Int)
}

enum PersonalCalibrationStatus: Sendable, Equatable {
    case disabled
    case collecting(
        weightCount: Int,
        requiredWeightCount: Int,
        balanceDayCount: Int,
        requiredBalanceDayCount: Int,
        spanDays: Int,
        requiredSpanDays: Int
    )
    case unavailable(reason: String)
    case ready(
        factor: Double,
        dailyBalanceAdjustmentKilocalories: Double
    )
}

struct WeightBalanceComparison: Sendable, Equatable {
    let interval: DateInterval
    let dailyWeights: [WeightMeasurement]
    let observedTrend: [WeightChartPoint]
    let expectedTrend: [WeightChartPoint]
    let observedChangeKilograms: Double?
    let expectedChangeKilograms: Double?
    let evaluableBalanceDayCount: Int
    let readiness: WeightComparisonReadiness
    let calibrationStatus: PersonalCalibrationStatus

    var usesPersonalCalibration: Bool {
        if case .ready = calibrationStatus { return true }
        return false
    }

    var dailyBalanceAdjustmentKilocalories: Double? {
        guard case let .ready(_, adjustment) = calibrationStatus else { return nil }
        return adjustment
    }
}
