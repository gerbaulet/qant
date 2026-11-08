import Foundation
import Testing
@testable import Quant

@MainActor
struct PortionMultiplierSnapshotTests {
    @Test("Snapshot reads each portion multiplier once")
    func capturesPortionMultiplier() {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: .confirmed,
            mealName: "Testmahlzeit",
            confidence: .medium
        )
        revision.portionMultiplier = 1.5
        let snapshot = PortionMultiplierSnapshot()
        #expect(snapshot.scaled(100, for: revision) == 150)
        revision.portionMultiplier = 2

        #expect(snapshot.scaled(100, for: revision) == 150)
    }

    @Test("Snapshot captures component adjustments once for all nutrients")
    func capturesComponentAdjustments() {
        let energy = NutrientValue(identifier: .energy, value: 300, unit: .kilocalorie, confidence: .medium, provenance: .visualEstimate)
        let protein = NutrientValue(identifier: .protein, value: 20, unit: .gram, confidence: .medium, provenance: .visualEstimate)
        let component = FoodComponent(
            sortIndex: 0,
            name: "Reis",
            nutrients: [
                NutrientValue(identifier: .energy, value: 200, unit: .kilocalorie, confidence: .medium, provenance: .visualEstimate),
                NutrientValue(identifier: .protein, value: 10, unit: .gram, confidence: .medium, provenance: .visualEstimate),
            ]
        )
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: .confirmed,
            mealName: "Test",
            confidence: .medium,
            components: [component],
            nutrients: [energy, protein]
        )
        revision.providerMetadata = InitialAnalysisRunMetadata.settingComponentMultipliers(
            [component.id.uuidString: 2],
            in: revision.providerMetadata
        )
        let snapshot = PortionMultiplierSnapshot()

        #expect(snapshot.scaled(energy, for: revision) == 500)
        #expect(snapshot.scaled(protein, for: revision) == 30)

        revision.providerMetadata = InitialAnalysisRunMetadata.settingComponentMultipliers(
            [component.id.uuidString: 0],
            in: revision.providerMetadata
        )
        #expect(snapshot.scaled(energy, for: revision) == 500)
        #expect(snapshot.scaled(protein, for: revision) == 30)
    }

    @Test("A positive validated call replaces a broken persisted zero")
    func recoversPersistedZero() {
        let calls = InitialAnalysisRunMetadata.encodeCalls([
            AnalysisCallSummary(
                callNumber: 1,
                sampleNumber: nil,
                attemptNumber: 1,
                status: .succeeded,
                modelIdentifier: "test/model",
                providerIdentifier: "Test",
                energyKilocalories: 483,
                errorMessage: nil
            ),
        ])
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            providerMetadata: calls,
            trigger: .correction,
            status: .confirmed,
            mealName: "Test",
            confidence: .medium,
            nutrients: NutritionAnalysisValidator.coreNutrients.map { identifier in
                NutrientValue(
                    identifier: identifier,
                    value: 0,
                    unit: identifier == .energy ? .kilocalorie : .gram,
                    confidence: .medium,
                    provenance: .visualEstimate
                )
            }
        )

        #expect(PortionMultiplierSnapshot().scaledValue(for: .energy, in: revision) == 483)
    }

    @Test("Fallback selection keeps the median rule for three initial estimates")
    func fallbackUsesInitialMedian() {
        let metadata = InitialAnalysisRunMetadata.encodeCalls([
            call(number: 1, sample: 1, energy: 500),
            call(number: 2, sample: 2, energy: 700),
            call(number: 3, sample: 3, energy: 600),
        ])
        let incompleteMetadata = InitialAnalysisRunMetadata.encodeCalls([
            call(number: 1, sample: 1, energy: 500),
            call(number: 2, sample: 2, energy: 700),
        ])

        #expect(InitialAnalysisRunMetadata.selectedEnergyKilocalories(
            from: metadata,
            trigger: .initial
        ) == 600)
        #expect(InitialAnalysisRunMetadata.selectedEnergyKilocalories(
            from: incompleteMetadata,
            trigger: .initial
        ) == 500)
    }

    private func call(number: Int, sample: Int, energy: Double) -> AnalysisCallSummary {
        AnalysisCallSummary(
            callNumber: number,
            sampleNumber: sample,
            attemptNumber: 1,
            status: .succeeded,
            modelIdentifier: "test/model",
            providerIdentifier: "Test",
            energyKilocalories: energy,
            errorMessage: nil
        )
    }
}

