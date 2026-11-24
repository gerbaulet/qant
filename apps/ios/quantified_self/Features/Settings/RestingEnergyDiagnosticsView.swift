import Charts
import SwiftUI

struct RestingEnergyDiagnosticsView: View {
    @Environment(HealthMetricsModel.self) private var healthMetrics
    @State private var snapshot: RestingEnergyDiagnosticsSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Die Gesamtzeile zeigt den von Quant verwendeten Wert. Watch-Daten haben Vorrang, danach folgen iPhone-Daten und klar ausgewiesene Quant-Schätzungen. Nachgetragene Health-Daten ersetzen Schätzungen automatisch. Die Diagramme zeigen die letzten sieben Tage stündlich.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let errorMessage, snapshot != nil {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if isLoading, snapshot == nil {
                    ProgressView("Ruheenergiedaten werden geladen …")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if let errorMessage, snapshot == nil {
                    ContentUnavailableView {
                        Label("Diagnose nicht verfügbar", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Erneut versuchen") {
                            Task { await load() }
                        }
                    }
                } else if let snapshot {
                    ForEach(snapshot.series) { series in
                        RestingEnergyDiagnosticSeriesCard(series: series)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Ruheenergie-Diagnose")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Label("Aktualisieren", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityIdentifier("settings.restingEnergyDiagnosticsRefresh")
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard !isLoading else { return }
        guard healthMetrics.hasRequestedEnergyAccess else {
            errorMessage = "Verbinde Quant zuerst mit den Energiedaten in Apple Health."
            return
        }

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else {
            errorMessage = "Der Zeitraum konnte nicht bestimmt werden."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await healthMetrics.restingEnergyDiagnostics(
                from: start,
                to: .now,
                calendar: calendar
            )
        } catch {
            errorMessage = "HealthKit konnte die Ruheenergiedaten nicht bereitstellen."
        }
    }
}

private struct RestingEnergyDiagnosticSeriesCard: View {
    let series: RestingEnergyDiagnosticSeries
    @State private var showsDailyValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Label(series.title, systemImage: systemImage)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(totalText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let details = series.details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Chart(series.hours) { hour in
                BarMark(
                    x: .value("Stunde", hour.date, unit: .hour),
                    y: .value("Ruheenergie", hour.kilocalories ?? 0)
                )
                .foregroundStyle(hour.kilocalories == nil ? Color.clear : tint)
            }
            .chartXScale(domain: chartDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(
                                .dateTime.weekday(.narrow).locale(Locale(identifier: "de_DE"))
                            ))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 128)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stündlicher Sieben-Tage-Verlauf für \(series.title)")
            .accessibilityValue(totalText)

            HStack(spacing: 16) {
                Label(coverageText, systemImage: "clock")
                if let sampleCount {
                    Label("\(sampleCount) Samples", systemImage: "list.number")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            DisclosureGroup("Tageswerte", isExpanded: $showsDailyValues) {
                VStack(spacing: 8) {
                    ForEach(series.days) { day in
                        dailyValueRow(day)
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("settings.restingEnergyDiagnostics.\(series.role.rawValue)")
    }

    private func dailyValueRow(_ day: RestingEnergyDiagnosticDay) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(day.date.formatted(
                .dateTime
                    .weekday(.short)
                    .day()
                    .month(.twoDigits)
                    .locale(Locale(identifier: "de_DE"))
            ))
            Spacer(minLength: 8)
            if let sampleCount = day.sampleCount {
                Text("\(sampleCount)×")
                    .foregroundStyle(.secondary)
            }
            Text(day.kilocalories.map { "\(Int($0.rounded())) kcal" } ?? "— kcal")
                .monospacedDigit()
        }
    }

    private var totalText: String {
        let total = series.days.compactMap(\.kilocalories).reduce(0, +)
        return series.days.contains(where: { $0.kilocalories != nil })
            ? "\(Int(total.rounded())) kcal"
            : "Keine Werte"
    }

    private var coverageText: String {
        let duration = series.days.compactMap(\.coveredDuration).reduce(0, +)
        guard duration > 0 else { return "Keine Abdeckung" }
        let hours = (duration / 3_600).formatted(
            .number.precision(.fractionLength(1))
        )
        return "\(hours) Std."
    }

    private var sampleCount: Int? {
        let counts = series.days.compactMap(\.sampleCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    private var chartDomain: ClosedRange<Date> {
        let start = series.hours.first?.date ?? .now
        let last = series.hours.last?.date ?? start
        let end = Calendar.autoupdatingCurrent.date(
            byAdding: .hour,
            value: 1,
            to: last
        ) ?? last.addingTimeInterval(3_600)
        return start...end
    }

    private var tint: Color {
        switch series.role {
        case .importedTotal: .blue
        case .estimated: .green
        case .iPhoneCategory: .cyan
        case .appleWatchCategory: .orange
        case .individualSource: .purple
        }
    }

    private var systemImage: String {
        switch series.role {
        case .importedTotal: "sum"
        case .estimated: "waveform.path.ecg.rectangle"
        case .iPhoneCategory: "iphone"
        case .appleWatchCategory: "applewatch"
        case .individualSource: "waveform.path.ecg"
        }
    }
}
