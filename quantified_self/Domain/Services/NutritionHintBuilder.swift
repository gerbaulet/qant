import Foundation

enum NutritionHintKind: String, Sendable {
    case calorieTargetNear
    case proteinLow
    case fiberLow
}

struct NutritionHint: Identifiable, Sendable, Equatable {
    let kind: NutritionHintKind
    let message: String
    let systemImage: String

    var id: NutritionHintKind { kind }
}

enum NutritionHintBuilder {
    /// Rules are intentionally conservative: macro shortfalls are only shown
    /// from 18:00 onward, when they are useful rather than premature.
    static func makeHints(
        for snapshot: TodayDashboardSnapshot,
        at date: Date,
        calendar: Calendar
    ) -> [NutritionHint] {
        guard !snapshot.meals.isEmpty else { return [] }

        var hints: [NutritionHint] = []
        if let fraction = snapshot.energy.fractionCompleted,
           fraction >= 0.9,
           fraction <= 1 {
            hints.append(NutritionHint(
                kind: .calorieTargetNear,
                message: "Du hast dein heutiges Kalorienziel fast erreicht.",
                systemImage: "gauge.with.dots.needle.67percent"
            ))
        }

        guard calendar.component(.hour, from: date) >= 18 else {
            return hints
        }

        if let protein = snapshot.macros.first(where: { $0.id == .protein }),
           let fraction = protein.fractionCompleted,
           fraction < 0.75 {
            hints.append(NutritionHint(
                kind: .proteinLow,
                message: "Protein liegt heute noch unter deinem Ziel.",
                systemImage: "circle.hexagongrid"
            ))
        }

        if let fraction = snapshot.fiber.fractionCompleted,
           fraction < 0.7 {
            hints.append(NutritionHint(
                kind: .fiberLow,
                message: "Deine Ballaststoffzufuhr ist heute noch niedrig.",
                systemImage: "leaf"
            ))
        }

        return Array(hints.prefix(2))
    }
}
