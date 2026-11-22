import Foundation

@MainActor
enum EnergyBalanceBuilder {
    static func makeBalances(
        within interval: DateInterval,
        meals: [Meal],
        expenditures: [DailyEnergyExpenditure],
        now: Date,
        calendar: Calendar
    ) -> [DailyEnergyBalance] {
        let portionMultipliers = PortionMultiplierSnapshot()
        let activeRevisions = ActiveMealRevisionSnapshot(meals: meals)
        let relevantMeals = meals.filter {
            $0.mealState != .archived &&
                $0.timestamp >= interval.start &&
                $0.timestamp < interval.end
        }
        let mealsByDay = Dictionary(grouping: relevantMeals) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let expenditureByDay = Dictionary(
            expenditures.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let today = calendar.startOfDay(for: now)

        var result: [DailyEnergyBalance] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let dayMeals = mealsByDay[day, default: []]
            let expenditure = expenditureByDay[day]
            result.append(makeBalance(
                day: day,
                meals: dayMeals,
                expenditure: expenditure,
                isCurrentDay: calendar.isDate(day, inSameDayAs: today),
                portionMultipliers: portionMultipliers,
                activeRevisions: activeRevisions
            ))
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  nextDay > day else {
                break
            }
            day = nextDay
        }
        return result
    }

    static func makeBalance(
        for date: Date,
        meals: [Meal],
        expenditure: DailyEnergyExpenditure?,
        now: Date,
        calendar: Calendar
    ) -> DailyEnergyBalance {
        let day = calendar.startOfDay(for: date)
        let dayMeals = meals.filter {
            $0.mealState != .archived && calendar.isDate($0.timestamp, inSameDayAs: day)
        }
        return makeBalance(
            day: day,
            meals: dayMeals,
            expenditure: expenditure,
            isCurrentDay: calendar.isDate(day, inSameDayAs: now),
            portionMultipliers: PortionMultiplierSnapshot(),
            activeRevisions: ActiveMealRevisionSnapshot(meals: meals)
        )
    }

    private static func makeBalance(
        day: Date,
        meals: [Meal],
        expenditure: DailyEnergyExpenditure?,
        isCurrentDay: Bool,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> DailyEnergyBalance {
        let revisions = meals.compactMap { activeRevisions.revision(for: $0) }
        let usableRevisions = revisions.filter { $0.status.includesNutritionEstimate }
        let energyValues = usableRevisions.compactMap {
            portionMultipliers.scaledValue(for: .energy, in: $0)
        }
        let intake = energyValues.isEmpty ? nil : energyValues.reduce(0, +)
        let hasIncompleteMeal = meals.contains { meal in
            activeRevisions.revision(for: meal)?.status.includesNutritionEstimate != true
        }
        let hasProvisionalMeal = usableRevisions.contains {
            $0.status.isProvisionalNutritionEstimate
        }

        let completeness: EnergyBalanceCompleteness
        if meals.isEmpty || intake == nil {
            completeness = .missingIntake
        } else if expenditure?.activeKilocalories == nil {
            completeness = .missingActiveEnergy
        } else if expenditure?.restingKilocalories == nil {
            completeness = .missingRestingEnergy
        } else if expenditure?.restingEnergyCoverage?.isComplete == false {
            completeness = .incompleteRestingEnergy
        } else if hasIncompleteMeal || hasProvisionalMeal {
            completeness = .provisionalIntake
        } else {
            completeness = .complete
        }

        return DailyEnergyBalance(
            date: day,
            intakeKilocalories: intake,
            activeKilocalories: expenditure?.activeKilocalories,
            restingKilocalories: expenditure?.restingKilocalories,
            restingEnergyCoverage: expenditure?.restingEnergyCoverage,
            completeness: completeness,
            isCurrentDay: isCurrentDay
        )
    }
}
