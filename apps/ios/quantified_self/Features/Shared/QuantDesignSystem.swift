import SwiftUI

enum QuantLayout {
    static let pageInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 18
    static let cardCornerRadius: CGFloat = 18
    static let heroCardPadding: CGFloat = 20
    static let heroCardCornerRadius: CGFloat = 22
}

enum QuantCardStyle {
    case standard
    case hero

    var padding: CGFloat {
        switch self {
        case .standard: QuantLayout.cardPadding
        case .hero: QuantLayout.heroCardPadding
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard: QuantLayout.cardCornerRadius
        case .hero: QuantLayout.heroCardCornerRadius
        }
    }
}

struct QuantCard<Content: View>: View {
    private let style: QuantCardStyle
    private let content: Content

    init(
        style: QuantCardStyle = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        content
            .padding(style.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: style.cornerRadius))
    }
}

struct MealStatusBadge: View {
    let state: AnalysisState

    var body: some View {
        Label(state.presentationTitle, systemImage: state.presentationSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.presentationColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.presentationColor.opacity(0.12), in: .capsule)
            .accessibilityIdentifier("meal.status.\(state.rawValue)")
    }
}

struct MealSummaryRow: View {
    let id: UUID
    let name: String?
    let timestamp: Date
    let energyKilocalories: Double?
    let analysisState: AnalysisState
    let isProvisional: Bool
    let thumbnailStorageKey: String?
    let showsCardBackground: Bool
    let onOpen: () -> Void
    let onRetry: () -> Void

    init(
        id: UUID,
        name: String?,
        timestamp: Date,
        energyKilocalories: Double?,
        analysisState: AnalysisState,
        isProvisional: Bool,
        thumbnailStorageKey: String?,
        showsCardBackground: Bool = false,
        onOpen: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.energyKilocalories = energyKilocalories
        self.analysisState = analysisState
        self.isProvisional = isProvisional
        self.thumbnailStorageKey = thumbnailStorageKey
        self.showsCardBackground = showsCardBackground
        self.onOpen = onOpen
        self.onRetry = onRetry
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    StoredMealThumbnailView(storageKey: thumbnailStorageKey)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName)
                            .font(.headline)
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            Text(timestamp, format: .dateTime.hour().minute())
                                .font(.caption)
                            if analysisState != .confirmed {
                                MealStatusBadge(state: analysisState)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if let energyKilocalories {
                        Text("\(isProvisional ? "~" : "")\(wholeNumber(energyKilocalories)) kcal")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet die Details dieser Mahlzeit")
            .accessibilityIdentifier("meal.open.\(id.uuidString)")

            if analysisState == .failed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Analyse erneut versuchen")
                .accessibilityIdentifier("meal.retry.\(id.uuidString)")
            }
        }
        .padding(showsCardBackground ? 14 : 0)
        .background {
            if showsCardBackground {
                RoundedRectangle(cornerRadius: QuantLayout.cardCornerRadius)
                    .fill(.background)
            }
        }
    }

    private var displayName: String {
        guard let name, !name.isEmpty else { return "Mahlzeit" }
        return name
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

extension AnalysisState {
    var presentationTitle: LocalizedStringKey {
        switch self {
        case .awaitingDescription: "Beschreibung fehlt"
        case .pending: "Ausstehend"
        case .analyzing: "Wird analysiert"
        case .needsClarification: "Rückfrage"
        case .awaitingConfirmation, .confirmed: "Bestätigt"
        case .failed: "Fehlgeschlagen"
        }
    }

    var presentationSystemImage: String {
        switch self {
        case .awaitingDescription: "text.bubble"
        case .pending: "clock"
        case .analyzing: "sparkles"
        case .needsClarification: "questionmark.circle"
        case .awaitingConfirmation, .confirmed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var presentationColor: Color {
        switch self {
        case .awaitingDescription, .needsClarification: .orange
        case .pending, .analyzing: .secondary
        case .awaitingConfirmation, .confirmed: .green
        case .failed: .red
        }
    }
}
