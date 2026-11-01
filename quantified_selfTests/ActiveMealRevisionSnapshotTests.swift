import Testing
@testable import Quant

@MainActor
struct ActiveMealRevisionSnapshotTests {
    @Test("Snapshot resolves and retains the active revision")
    func resolvesActiveRevisionOnce() {
        let first = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: .confirmed,
            mealName: "First",
            confidence: .medium
        )
        let second = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: .confirmed,
            mealName: "Second",
            confidence: .medium
        )
        let meal = Meal(
            activeRevisionID: first.id,
            analysisRevisions: [first, second]
        )
        let snapshot = ActiveMealRevisionSnapshot(meals: [meal])

        #expect(snapshot.revision(for: meal) === first)

        meal.activeRevisionID = second.id
        #expect(snapshot.revision(for: meal) === first)
        #expect(ActiveMealRevisionSnapshot(meals: [meal]).revision(for: meal) === second)
    }
}
