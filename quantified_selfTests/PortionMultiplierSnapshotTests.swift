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
