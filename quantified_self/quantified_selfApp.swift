//
//  quantified_selfApp.swift
//  quantified_self
//
//  Created by Clemens Gerbaulet on 23.08.26.
//

import SwiftUI
import SwiftData

@main
struct quantified_selfApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema(NutritionSchemaV1.models)
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: NutritionMigrationPlan.self,
                configurations: [modelConfiguration]
            )
            try InitialDataSeeder.seedGoalsIfNeeded(in: container.mainContext)
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
