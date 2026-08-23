import SwiftData
import SwiftUI

struct ContentView: View {
    private enum AppSection: Hashable {
        case today
        case meals
        case trends
        case settings
    }

    @State private var selectedSection: AppSection = .today
    @State private var showsMealCapture = false

    var body: some View {
        TabView(selection: $selectedSection) {
            Tab("Heute", systemImage: "sun.max.fill", value: .today) {
                TodayDashboardContainer {
                    showsMealCapture = true
                }
            }

            Tab("Mahlzeiten", systemImage: "fork.knife", value: .meals) {
                FeaturePlaceholderView(
                    title: "Mahlzeiten",
                    message: "Der Mahlzeitenverlauf folgt nach der Erfassung.",
                    systemImage: "list.bullet.rectangle"
                )
            }

            Tab("Trends", systemImage: "chart.xyaxis.line", value: .trends) {
                FeaturePlaceholderView(
                    title: "Trends",
                    message: "Trends werden sichtbar, sobald Mahlzeiten erfasst sind.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            }

            Tab("Einstellungen", systemImage: "gearshape", value: .settings) {
                FeaturePlaceholderView(
                    title: "Einstellungen",
                    message: "Ziele und KI-Einstellungen folgen in einem späteren Meilenstein.",
                    systemImage: "gearshape"
                )
            }
        }
        .sheet(isPresented: $showsMealCapture) {
            MealCaptureView()
        }
    }
}

private struct TodayDashboardContainer: View {
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]

    let onAddFood: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            TodayDashboardView(
                snapshot: TodayDashboardBuilder.makeSnapshot(
                    for: context.date,
                    meals: meals,
                    goals: goals,
                    calendar: .autoupdatingCurrent
                ),
                onAddFood: onAddFood
            )
        }
    }
}

private struct FeaturePlaceholderView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(message)
            }
            .navigationTitle(title)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: NutritionSchemaV1.models, inMemory: true)
}
