import Foundation

enum NutritionHintKind: String, Sendable, CaseIterable {
    case calorieTargetNear
    case calorieTargetExceeded
    case proteinLow
    case proteinTargetReached
    case fiberLow
    case fiberTargetReached
    case carbohydratesLow
    case carbohydratesHigh
    case fatHigh
    case energyVeryLow
    case energyTargetReached
    case proteinNearTarget
    case fiberNearTarget
    case fatLow
    case balancedTargets
    case regularMeals
    case estimatesPending
    case carbohydrateTargetReached
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
        case .carbohydratesHigh: 78
        case .energyVeryLow: 70
        case .calorieTargetNear: 60
        case .estimatesPending: 58
        case .energyTargetReached: 55
        case .balancedTargets: 52
        case .proteinNearTarget: 48
        case .fiberNearTarget: 46
        case .carbohydrateTargetReached: 44
        case .regularMeals: 30
        case .fatLow: 25
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
            } else if fraction > 1, fraction < 1.1 {
                hints.append(NutritionHint(
                    kind: .energyTargetReached,
                    message: "Deine Energiezufuhr liegt heute nah an deinem Ziel.",
                    systemImage: "checkmark.circle"
                ))
            }
        }

        if snapshot.hasProvisionalValues {
            hints.append(NutritionHint(
                kind: .estimatesPending,
                message: "Einige heutige Werte sind noch vorläufig und können sich nach der Analyse ändern.",
                systemImage: "clock.badge.questionmark"
            ))
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

        if let carbohydrates = snapshot.macros.first(where: { $0.id == .carbohydrates }),
           let fraction = carbohydrates.fractionCompleted {
            if fraction >= 1.15 {
                hints.append(NutritionHint(
                    kind: .carbohydratesHigh,
                    message: "Kohlenhydrate liegen heute deutlich über deinem Ziel.",
                    systemImage: "chart.bar.xaxis"
                ))
            } else if fraction >= 0.9, fraction <= 1.1 {
                hints.append(NutritionHint(
                    kind: .carbohydrateTargetReached,
                    message: "Deine Kohlenhydrate liegen heute nah am Zielbereich.",
                    systemImage: "checkmark.circle"
                ))
            }
        }

        if targetsAreBalanced(in: snapshot) {
            hints.append(NutritionHint(
                kind: .balancedTargets,
                message: "Kalorien, Protein, Kohlenhydrate und Fett liegen heute ausgewogen zu deinen Zielen.",
                systemImage: "scale.3d"
            ))
        }

        if hasRegularMealSpacing(snapshot.meals) {
            hints.append(NutritionHint(
                kind: .regularMeals,
                message: "Deine erfassten Mahlzeiten sind heute gleichmäßig über den Tag verteilt.",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
            ))
        }

        guard calendar.component(.hour, from: date) >= 18 else {
            return mostImportantHints(from: hints)
        }

        if let fraction = snapshot.energy.fractionCompleted, fraction < 0.55 {
            hints.append(NutritionHint(
                kind: .energyVeryLow,
                message: "Deine bisher erfasste Energie liegt für heute noch deutlich unter dem Ziel.",
                systemImage: "gauge.with.dots.needle.0percent"
            ))
        }

        if let protein = snapshot.macros.first(where: { $0.id == .protein }),
           let fraction = protein.fractionCompleted,
           fraction < 0.75 {
            hints.append(NutritionHint(
                kind: .proteinLow,
                message: "Protein liegt heute noch unter deinem Ziel.",
                systemImage: "circle.hexagongrid"
            ))
        } else if let protein = snapshot.macros.first(where: { $0.id == .protein }),
                  let fraction = protein.fractionCompleted,
                  fraction >= 0.75, fraction < 1 {
            hints.append(NutritionHint(
                kind: .proteinNearTarget,
                message: "Bis zu deinem Proteinziel fehlt heute nur noch wenig.",
                systemImage: "circle.hexagongrid.fill"
            ))
        }

        if let fraction = snapshot.fiber.fractionCompleted,
           fraction < 0.7 {
            hints.append(NutritionHint(
                kind: .fiberLow,
                message: "Deine Ballaststoffzufuhr ist heute noch niedrig.",
                systemImage: "leaf"
            ))
        } else if let fraction = snapshot.fiber.fractionCompleted,
                  fraction >= 0.7, fraction < 1 {
            hints.append(NutritionHint(
                kind: .fiberNearTarget,
                message: "Du bist heute schon nah an deinem Ballaststoffziel.",
                systemImage: "leaf.fill"
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

        if let fat = snapshot.macros.first(where: { $0.id == .fat }),
           let fraction = fat.fractionCompleted,
           fraction < 0.6 {
            hints.append(NutritionHint(
                kind: .fatLow,
                message: "Fett liegt heute noch unter deinem eingestellten Ziel.",
                systemImage: "drop"
            ))
        }

        return mostImportantHints(from: hints)
    }

    private static func mostImportantHints(from hints: [NutritionHint]) -> [NutritionHint] {
        Array(hints
            .sorted { $0.importanceScore > $1.importanceScore }
            .prefix(2))
    }

    private static func targetsAreBalanced(in snapshot: TodayDashboardSnapshot) -> Bool {
        let progress = [snapshot.energy] + snapshot.macros
        guard progress.allSatisfy({ $0.target != nil }) else { return false }
        return progress.allSatisfy { progress in
            guard let fraction = progress.fractionCompleted else { return false }
            return (0.85...1.1).contains(fraction)
        }
    }

    private static func hasRegularMealSpacing(_ meals: [TodayMealSummary]) -> Bool {
        let timestamps = meals
            .filter { $0.analysisState == .confirmed }
            .map(\.timestamp)
            .sorted()
        guard timestamps.count >= 3 else { return false }
        let gaps = zip(timestamps, timestamps.dropFirst()).map { $1.timeIntervalSince($0) }
        return gaps.allSatisfy { (2 * 60 * 60)...(7 * 60 * 60) ~= $0 }
    }
}
