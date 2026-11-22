import Foundation

struct RestingEnergyIntervalValue: Sendable, Equatable {
    let interval: DateInterval
    let primaryKilocalories: Double?
    let primaryDuration: TimeInterval
    let iPhoneKilocalories: Double?
    let iPhoneDuration: TimeInterval
}

struct FusedRestingEnergyInterval: Sendable, Equatable {
    let interval: DateInterval
    let kilocalories: Double?
    let coverage: RestingEnergyCoverage
}

enum RestingEnergyFusionBuilder {
    static func fuse(
        _ value: RestingEnergyIntervalValue
    ) -> FusedRestingEnergyInterval {
        let expectedDuration = max(value.interval.duration, 0)
        let primaryKilocalories = validKilocalories(value.primaryKilocalories)
        let primaryDuration = primaryKilocalories == nil
            ? 0
            : clampedDuration(value.primaryDuration, maximum: expectedDuration)
        let missingDuration = max(expectedDuration - primaryDuration, 0)

        let iPhoneKilocalories = validKilocalories(value.iPhoneKilocalories)
        let availableIPhoneDuration = iPhoneKilocalories == nil
            ? 0
            : clampedDuration(value.iPhoneDuration, maximum: expectedDuration)
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
            coverage: RestingEnergyCoverage(
                expectedDuration: expectedDuration,
                primaryDuration: primaryDuration,
                iPhoneFallbackDuration: usedIPhoneDuration
            )
        )
    }

    static func aggregate(
        _ values: [FusedRestingEnergyInterval]
    ) -> (kilocalories: Double?, coverage: RestingEnergyCoverage?) {
        guard !values.isEmpty else { return (nil, nil) }
        let kilocalories = values.compactMap(\.kilocalories)
        let coverage = RestingEnergyCoverage(
            expectedDuration: values.reduce(0) { $0 + $1.coverage.expectedDuration },
            primaryDuration: values.reduce(0) { $0 + $1.coverage.primaryDuration },
            iPhoneFallbackDuration: values.reduce(0) {
                $0 + $1.coverage.iPhoneFallbackDuration
            }
        )
        return (
            kilocalories.isEmpty ? nil : kilocalories.reduce(0, +),
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
}
