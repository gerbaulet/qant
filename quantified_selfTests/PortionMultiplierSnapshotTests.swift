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
