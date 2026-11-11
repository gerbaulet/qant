import SwiftUI

struct AppleHealthSettingsSection: View {
    @Environment(HealthMetricsModel.self) private var healthMetrics

    var body: some View {
        Section {
            LabeledContent("Energiedaten") {
                Label(energyStatusTitle, systemImage: statusSystemImage(healthMetrics.energyStatus))
                    .foregroundStyle(statusColor(healthMetrics.energyStatus))
            }

            Button {
                requestAccess()
            } label: {
                HStack {
                    Text(healthMetrics.hasRequestedEnergyAccess ? "Energiedaten aktualisieren" : "Apple Health verbinden")
                    Spacer()
                    if healthMetrics.isLoadingEnergy {
                        ProgressView()
                    }
                }
            }
            .disabled(healthMetrics.isLoadingEnergy)
            .accessibilityIdentifier("settings.healthEnergyAccess")

            LabeledContent("Gewichtsverlauf") {
                Label(weightStatusTitle, systemImage: statusSystemImage(healthMetrics.weightStatus))
                    .foregroundStyle(statusColor(healthMetrics.weightStatus))
            }

            Button {
                requestWeightAccess()
            } label: {
                HStack {
                    Text(healthMetrics.hasRequestedWeightAccess ? "Gewichtsdaten aktualisieren" : "Gewichtsdaten verbinden")
                    Spacer()
                    if healthMetrics.isLoadingWeight {
                        ProgressView()
                    }
                }
            }
            .disabled(healthMetrics.isLoadingWeight)
            .accessibilityIdentifier("settings.healthWeightAccess")

            Toggle(
                "Persönliche Modellkalibrierung",
                isOn: Binding(
                    get: { healthMetrics.personalCalibrationEnabled },
                    set: { healthMetrics.personalCalibrationEnabled = $0 }
                )
            )
            .disabled(!healthMetrics.hasRequestedWeightAccess)
            .accessibilityIdentifier("settings.personalCalibration")

            switch healthMetrics.energyStatus {
            case .limited(let since):
                Text("Apple Health stellt Quant Energiedaten ab \(since.formatted(date: .abbreviated, time: .omitted)) bereit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .noData where healthMetrics.hasRequestedEnergyAccess:
                Text("Keine Energiedaten verfügbar. Prüfe in Apple Health, ob Quant Zugriff hat und ob Aktivitäts- und Ruheenergie vorhanden sind.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Die Energiedaten konnten nicht geladen werden. Versuche es später erneut.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }

            switch healthMetrics.weightStatus {
            case .noData where healthMetrics.hasRequestedWeightAccess:
                Text("Keine Gewichtsdaten verfügbar. Prüfe in Apple Health, ob Quant Zugriff hat und Gewichtswerte vorhanden sind.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Die Gewichtsdaten konnten nicht geladen werden. Versuche es später erneut.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Quant liest Aktivitäts-, Ruhe- und Gewichtsdaten nur mit deiner Zustimmung. Die persönliche Kalibrierung vergleicht den Gewichtstrend mit der Energiebilanz, verändert aber keine Mahlzeiten oder Ziele. Alle Health-Daten bleiben auf diesem Gerät und werden weder an OpenRouter gesendet noch in iCloud gespeichert.")
        }
    }

    private var energyStatusTitle: String {
        switch healthMetrics.energyStatus {
        case .notRequested: "Nicht verbunden"
        case .loading: "Wird geladen"
        case .available, .limited: "Verfügbar"
        case .noData: "Keine Daten"
        case .unavailable: "Nicht verfügbar"
        case .failed: "Laden fehlgeschlagen"
        }
    }

    private var weightStatusTitle: String {
        switch healthMetrics.weightStatus {
        case .notRequested: "Nicht verbunden"
        case .loading: "Wird geladen"
        case .available, .limited: "Verfügbar"
        case .noData: "Keine Daten"
        case .unavailable: "Nicht verfügbar"
        case .failed: "Laden fehlgeschlagen"
        }
    }

    private func statusSystemImage(_ status: HealthDataStatus) -> String {
        switch status {
        case .available, .limited: "checkmark.circle.fill"
        case .loading: "arrow.clockwise.circle"
        case .failed: "exclamationmark.triangle.fill"
        default: "heart.text.square"
        }
    }

    private func statusColor(_ status: HealthDataStatus) -> Color {
        switch status {
        case .available, .limited: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func requestAccess() {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -365, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        Task {
            if healthMetrics.hasRequestedEnergyAccess {
                await healthMetrics.loadEnergy(
                    from: start,
                    to: end,
                    calendar: calendar,
                    force: true
                )
            } else {
                await healthMetrics.requestEnergyAccess(
                    from: start,
                    to: end,
                    calendar: calendar
                )
            }
        }
    }

    private func requestWeightAccess() {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -120, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        Task {
            if healthMetrics.hasRequestedWeightAccess {
                await healthMetrics.loadWeights(from: start, to: end, force: true)
            } else {
                await healthMetrics.requestWeightAccess(from: start, to: end)
            }
        }
    }
}
