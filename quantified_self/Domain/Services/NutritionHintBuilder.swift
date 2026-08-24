import Foundation

enum NutritionHintKind: String, Sendable {
    case calorieTargetNear
    case calorieTargetExceeded
    case proteinLow
    case proteinTargetReached
    case fiberLow
    case fiberTargetReached
    case carbohydratesLow
    case fatHigh
}

struct NutritionHint: Identifiable, Sendable, Equatable {
    let kind: NutritionHintKind
    let message: String
    let systemImage: String

    var id: NutritionHintKind { kind }
    var importanceScore: Int { kind.importanceScore }
}

private extension NutritionHintKind {
    var importanceScore: Int {
        switch self {
        case .calorieTargetExceeded: 100
        case .proteinLow: 90
        case .fiberLow: 85
        case .fatHigh: 80
        case .carbohydratesLow: 75
        case .calorieTargetNear: 60
        case .proteinTargetReached: 40
        case .fiberTargetReached: 35
        }
    }
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
        if let fraction = snapshot.energy.fractionCompleted {
            if fraction >= 1.1 {
                hints.append(NutritionHint(
                    kind: .calorieTargetExceeded,
                    message: "Du liegst heute deutlich über deinem Kalorienziel.",
                    systemImage: "gauge.with.dots.needle.100percent"
                ))
            } else if fraction >= 0.9, fraction <= 1 {
                hints.append(NutritionHint(
                    kind: .calorieTargetNear,
                    message: "Du hast dein heutiges Kalorienziel fast erreicht.",
                    systemImage: "gauge.with.dots.needle.67percent"
                ))
            }
        }

        if let protein = snapshot.macros.first(where: { $0.id == .protein }),
           let fraction = protein.fractionCompleted,
           fraction >= 1 {
            hints.append(NutritionHint(
                kind: .proteinTargetReached,
                message: "Dein Proteinziel ist heute erreicht.",
                systemImage: "checkmark.circle"
            ))
        }

        if let fraction = snapshot.fiber.fractionCompleted,
           fraction >= 1 {
            hints.append(NutritionHint(
                kind: .fiberTargetReached,
                message: "Dein Ballaststoffziel ist heute erreicht.",
                systemImage: "leaf.circle"
            ))
        }

        if let fat = snapshot.macros.first(where: { $0.id == .fat }),
           let fraction = fat.fractionCompleted,
           fraction >= 1.15 {
            hints.append(NutritionHint(
                kind: .fatHigh,
                message: "Fett liegt heute deutlich über deinem Ziel.",
                systemImage: "drop.triangle"
            ))
        }

        guard calendar.component(.hour, from: date) >= 18 else {
            return mostImportantHints(from: hints)
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

        if let carbohydrates = snapshot.macros.first(where: { $0.id == .carbohydrates }),
           let fraction = carbohydrates.fractionCompleted,
           fraction < 0.6 {
            hints.append(NutritionHint(
                kind: .carbohydratesLow,
                message: "Kohlenhydrate liegen heute noch deutlich unter deinem Ziel.",
                systemImage: "chart.bar.fill"
            ))
        }

        return mostImportantHints(from: hints)
    }

    private static func mostImportantHints(from hints: [NutritionHint]) -> [NutritionHint] {
        Array(hints
            .sorted { $0.importanceScore > $1.importanceScore }
            .prefix(2))
    }
}
