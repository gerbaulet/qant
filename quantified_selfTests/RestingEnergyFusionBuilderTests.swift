import Foundation
import Testing
@testable import Quant

struct RestingEnergyFusionBuilderTests {
    @Test("The Health value wins when it covers the complete interval")
    func primaryValueWins() throws {
        let interval = DateInterval(start: .now, duration: 300)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: 5,
            primaryDuration: 300,
            iPhoneKilocalories: 6,
            iPhoneDuration: 300
        ))

        #expect(fused.kilocalories == 5)
        #expect(fused.coverage.primaryDuration == 300)
        #expect(fused.coverage.iPhoneFallbackDuration == 0)
        #expect(fused.coverage.isComplete)
    }

    @Test("Complete Watch coverage is never replaced or duplicated by iPhone energy")
    func watchCoverageHasPriority() {
        let interval = DateInterval(start: .now, duration: 3_600)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: 70,
            primaryDuration: 3_600,
            iPhoneKilocalories: 72,
            iPhoneDuration: 3_600
        ))

        #expect(fused.kilocalories == 70)
        #expect(fused.coverage.primaryDuration == 3_600)
        #expect(fused.coverage.iPhoneFallbackDuration == 0)
    }

    @Test("An hourly Watch point keeps priority over the iPhone fallback")
    func watchPointCoverageHasPriority() {
        let interval = DateInterval(start: .now, duration: 3_600)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: 70,
            primaryDuration: 0,
            iPhoneKilocalories: 72,
            iPhoneDuration: 3_600,
            inferredPrimaryPointCoverageDuration: 3_600
        ))

        #expect(fused.kilocalories == 70)
        #expect(fused.coverage.primaryDuration == 3_600)
        #expect(fused.coverage.iPhoneFallbackDuration == 0)
        #expect(fused.coverage.isComplete)
    }

    @Test("The iPhone fills only the duration missing from the primary value")
    func fillsPartialGapWithoutDoubleCounting() throws {
        let interval = DateInterval(start: .now, duration: 300)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: 3,
            primaryDuration: 180,
            iPhoneKilocalories: 5,
            iPhoneDuration: 300
        ))

        #expect(fused.kilocalories == 5)
        #expect(fused.coverage.primaryDuration == 180)
        #expect(fused.coverage.iPhoneFallbackDuration == 120)
        #expect(fused.coverage.isComplete)
    }

    @Test("An hourly iPhone interval can cover a complete hour")
    func acceptsHourlyIPhoneIntervals() throws {
        let interval = DateInterval(start: .now, duration: 3_600)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: nil,
            primaryDuration: 0,
            iPhoneKilocalories: 72,
            iPhoneDuration: 3_600
        ))

        #expect(fused.kilocalories == 72)
        #expect(fused.coverage.iPhoneFallbackDuration == 3_600)
        #expect(fused.coverage.isComplete)
    }

    @Test("Point values remain visible without claiming time coverage")
    func preservesPointValueConservatively() throws {
        let interval = DateInterval(start: .now, duration: 300)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: nil,
            primaryDuration: 0,
            iPhoneKilocalories: 5,
            iPhoneDuration: 0
        ))

        #expect(fused.kilocalories == 5)
        #expect(fused.coverage.coveredDuration == 0)
        #expect(!fused.coverage.isComplete)
    }

    @Test("An hourly Health point value can cover its statistics bucket")
    func infersCoverageForHourlyPointValue() {
        let interval = DateInterval(start: .now, duration: 3_600)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: nil,
            primaryDuration: 0,
            iPhoneKilocalories: 72,
            iPhoneDuration: 0,
            inferredIPhonePointCoverageDuration: 3_600
        ))

        #expect(fused.kilocalories == 72)
        #expect(fused.coverage.iPhoneFallbackDuration == 3_600)
        #expect(fused.coverage.isComplete)
    }

    @Test("A primary point known to be the iPhone value can cover the hour")
    func infersCoverageForPrimaryIPhonePointValue() {
        let interval = DateInterval(start: .now, duration: 3_600)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: 72,
            primaryDuration: 0,
            iPhoneKilocalories: nil,
            iPhoneDuration: 0,
            inferredPrimaryPointCoverageDuration: 3_600
        ))

        #expect(fused.kilocalories == 72)
        #expect(fused.coverage.primaryDuration == 3_600)
        #expect(fused.coverage.isComplete)
    }

    @Test("Unknown primary duration never causes a duplicate iPhone addition")
    func avoidsFallbackWhenPrimaryDurationIsUnknown() {
        let interval = DateInterval(start: .now, duration: 3_600)

        let fused = RestingEnergyFusionBuilder.fuse(RestingEnergyIntervalValue(
            interval: interval,
            primaryKilocalories: 70,
            primaryDuration: 0,
            iPhoneKilocalories: 72,
            iPhoneDuration: 3_600
        ))

        #expect(fused.kilocalories == 70)
        #expect(fused.coverage.iPhoneFallbackDuration == 0)
        #expect(!fused.coverage.isComplete)
    }

    @Test("Coverage completeness has an explicit fifteen minute boundary")
    func completenessBoundary() {
        let complete = RestingEnergyCoverage(
            expectedDuration: 86_400,
            primaryDuration: 85_500,
            iPhoneFallbackDuration: 0
        )
        let incomplete = RestingEnergyCoverage(
            expectedDuration: 86_400,
            primaryDuration: 85_499,
            iPhoneFallbackDuration: 0
        )

        #expect(complete.isComplete)
        #expect(!incomplete.isComplete)
    }

    @Test("An unfinished current hour does not make today's coverage incomplete")
    func toleratesPendingCurrentHour() {
        let coverage = RestingEnergyCoverage(
            expectedDuration: 24 * 60 * 60,
            primaryDuration: 23 * 60 * 60,
            iPhoneFallbackDuration: 0,
            pendingDuration: 60 * 60
        )

        #expect(coverage.missingDuration == 60 * 60)
        #expect(coverage.isComplete)
    }

    @Test("A pending current hour does not hide earlier coverage gaps")
    func pendingHourDoesNotHideEarlierGaps() {
        let coverage = RestingEnergyCoverage(
            expectedDuration: 24 * 60 * 60,
            primaryDuration: 22 * 60 * 60,
            iPhoneFallbackDuration: 0,
            pendingDuration: 60 * 60
        )

        #expect(!coverage.isComplete)
    }

    @Test("Aggregating intervals keeps energy and provenance consistent")
    func aggregatesIntervals() throws {
        let start = Date.now
        let values = [
            FusedRestingEnergyInterval(
                interval: DateInterval(start: start, duration: 3_600),
                kilocalories: 70,
                coverage: RestingEnergyCoverage(
                    expectedDuration: 3_600,
                    primaryDuration: 3_600,
                    iPhoneFallbackDuration: 0
                )
            ),
            FusedRestingEnergyInterval(
                interval: DateInterval(start: start.addingTimeInterval(3_600), duration: 3_600),
                kilocalories: 72,
                coverage: RestingEnergyCoverage(
                    expectedDuration: 3_600,
                    primaryDuration: 0,
                    iPhoneFallbackDuration: 3_600
                )
            ),
            FusedRestingEnergyInterval(
                interval: DateInterval(start: start.addingTimeInterval(7_200), duration: 3_600),
                kilocalories: nil,
                coverage: RestingEnergyCoverage(
                    expectedDuration: 3_600,
                    primaryDuration: 0,
                    iPhoneFallbackDuration: 0,
                    pendingDuration: 3_600
                )
            ),
        ]

        let aggregate = RestingEnergyFusionBuilder.aggregate(values)

        #expect(aggregate.kilocalories == 142)
        #expect(aggregate.coverage?.expectedDuration == 10_800)
        #expect(aggregate.coverage?.primaryDuration == 3_600)
        #expect(aggregate.coverage?.iPhoneFallbackDuration == 3_600)
        #expect(aggregate.coverage?.pendingDuration == 3_600)
        #expect(aggregate.coverage?.isComplete == true)
    }
}
