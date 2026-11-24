import Foundation

/// Resolves each meal's active revision once for a presentation-data build.
/// The snapshot is intentionally short-lived so persistence does not need a
/// redundant cached relationship or a schema migration.
@MainActor
final class ActiveMealRevisionSnapshot {
    private let revisionsByMealID: [UUID: MealAnalysisRevision]

    init(meals: [Meal]) {
        revisionsByMealID = Dictionary(uniqueKeysWithValues: meals.compactMap { meal in
            meal.activeRevision.map { (meal.id, $0) }
        })
    }

    func revision(for meal: Meal) -> MealAnalysisRevision? {
        revisionsByMealID[meal.id]
    }
}