@MainActor
struct PortionAdjustmentDraftTests {
    @Test("Draft rounds slider values and enforces supported bounds")
    func normalization() {
        let draft = PortionAdjustmentDraft(multiplier: 1.26)
        #expect(draft.multiplier == 1.3)

        draft.update(-1)
        #expect(draft.multiplier == 0)

        draft.update(5)
        #expect(draft.multiplier == 4)

        draft.update(.infinity)
        #expect(draft.multiplier == 1)
    }
}

@MainActor
struct ComponentPortionScalingTests {
    private func energy(_ value: Double) -> NutrientValue {
        NutrientValue(identifier: .energy, value: value, unit: .kilocalorie, confidence: .medium, provenance: .visualEstimate)
    }

    @Test("Component adjustment preserves other components and combines with the meal multiplier")
    func independentScaling() {
        let rice = FoodComponent(sortIndex: 0, name: "Reis", estimatedWeightGrams: 100, nutrients: [energy(200)])
        let sauce = FoodComponent(sortIndex: 1, name: "Sauce", estimatedWeightGrams: 50, nutrients: [energy(100)])
        let total = energy(300)
        let revision = MealAnalysisRevision(modelIdentifier: "test/model", status: .confirmed, mealName: "Test", confidence: .medium)
        revision.components = [rice, sauce]
        revision.nutrients = [total]
        revision.estimatedTotalWeightGrams = 150
        let draft = PortionAdjustmentDraft(multiplier: 1.5)
        draft.updateComponent(rice, value: 2)
        #expect(draft.componentMultiplier(for: sauce) == 1)
        #expect(ComponentPortionScaling.nutrient(total, in: revision, multipliers: draft.componentMultipliers) == 500)
        #expect(ComponentPortionScaling.weight(in: revision, multipliers: draft.componentMultipliers) == 250)
        revision.portionMultiplier = draft.multiplier
        revision.providerMetadata = InitialAnalysisRunMetadata.settingComponentMultipliers(draft.componentMultipliers, in: revision.providerMetadata)
        #expect(PortionMultiplierSnapshot().scaled(total, for: revision) == 750)
        #expect(total.value == 300)
        #expect(rice.nutrients.first?.value == 200)
        draft.updateComponent(rice, value: 0)
        #expect(ComponentPortionScaling.nutrient(total, in: revision, multipliers: draft.componentMultipliers) == 100)
        draft.updateComponent(rice, value: 4.5)
        #expect(draft.componentMultiplier(for: rice) == 4)
        draft.updateComponent(rice, value: .nan)
        #expect(draft.componentMultiplier(for: rice) == 1)
    }

    @Test("Component metadata round trips without losing legacy runs or the meal multiplier")
    func metadataCompatibility() {
        let legacy = "{\"version\":1,\"runs\":[],\"portionMultiplier\":1.5}"
        let updated = InitialAnalysisRunMetadata.settingComponentMultipliers(["rice": 2], in: legacy)
        let rescaled = InitialAnalysisRunMetadata.settingPortionMultiplier(3, in: updated)
        #expect(InitialAnalysisRunMetadata.componentMultipliers(from: rescaled) == ["rice": 2])
        #expect(InitialAnalysisRunMetadata.portionMultiplier(from: rescaled) == 3)
        #expect(InitialAnalysisRunMetadata.componentMultipliers(from: legacy).isEmpty)
        let calls = "{\"version\":2,\"calls\":[],\"portionMultiplier\":2}"
        let updatedCalls = InitialAnalysisRunMetadata.settingComponentMultipliers(["rice": 0], in: calls)
        #expect(InitialAnalysisRunMetadata.componentMultipliers(from: updatedCalls) == ["rice": 0])
        #expect(InitialAnalysisRunMetadata.portionMultiplier(from: updatedCalls) == 2)

        let selectedEnergy = AnalyzedNutrient(
            identifier: .energy,
            value: 483,
            unit: .kilocalorie,
            confidence: .medium,
            provenance: .visualEstimate
        )
        let selectedMetadata = InitialAnalysisRunMetadata.encodeCalls(
            [AnalysisCallSummary(
                callNumber: 1,
                sampleNumber: nil,
                attemptNumber: 1,
                status: .succeeded,
                modelIdentifier: "test/model",
                providerIdentifier: "Test",
                energyKilocalories: 483,
                errorMessage: nil
            )],
            selectedNutrients: [selectedEnergy]
        )
        let selectedRescaled = InitialAnalysisRunMetadata.settingPortionMultiplier(1.5, in: selectedMetadata)
        #expect(InitialAnalysisRunMetadata.selectedNutrient(
            .energy,
            from: selectedRescaled,
            trigger: .correction
        ) == selectedEnergy)
    }
}
