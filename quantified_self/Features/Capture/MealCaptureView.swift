import SwiftData
import SwiftUI

struct MealCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let classificationSchedule: MealClassificationSchedule
    private let calendar: Calendar

    @State private var timestamp: Date
    @State private var comment = ""
    @State private var category: MealCategory
    @State private var usesAutomaticCategory = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var commentIsFocused: Bool

    init(
        now: Date = .now,
        classificationSchedule: MealClassificationSchedule = .default,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.classificationSchedule = classificationSchedule
        self.calendar = calendar
        _timestamp = State(initialValue: now)
        _category = State(initialValue: classificationSchedule.category(
            for: now,
            calendar: calendar
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Zeitpunkt") {
                    DatePicker(
                        "Mahlzeit",
                        selection: $timestamp,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("meal.timestamp")
                }

                Section("Art der Mahlzeit") {
                    Picker("Kategorie", selection: categoryBinding) {
                        ForEach(MealCategory.allCases, id: \.self) { category in
                            Text(category.captureTitle).tag(category)
                        }
                    }
                    .accessibilityIdentifier("meal.category")

                    if !usesAutomaticCategory {
                        Button("Wieder automatisch bestimmen") {
                            usesAutomaticCategory = true
                            updateAutomaticCategory()
                        }
                    } else {
                        Label("Automatisch nach Uhrzeit gewählt", systemImage: "clock.badge.checkmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField(
                        "z. B. große Portion, ungefähr 350 g",
                        text: $comment,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .focused($commentIsFocused)
                    .accessibilityIdentifier("meal.comment")
                } header: {
                    Text("Kommentar (optional)")
                } footer: {
                    Text("Gewicht, Portionsgröße oder besondere Zutaten helfen später bei der Analyse.")
                }

                Section {
                    Label("Fotos können im nächsten Meilenstein hinzugefügt werden.", systemImage: "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Essen hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: save)
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                        .accessibilityIdentifier("meal.save")
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") {
                        commentIsFocused = false
                    }
                }
            }
            .onChange(of: timestamp) {
                if usesAutomaticCategory {
                    updateAutomaticCategory()
                }
            }
            .alert("Mahlzeit konnte nicht gespeichert werden", isPresented: showsError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unbekannter Fehler")
            }
        }
    }

    private var categoryBinding: Binding<MealCategory> {
        Binding(
            get: { category },
            set: {
                category = $0
                usesAutomaticCategory = false
            }
        )
    }

    private var showsError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func updateAutomaticCategory() {
        category = classificationSchedule.category(for: timestamp, calendar: calendar)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let repository = SwiftDataMealRepository(context: modelContext)
            try repository.createMeal(from: MealDraft(
                timestamp: timestamp,
                comment: comment,
                category: category
            ))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension MealCategory {
    var captureTitle: LocalizedStringKey {
        switch self {
        case .breakfast: "Frühstück"
        case .lunch: "Mittagessen"
        case .dinner: "Abendessen"
        case .snack: "Snack"
        }
    }
}

#Preview {
    MealCaptureView()
        .modelContainer(for: NutritionSchemaV1.models, inMemory: true)
}
