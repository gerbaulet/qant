import Foundation

enum WeeklyNutritionRecommendationKind: String, Sendable {
    case increaseFiber
    case increaseProtein
    case reduceFat
    case moderateEnergy
    case repeatFiberRichMeal
    case repeatProteinRichMeal
}

struct WeeklyNutritionRecommendation: Identifiable, Sendable, Equatable {
    let kind: WeeklyNutritionRecommendationKind
    let message: String
    let systemImage: String

    var id: WeeklyNutritionRecommendationKind { kind }
}

struct WeeklyNutritionSummary: Sendable {
    let interval: DateInterval
    let energyKilocalories: Double
    let energyTargetKilocalories: Double?
    let trackedDayCount: Int
    let averageEnergyKilocalories: Double?
    let averageProteinGrams: Double?
    let averageCarbohydratesGrams: Double?
    let averageFatGrams: Double?
    let averageFiberGrams: Double?
    let daysWithinEnergyTarget: Int
    let daysAboveEnergyTarget: Int
    let previousWeekAverageEnergyChangePercent: Double?
    let recommendations: [WeeklyNutritionRecommendation]
}

/// Builds stable historical statistics from confirmed revisions only. Missing
/// days remain missing instead of being interpreted as zero intake.
@MainActor
enum WeeklyNutritionSummaryBuilder {
    static func makeSummary(
        containing date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> WeeklyNutritionSummary? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date),
              let previousDate = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start),
              let previousInterval = calendar.dateInterval(of: .weekOfYear, for: previousDate) else {
            return nil
        }

        let current = aggregate(interval: interval, meals: meals, goals: goals, calendar: calendar)
        let previous = aggregate(interval: previousInterval, meals: meals, goals: goals, calendar: calendar)
        let change: Double?
        if let currentAverage = current.averageEnergy,
           let previousAverage = previous.averageEnergy,
           previousAverage > 0 {
            change = ((currentAverage - previousAverage) / previousAverage) * 100
        } else {
            change = nil
        }

        return WeeklyNutritionSummary(
            interval: interval,
            energyKilocalories: current.energy,
            energyTargetKilocalories: current.weeklyTarget,
            trackedDayCount: current.trackedDays,
            averageEnergyKilocalories: current.averageEnergy,
            averageProteinGrams: current.averageProtein,
            averageCarbohydratesGrams: current.averageCarbohydrates,
            averageFatGrams: current.averageFat,
            averageFiberGrams: current.averageFiber,
            daysWithinEnergyTarget: current.daysWithinTarget,
            daysAboveEnergyTarget: current.daysAboveTarget,
            previousWeekAverageEnergyChangePercent: change,
            recommendations: makeRecommendations(from: current)
        )
    }

    private struct Aggregate {
        var energy = 0.0
        var protein = 0.0
        var carbohydrates = 0.0
        var fat = 0.0
        var fiber = 0.0
        var trackedDays = 0
        var daysWithinTarget = 0
        var daysAboveTarget = 0
        var weeklyTarget: Double?
        var energyTargetTotal = 0.0
        var energyTargetDayCount = 0
        var proteinTargetTotal = 0.0
        var proteinTargetDayCount = 0
        var fatTargetTotal = 0.0
        var fatTargetDayCount = 0
        var fiberTargetTotal = 0.0
        var fiberTargetDayCount = 0
        var foodDescriptions: [String] = []
        var highestFiberMeal: (name: String, value: Double)?
        var highestProteinMeal: (name: String, value: Double)?

        var averageEnergy: Double? { average(energy) }
        var averageProtein: Double? { average(protein) }
        var averageCarbohydrates: Double? { average(carbohydrates) }
        var averageFat: Double? { average(fat) }
        var averageFiber: Double? { average(fiber) }
        var averageEnergyTarget: Double? { targetAverage(energyTargetTotal, energyTargetDayCount) }
        var averageProteinTarget: Double? { targetAverage(proteinTargetTotal, proteinTargetDayCount) }
        var averageFatTarget: Double? { targetAverage(fatTargetTotal, fatTargetDayCount) }
        var averageFiberTarget: Double? { targetAverage(fiberTargetTotal, fiberTargetDayCount) }

        private func average(_ value: Double) -> Double? {
            trackedDays > 0 ? value / Double(trackedDays) : nil
        }

        private func targetAverage(_ value: Double, _ dayCount: Int) -> Double? {
            dayCount > 0 ? value / Double(dayCount) : nil
        }
    }

    private static func aggregate(
        interval: DateInterval,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> Aggregate {
        var result = Aggregate()
        result.weeklyTarget = try? GoalHistory.weeklyTarget(
            for: .energy,
            containing: interval.start,
            calendar: calendar,
            periods: goals
        )

        var cursor = interval.start
        while cursor < interval.end,
              let day = calendar.dateInterval(of: .day, for: cursor) {
            let revisions = meals.compactMap { meal -> MealAnalysisRevision? in
                guard meal.mealState != .archived,
                      meal.timestamp >= day.start,
                      meal.timestamp < day.end,
                      let revision = meal.activeRevision,
                      revision.status == .confirmed else {
                    return nil
                }
                return revision
            }

            if !revisions.isEmpty {
                result.trackedDays += 1
                let energy = nutrientTotal(.energy, unit: .kilocalorie, revisions: revisions)
                result.energy += energy
                result.protein += nutrientTotal(.protein, unit: .gram, revisions: revisions)
                result.carbohydrates += nutrientTotal(.carbohydrates, unit: .gram, revisions: revisions)
                result.fat += nutrientTotal(.fat, unit: .gram, revisions: revisions)
                result.fiber += nutrientTotal(.fiber, unit: .gram, revisions: revisions)

                for revision in revisions {
                    let description = ([revision.mealName] + revision.components.map(\.name))
                        .joined(separator: " ")
                    result.foodDescriptions.append(description)

                    let fiber = nutrientTotal(.fiber, unit: .gram, revisions: [revision])
                    if result.highestFiberMeal.map({ fiber > $0.value }) ?? true {
                        result.highestFiberMeal = (revision.mealName, fiber)
                    }

                    let protein = nutrientTotal(.protein, unit: .gram, revisions: [revision])
                    if result.highestProteinMeal.map({ protein > $0.value }) ?? true {
                        result.highestProteinMeal = (revision.mealName, protein)
                    }
                }

                if let target = GoalHistory.goal(for: .energy, at: day.start, in: goals)?.targetValue {
                    result.energyTargetTotal += target
                    result.energyTargetDayCount += 1
                    if energy <= target {
                        result.daysWithinTarget += 1
                    } else {
                        result.daysAboveTarget += 1
                    }
                }
                if let target = GoalHistory.goal(for: .protein, at: day.start, in: goals)?.targetValue {
                    result.proteinTargetTotal += target
                    result.proteinTargetDayCount += 1
                }
                if let target = GoalHistory.goal(for: .fat, at: day.start, in: goals)?.targetValue {
                    result.fatTargetTotal += target
                    result.fatTargetDayCount += 1
                }
                if let target = GoalHistory.goal(for: .fiber, at: day.start, in: goals)?.targetValue {
                    result.fiberTargetTotal += target
                    result.fiberTargetDayCount += 1
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: day.start), next > cursor else {
                break
            }
            cursor = next
        }
        return result
    }

    private struct RecommendationCandidate {
        let recommendation: WeeklyNutritionRecommendation
        let importance: Int
    }

    private static func makeRecommendations(from aggregate: Aggregate) -> [WeeklyNutritionRecommendation] {
        guard aggregate.trackedDays >= 3 else { return [] }

        var candidates: [RecommendationCandidate] = []
        let descriptions = aggregate.foodDescriptions
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()

        let fiberIsLow = fraction(aggregate.averageFiber, of: aggregate.averageFiberTarget).map { $0 < 0.8 } ?? false
        if fiberIsLow {
            candidates.append(RecommendationCandidate(
                recommendation: WeeklyNutritionRecommendation(
                    kind: .increaseFiber,
                    message: fiberRecommendation(for: descriptions),
                    systemImage: "leaf"
                ),
                importance: 100
            ))
        }

        let proteinIsLow = fraction(aggregate.averageProtein, of: aggregate.averageProteinTarget).map { $0 < 0.8 } ?? false
        if proteinIsLow {
            candidates.append(RecommendationCandidate(
                recommendation: WeeklyNutritionRecommendation(
                    kind: .increaseProtein,
                    message: proteinRecommendation(for: descriptions),
                    systemImage: "circle.hexagongrid"
                ),
                importance: 90
            ))
        }

        if let fatFraction = fraction(aggregate.averageFat, of: aggregate.averageFatTarget),
           fatFraction >= 1.15 {
            candidates.append(RecommendationCandidate(
                recommendation: WeeklyNutritionRecommendation(
                    kind: .reduceFat,
                    message: fatRecommendation(for: descriptions),
                    systemImage: "drop.triangle"
                ),
                importance: 85
            ))
        }

        let energyIsFrequentlyHigh = aggregate.daysAboveTarget * 2 >= aggregate.trackedDays
        let averageEnergyIsHigh = fraction(aggregate.averageEnergy, of: aggregate.averageEnergyTarget).map { $0 >= 1.05 } ?? false
        if energyIsFrequentlyHigh || averageEnergyIsHigh {
            candidates.append(RecommendationCandidate(
                recommendation: WeeklyNutritionRecommendation(
                    kind: .moderateEnergy,
                    message: "Behalte deine gewohnten Gerichte bei und reduziere bei einer Mahlzeit zuerst Sauce oder Beilage um ungefähr ein Viertel.",
                    systemImage: "chart.pie"
                ),
                importance: 80
            ))
        }

        if !fiberIsLow,
           let mealName = usefulMealName(aggregate.highestFiberMeal, minimumValue: 5) {
            candidates.append(RecommendationCandidate(
                recommendation: WeeklyNutritionRecommendation(
                    kind: .repeatFiberRichMeal,
                    message: "„\(mealName)“ hat gut zu deinen Ballaststoffen beigetragen. Plane eine ähnliche Mahlzeit nächste Woche wieder ein.",
                    systemImage: "arrow.clockwise.circle"
                ),
                importance: 40
            ))
        }

        if !proteinIsLow,
           let mealName = usefulMealName(aggregate.highestProteinMeal, minimumValue: 20) {
            candidates.append(RecommendationCandidate(
                recommendation: WeeklyNutritionRecommendation(
                    kind: .repeatProteinRichMeal,
                    message: "„\(mealName)“ war eine gute Proteinquelle. Eine ähnliche Mahlzeit passt auch nächste Woche zu deinem bisherigen Rhythmus.",
                    systemImage: "checkmark.circle"
                ),
                importance: 35
            ))
        }

        return candidates
            .sorted { $0.importance > $1.importance }
            .prefix(2)
            .map(\.recommendation)
    }

    private static func fraction(_ value: Double?, of target: Double?) -> Double? {
        guard let value, let target, target > 0 else { return nil }
        return value / target
    }

    private static func fiberRecommendation(for descriptions: String) -> String {
        if containsAny(["joghurt", "yogurt", "musli", "muesli", "hafer", "porridge"], in: descriptions) {
            return "Ergänze dein gewohntes Joghurt oder Müsli mit Haferflocken, Beeren oder einem Löffel Samen."
        }
        if containsAny(["reis", "nudel", "pasta", "brot", "brotchen", "wrap"], in: descriptions) {
            return "Tausche bei einer deiner gewohnten Reis-, Nudel- oder Brotmahlzeiten einen Teil gegen Vollkorn oder Hülsenfrüchte."
        }
        return "Ergänze eine deiner gewohnten Mahlzeiten um eine Handvoll Gemüse, Obst oder Hülsenfrüchte."
    }

    private static func proteinRecommendation(for descriptions: String) -> String {
        if containsAny(["joghurt", "yogurt", "musli", "muesli", "porridge"], in: descriptions) {
            return "Wähle bei deinem gewohnten Frühstück häufiger Skyr oder einen proteinreichen Joghurt."
        }
        if containsAny(["salat", "suppe"], in: descriptions) {
            return "Ergänze deine gewohnten Salate oder Suppen um Ei, Bohnen, Tofu oder eine andere einfache Proteinquelle."
        }
        return "Ergänze eine deiner gewohnten Mahlzeiten um eine handtellergroße Proteinquelle, zum Beispiel Bohnen, Tofu, Ei, Fisch oder Geflügel."
    }

    private static func fatRecommendation(for descriptions: String) -> String {
        if containsAny(["curry", "sauce", "kase", "pizza", "burger"], in: descriptions) {
            return "Nimm bei einem deiner gewohnten Gerichte etwas weniger Sauce, Käse oder Öl; der Rest der Mahlzeit kann gleich bleiben."
        }
        return "Reduziere bei einer gewohnten Mahlzeit zuerst Öl, Dressing oder eine cremige Beilage, statt das ganze Gericht zu ändern."
    }

    private static func containsAny(_ terms: [String], in text: String) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func usefulMealName(
        _ meal: (name: String, value: Double)?,
        minimumValue: Double
    ) -> String? {
        guard let meal, meal.value >= minimumValue else { return nil }
        let name = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Mahlzeit" else { return nil }
        return String(name.prefix(60))
    }

    private static func nutrientTotal(
        _ identifier: NutrientIdentifier,
        unit: NutrientUnit,
        revisions: [MealAnalysisRevision]
    ) -> Double {
        revisions
            .flatMap(\.nutrients)
            .filter { $0.identifierRawValue == identifier.rawValue && $0.unitRawValue == unit.rawValue }
            .reduce(0) { $0 + $1.value }
    }
}
