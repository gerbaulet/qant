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
        dailyBalanceAdjustmentKilocalories: Double,
        uncappedDailyBalanceAdjustmentKilocalories: Double
    )
}

struct WeightBalanceComparison: Sendable, Equatable {
    let interval: DateInterval
    let dailyWeights: [WeightMeasurement]
    let observedTrend: [WeightChartPoint]
    let observedChangeKilograms: Double?
    let readiness: WeightComparisonReadiness
    let calibrationStatus: PersonalCalibrationStatus

    var dailyBalanceAdjustmentKilocalories: Double? {
        guard case let .ready(adjustment, _) = calibrationStatus else { return nil }
        return adjustment
    }
}
