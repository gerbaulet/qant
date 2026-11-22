import Foundation

struct TodayEnergyChartScale: Equatable, Sendable {
    let domain: ClosedRange<Double>
    let axisValues: [Double]
}

enum TodayEnergyChartScaleBuilder {
    private static let maximumAxisIntervals = 5
    private static let minimumStep = 100.0
    private static let stepFactors = [1.0, 1.25, 1.5, 2.0, 2.5, 5.0]

    static func makeScale(
        for trend: TodayEnergyTrend,
        includesAverageIntake: Bool
    ) -> TodayEnergyChartScale {
        var values = [
            trend.intakeActualPoints.map(\.value),
            trend.intakeForecastPoints.map(\.value),
            trend.expenditureActualPoints.map { -$0.value },
            trend.expenditureForecastPoints.map { -$0.value },
            trend.balanceActualPoints.map(\.value),
            trend.balanceForecastPoints.map(\.value),
        ].flatMap { $0 }

        if includesAverageIntake {
            values.append(contentsOf: trend.averageIntakePoints.map(\.value))
        }
        values = values.filter(\.isFinite)

        guard let dataMinimum = values.min(),
              let dataMaximum = values.max() else {
            return fallbackScale
        }
        let minimum = min(dataMinimum, 0)
        let maximum = max(dataMaximum, 0)
        let span = maximum - minimum
        guard span > 0 else { return fallbackScale }

        let candidates = candidateSteps(for: span).compactMap { step -> ScaleCandidate? in
            let lowerIndex = Int(floor(minimum / step))
            let upperIndex = Int(ceil(maximum / step))
            let intervalCount = upperIndex - lowerIndex
            guard intervalCount > 0, intervalCount <= maximumAxisIntervals else { return nil }
            return ScaleCandidate(
                step: step,
                lowerIndex: lowerIndex,
                upperIndex: upperIndex,
                unusedRange: Double(intervalCount) * step - span
            )
        }
        guard let candidate = candidates.min(by: { lhs, rhs in
            if abs(lhs.unusedRange - rhs.unusedRange) > 0.001 {
                return lhs.unusedRange < rhs.unusedRange
            }
            return lhs.step < rhs.step
        }) else {
            return fallbackScale
        }

        let axisValues = (candidate.lowerIndex...candidate.upperIndex).map { index in
            normalized(Double(index) * candidate.step)
        }
        guard let lowerBound = axisValues.first,
              let upperBound = axisValues.last else {
            return fallbackScale
        }
        return TodayEnergyChartScale(
            domain: lowerBound...upperBound,
            axisValues: axisValues
        )
    }

    private static var fallbackScale: TodayEnergyChartScale {
        TodayEnergyChartScale(
            domain: -500...500,
            axisValues: [-500, -250, 0, 250, 500]
        )
    }

    private static func candidateSteps(for span: Double) -> [Double] {
        let targetStep = max(span / Double(maximumAxisIntervals), minimumStep)
        let baseExponent = floor(log10(targetStep))
        return (0...3).flatMap { exponentOffset in
            let magnitude = pow(10, baseExponent + Double(exponentOffset))
            return stepFactors.map { $0 * magnitude }
        }
        .filter { $0 >= minimumStep }
    }

    private static func normalized(_ value: Double) -> Double {
        abs(value) < 0.001 ? 0 : value
    }

    private struct ScaleCandidate {
        let step: Double
        let lowerIndex: Int
        let upperIndex: Int
        let unusedRange: Double
    }
}
