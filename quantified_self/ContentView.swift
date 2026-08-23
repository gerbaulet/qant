//
//  ContentView.swift
//  quantified_self
//
//  Created by Clemens Gerbaulet on 23.08.26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var meals: [Meal]

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Ernährungstagebuch", systemImage: "fork.knife")
            } description: {
                Text(meals.isEmpty
                     ? "Die Datengrundlage steht. Als Nächstes folgt die Heute-Ansicht."
                     : "Gespeicherte Mahlzeiten: \(meals.count)")
            }
            .navigationTitle("Heute")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            Meal.self,
            MealImage.self,
            MealAnalysisRevision.self,
            FoodComponent.self,
            NutrientValue.self,
            NutritionGoalPeriod.self,
        ], inMemory: true)
}
