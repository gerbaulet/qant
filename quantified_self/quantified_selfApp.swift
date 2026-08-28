//
//  QuantApp.swift
//  Quant
//
//  Created by Clemens Gerbaulet on 23.08.26.
//

import SwiftUI
import SwiftData

@main
struct QuantApp: App {
    var sharedModelContainer: ModelContainer = {
        let usesEphemeralStore = ProcessInfo.processInfo.arguments.contains("--ui-testing")

        do {
            let container = try NutritionModelContainerFactory.makeContainer(
                mode: .current,
                isStoredInMemoryOnly: usesEphemeralStore
            )
            try MealAnalysisCoordinator.recoverInterruptedAnalyses(in: container.mainContext)
            try InitialDataSeeder.seedGoalsIfNeeded(in: container.mainContext)
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-quick-capture") {
                QuickCaptureRequestStore().requestCapture()
            }
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
