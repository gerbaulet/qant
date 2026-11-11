import SwiftUI

struct AppleHealthSettingsSection: View {
    @Environment(HealthMetricsModel.self) private var healthMetrics

    var body: some View {
        Section {
            LabeledContent("Energiedaten") {
                Label(statusTitle, systemImage: statusSystemImage)
                    .foregroundStyle(statusColor)
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
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Quant liest Aktivitäts- und Ruheenergie nur mit deiner Zustimmung. Die Daten bleiben auf diesem Gerät und werden weder an OpenRouter gesendet noch in iCloud gespeichert. Du kannst den Zugriff jederzeit in Apple Health ändern.")
        }
    }

    private var statusTitle: String {
        switch healthMetrics.energyStatus {
        case .notRequested: "Nicht verbunden"
        case .loading: "Wird geladen"
        case .available, .limited: "Verfügbar"
        case .noData: "Keine Daten"
        case .unavailable: "Nicht verfügbar"
        case .failed: "Laden fehlgeschlagen"
        }
    }

    private var statusSystemImage: String {
        switch healthMetrics.energyStatus {
        case .available, .limited: "checkmark.circle.fill"
        case .loading: "arrow.clockwise.circle"
        case .failed: "exclamationmark.triangle.fill"
        default: "heart.text.square"
        }
    }

    private var statusColor: Color {
        switch healthMetrics.energyStatus {
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
}
