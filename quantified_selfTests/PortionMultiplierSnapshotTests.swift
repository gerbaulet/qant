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
    }
}
