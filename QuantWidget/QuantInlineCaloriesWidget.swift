import SwiftUI
import WidgetKit

struct QuantCalorieEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetCalorieSnapshot
}

struct QuantCalorieProvider: TimelineProvider {
    private let calendar = Calendar.autoupdatingCurrent
    private let store = WidgetCalorieSnapshotStore()

    func placeholder(in context: Context) -> QuantCalorieEntry {
        QuantCalorieEntry(
            date: .now,
            snapshot: WidgetCalorieSnapshot(
                dayStart: calendar.startOfDay(for: .now),
                energyKilocalories: 2_123,
                hasProvisionalValues: true
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (QuantCalorieEntry) -> Void) {
        let date = Date.now
        completion(QuantCalorieEntry(
            date: date,
            snapshot: context.isPreview
                ? placeholder(in: context).snapshot
                : store.snapshot(for: date, calendar: calendar)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuantCalorieEntry>) -> Void) {
        let date = Date.now
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            ?? date.addingTimeInterval(86_400)
        let currentEntry = QuantCalorieEntry(
            date: date,
            snapshot: store.snapshot(for: date, calendar: calendar)
        )
        let rolloverEntry = QuantCalorieEntry(
            date: nextDay,
            snapshot: .empty(for: nextDay, calendar: calendar)
        )
        completion(Timeline(entries: [currentEntry, rolloverEntry], policy: .atEnd))
    }
}

struct QuantInlineCaloriesWidgetView: View {
    let entry: QuantCalorieEntry
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        Text(WidgetCalorieTextFormatter.text(
            for: entry.date,
            snapshot: entry.snapshot,
            calendar: calendar
        ))
        .accessibilityLabel(WidgetCalorieTextFormatter.accessibilityText(
            for: entry.date,
            snapshot: entry.snapshot,
            calendar: calendar
        ))
        .widgetURL(QuantWidgetConfiguration.todayURL)
    }
}

struct QuantInlineCaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: QuantWidgetConfiguration.widgetKind,
            provider: QuantCalorieProvider()
        ) { entry in
            QuantInlineCaloriesWidgetView(entry: entry)
        }
        .configurationDisplayName("Heutige Kalorien")
        .description("Zeigt die heute aufgenommenen Kalorien über der Uhr.")
        .supportedFamilies([.accessoryInline])
    }
}

@main
struct QuantWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuantInlineCaloriesWidget()
    }
}

#Preview(as: .accessoryInline) {
    QuantInlineCaloriesWidget()
} timeline: {
    QuantCalorieEntry(
        date: .now,
        snapshot: WidgetCalorieSnapshot(
            dayStart: Calendar.autoupdatingCurrent.startOfDay(for: .now),
            energyKilocalories: 2_123,
            hasProvisionalValues: true
        )
    )
}
