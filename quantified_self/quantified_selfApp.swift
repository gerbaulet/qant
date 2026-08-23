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
        let usesEphemeralStore = ProcessInfo.processInfo.arguments.contains("--ui-testing")

        do {
            let container = try NutritionModelContainerFactory.makeContainer(
                mode: .current,
                isStoredInMemoryOnly: usesEphemeralStore
            )
            try InitialDataSeeder.seedGoalsIfNeeded(in: container.mainContext)
#if DEBUG
            try UITestDataSeeder.seedReviewMealIfRequested(
                arguments: ProcessInfo.processInfo.arguments,
                in: container.mainContext
            )
#endif
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
