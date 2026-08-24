import Foundation

enum MealHistoryGrouping: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: Self { self }
}

struct MealHistoryEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let name: String?
    let category: MealCategory
    let energyKilocalories: Double?
    let analysisState: AnalysisState
    let isProvisional: Bool
    let thumbnailStorageKey: String?
}

struct MealHistorySection: Identifiable, Sendable {
    let id: Date
    let interval: DateInterval
    let entries: [MealHistoryEntry]

    var totalEnergyKilocalories: Double? {
        let values = entries.compactMap(\.energyKilocalories)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    var containsProvisionalEnergy: Bool {
        entries.contains { $0.energyKilocalories != nil && $0.isProvisional }
    }
}

@MainActor
enum MealHistoryBuilder {
    static func makeSections(
        meals: [Meal],
        grouping: MealHistoryGrouping,
        calendar: Calendar
    ) -> [MealHistorySection] {
        let visibleMeals = meals
            .filter { $0.mealState != .archived }
            .sorted { $0.timestamp > $1.timestamp }
        let grouped = Dictionary(grouping: visibleMeals) { meal in
            interval(for: meal.timestamp, grouping: grouping, calendar: calendar)?.start
                ?? meal.timestamp
        }

        return grouped.keys.sorted(by: >).compactMap { start in
            guard let interval = interval(for: start, grouping: grouping, calendar: calendar) else {
                return nil
            }
            return MealHistorySection(
                id: start,
                interval: interval,
                entries: (grouped[start] ?? []).map(makeEntry)
            )
        }
    }

    private static func interval(
        for date: Date,
        grouping: MealHistoryGrouping,
        calendar: Calendar
    ) -> DateInterval? {
        switch grouping {
        case .day:
            calendar.dateInterval(of: .day, for: date)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)
        case .month:
            calendar.dateInterval(of: .month, for: date)
        }
    }

    private static func makeEntry(_ meal: Meal) -> MealHistoryEntry {
        let revision = meal.activeRevision
        let includesNutrition = revision.map { revision in
            switch revision.status {
            case .needsClarification, .awaitingConfirmation, .confirmed: true
            case .pending, .analyzing, .failed: false
            }
        } ?? false
        let energy = includesNutrition
            ? revision?.nutrients.first(where: {
                $0.identifierRawValue == NutrientIdentifier.energy.rawValue &&
                    $0.unitRawValue == NutrientUnit.kilocalorie.rawValue
            })?.value
            : nil
        return MealHistoryEntry(
            id: meal.id,
            timestamp: meal.timestamp,
            name: revision?.mealName,
            category: meal.category,
            energyKilocalories: energy,
            analysisState: meal.analysisState,
            isProvisional: includesNutrition && revision?.status != .confirmed,
            thumbnailStorageKey: meal.images.min(by: { $0.sortIndex < $1.sortIndex })?.thumbnailStorageKey
        )
    }
}
