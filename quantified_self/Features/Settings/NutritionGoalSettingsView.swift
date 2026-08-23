import SwiftData
import SwiftUI

struct NutritionGoalSettingsSection: View {
    let goals: [NutritionGoalPeriod]

    private var today: Date { .now }

    var body: some View {
        Section("Ziele") {
            ForEach(NutritionGoalDefinition.all) { definition in
                LabeledContent(definition.title) {
                    if let value = GoalHistory.goal(
                        for: definition.nutrient,
                        at: today,
                        in: goals
                    )?.targetValue {
                        Text("\(wholeNumber(value)) \(definition.unit.rawValue)")
                    } else {
                        Text("Nicht festgelegt")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("Kalorienziel diese Woche") {
                if let weeklyTarget = try? GoalHistory.weeklyTarget(
                    for: .energy,
                    containing: today,
                    calendar: .autoupdatingCurrent,
                    periods: goals
                ) {
                    Text("\(wholeNumber(weeklyTarget)) kcal")
                } else {
                    Text("Unvollständig")
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink("Ziele bearbeiten") {
                NutritionGoalEditor(goals: goals)
            }
        }
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct NutritionGoalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let goals: [NutritionGoalPeriod]

    @State private var values: [NutrientIdentifier: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(NutritionGoalDefinition.all) { definition in
                    HStack {
                        Text(definition.title)
                        Spacer()
                        TextField(
                            definition.unit.rawValue,
                            text: binding(for: definition.nutrient)
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        Text(definition.unit.rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Änderungen gelten ab heute. Frühere Zielwerte bleiben für historische Auswertungen erhalten.")
            }
        }
        .navigationTitle("Ernährungsziele")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern", action: save)
            }
        }
        .onAppear(perform: loadValues)
        .alert("Ziele nicht gespeichert", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Ungültige Eingabe")
        }
    }

    private func binding(for nutrient: NutrientIdentifier) -> Binding<String> {
        Binding(
            get: { values[nutrient, default: ""] },
            set: { values[nutrient] = $0 }
        )
    }

    private func loadValues() {
        guard values.isEmpty else { return }
        for definition in NutritionGoalDefinition.all {
            if let value = GoalHistory.goal(
                for: definition.nutrient,
                at: .now,
                in: goals
            )?.targetValue {
                values[definition.nutrient] = value.formatted(
                    .number.locale(Locale(identifier: "de_DE")).grouping(.never)
                )
            }
        }
    }

    private func save() {
        do {
            let now = Date.now
            for definition in NutritionGoalDefinition.all {
                guard let input = values[definition.nutrient],
                      let value = Double(input.replacingOccurrences(of: ",", with: ".")),
                      value > 0 else {
                    throw GoalHistoryError.invalidTarget
                }
                let current = GoalHistory.goal(
                    for: definition.nutrient,
                    at: now,
                    in: goals
                )
                guard current?.targetValue != value || current?.unit != definition.unit else {
                    continue
                }
                let changed = try GoalHistory.applyChange(
                    for: definition.nutrient,
                    targetValue: value,
                    unit: definition.unit,
                    effectiveOn: now,
                    calendar: .autoupdatingCurrent,
                    periods: goals,
                    now: now
                )
                if !goals.contains(where: { $0.id == changed.id }) {
                    modelContext.insert(changed)
                }
            }
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "Bitte gib für jedes Ziel eine positive Zahl ein."
        }
    }
}

private struct NutritionGoalDefinition: Identifiable {
    let nutrient: NutrientIdentifier
    let title: LocalizedStringKey
    let unit: NutrientUnit

    var id: NutrientIdentifier { nutrient }

    static let all: [NutritionGoalDefinition] = [
        NutritionGoalDefinition(nutrient: .energy, title: "Kalorien", unit: .kilocalorie),
        NutritionGoalDefinition(nutrient: .protein, title: "Protein", unit: .gram),
        NutritionGoalDefinition(nutrient: .carbohydrates, title: "Kohlenhydrate", unit: .gram),
        NutritionGoalDefinition(nutrient: .fat, title: "Fett", unit: .gram),
        NutritionGoalDefinition(nutrient: .fiber, title: "Ballaststoffe", unit: .gram),
    ]
}
