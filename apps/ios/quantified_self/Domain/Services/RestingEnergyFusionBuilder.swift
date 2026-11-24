import Foundation

struct RestingEnergyIntervalValue: Sendable, Equatable {
    let interval: DateInterval
    let primaryKilocalories: Double?
    let primaryDuration: TimeInterval
    let iPhoneKilocalories: Double?
    let iPhoneDuration: TimeInterval
    let pendingDuration: TimeInterval
    let inferredPrimaryPointCoverageDuration: TimeInterval
    let inferredIPhonePointCoverageDuration: TimeInterval

    init(
        interval: DateInterval,
        primaryKilocalories: Double?,
        primaryDuration: TimeInterval,
        iPhoneKilocalories: Double?,
        iPhoneDuration: TimeInterval,
        pendingDuration: TimeInterval = 0,
        inferredPrimaryPointCoverageDuration: TimeInterval = 0,
        inferredIPhonePointCoverageDuration: TimeInterval = 0
    ) {
        self.interval = interval
        self.primaryKilocalories = primaryKilocalories
        self.primaryDuration = primaryDuration
        self.iPhoneKilocalories = iPhoneKilocalories
        self.iPhoneDuration = iPhoneDuration
        self.pendingDuration = pendingDuration
        self.inferredPrimaryPointCoverageDuration = inferredPrimaryPointCoverageDuration
        self.inferredIPhonePointCoverageDuration = inferredIPhonePointCoverageDuration
    }
}

struct FusedRestingEnergyInterval: Sendable, Equatable {
    let interval: DateInterval
    let kilocalories: Double?
    let estimatedKilocalories: Double
    let coverage: RestingEnergyCoverage

    init(
        interval: DateInterval,
        kilocalories: Double?,
        estimatedKilocalories: Double = 0,
        coverage: RestingEnergyCoverage
    ) {
        self.interval = interval
        self.kilocalories = kilocalories
        self.estimatedKilocalories = estimatedKilocalories
        self.coverage = coverage
    }
}

enum RestingEnergyFusionBuilder {
    static func fuse(
        _ value: RestingEnergyIntervalValue
    ) -> FusedRestingEnergyInterval {
        let expectedDuration = max(value.interval.duration, 0)
        let primaryKilocalories = validKilocalories(value.primaryKilocalories)
        let primaryDuration = primaryKilocalories == nil
            ? 0
            : effectiveDuration(
                reported: value.primaryDuration,
                inferredForPoint: value.inferredPrimaryPointCoverageDuration,
                maximum: expectedDuration
            )
        let missingDuration = max(expectedDuration - primaryDuration, 0)

        let iPhoneKilocalories = validKilocalories(value.iPhoneKilocalories)
        let availableIPhoneDuration = iPhoneKilocalories == nil
            ? 0
            : effectiveDuration(
                reported: value.iPhoneDuration,
                inferredForPoint: value.inferredIPhonePointCoverageDuration,
                maximum: expectedDuration
            )
        // Without primary duration metadata, overlap cannot be determined safely.
        // Keep the primary value, but do not add a potentially duplicate fallback.
        let canFillFromIPhone = primaryKilocalories == nil || primaryDuration > 0
        let usedIPhoneDuration = canFillFromIPhone
            ? min(missingDuration, availableIPhoneDuration)
            : 0
        let iPhoneContribution: Double?
        if let iPhoneKilocalories, availableIPhoneDuration > 0, usedIPhoneDuration > 0 {
            iPhoneContribution = iPhoneKilocalories / availableIPhoneDuration * usedIPhoneDuration
        } else {
            iPhoneContribution = nil
        }

        let kilocalories: Double?
        switch (primaryKilocalories, iPhoneContribution) {
        case let (.some(primary), .some(fallback)):
            kilocalories = primary + fallback
        case let (.some(primary), .none):
            kilocalories = primary
        case let (.none, .some(fallback)):
            kilocalories = fallback
        case (.none, .none):
            // Preserve a valid point value, but do not claim that it covers time.
            kilocalories = iPhoneKilocalories
        }

        return FusedRestingEnergyInterval(
            interval: value.interval,
            kilocalories: kilocalories,
            estimatedKilocalories: 0,
            coverage: RestingEnergyCoverage(
                expectedDuration: expectedDuration,
                primaryDuration: primaryDuration,
                iPhoneFallbackDuration: usedIPhoneDuration,
                pendingDuration: min(max(value.pendingDuration, 0), expectedDuration)
            )
        )
    }

    static func aggregate(
        _ values: [FusedRestingEnergyInterval]
    ) -> (
        kilocalories: Double?,
        estimatedKilocalories: Double,
        coverage: RestingEnergyCoverage?
    ) {
        guard !values.isEmpty else { return (nil, 0, nil) }
        let kilocalories = values.compactMap(\.kilocalories)
        let coverage = RestingEnergyCoverage(
            expectedDuration: values.reduce(0) { $0 + $1.coverage.expectedDuration },
            primaryDuration: values.reduce(0) { $0 + $1.coverage.primaryDuration },
            iPhoneFallbackDuration: values.reduce(0) {
                $0 + $1.coverage.iPhoneFallbackDuration
            },
            estimatedDuration: values.reduce(0) {
                $0 + $1.coverage.estimatedDuration
            },
            pendingDuration: values.reduce(0) {
                $0 + $1.coverage.pendingDuration
            },
            hasExcessiveGap: values.contains { $0.coverage.hasExcessiveGap }
        )
        return (
            kilocalories.isEmpty ? nil : kilocalories.reduce(0, +),
            values.reduce(0) { $0 + $1.estimatedKilocalories },
            coverage
        )
    }

    private static func validKilocalories(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func clampedDuration(
        _ duration: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard duration.isFinite else { return 0 }
        return min(max(duration, 0), maximum)
    }

    private static func effectiveDuration(
        reported duration: TimeInterval,
        inferredForPoint inferredDuration: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let reportedDuration = clampedDuration(duration, maximum: maximum)
        guard reportedDuration <= 1 else { return reportedDuration }
        return clampedDuration(inferredDuration, maximum: maximum)
    }
}
