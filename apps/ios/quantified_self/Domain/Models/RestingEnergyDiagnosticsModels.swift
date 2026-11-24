import Foundation

enum RestingEnergyDiagnosticSourceKind: String, Sendable, Equatable {
    case iPhone
    case appleWatch
    case other
}

enum RestingEnergyDiagnosticSeriesRole: String, Sendable, Equatable {
    case importedTotal
    case estimated
    case iPhoneCategory
    case appleWatchCategory
    case individualSource
}

struct RestingEnergyDiagnosticImportedDay: Sendable, Equatable {
    let date: Date
    let kilocalories: Double?
    let coveredDuration: TimeInterval?
    let estimatedKilocalories: Double
    let estimatedDuration: TimeInterval

    init(
        date: Date,
        kilocalories: Double?,
        coveredDuration: TimeInterval?,
        estimatedKilocalories: Double = 0,
        estimatedDuration: TimeInterval = 0
    ) {
        self.date = date
        self.kilocalories = kilocalories
        self.coveredDuration = coveredDuration
        self.estimatedKilocalories = estimatedKilocalories
        self.estimatedDuration = estimatedDuration
    }
}

struct RestingEnergyDiagnosticImportedHour: Sendable, Equatable {
    let date: Date
    let kilocalories: Double?
    let coveredDuration: TimeInterval?
    let estimatedKilocalories: Double
    let estimatedDuration: TimeInterval

    init(
        date: Date,
        kilocalories: Double?,
        coveredDuration: TimeInterval?,
        estimatedKilocalories: Double = 0,
        estimatedDuration: TimeInterval = 0
    ) {
        self.date = date
        self.kilocalories = kilocalories
        self.coveredDuration = coveredDuration
        self.estimatedKilocalories = estimatedKilocalories
        self.estimatedDuration = estimatedDuration
    }
}

struct RestingEnergyDiagnosticSample: Sendable, Equatable {
    let interval: DateInterval
    let kilocalories: Double
    let sourceID: String
    let sourceTitle: String
    let sourceDetails: String?
    let sourceKind: RestingEnergyDiagnosticSourceKind
}

struct RestingEnergyDiagnosticDay: Identifiable, Sendable, Equatable {
    var id: Date { date }

    let date: Date
    let kilocalories: Double?
    let coveredDuration: TimeInterval?
    let sampleCount: Int?
}

struct RestingEnergyDiagnosticHour: Identifiable, Sendable, Equatable {
    var id: Date { date }

    let date: Date
    let kilocalories: Double?
    let coveredDuration: TimeInterval?
}

struct RestingEnergyDiagnosticSeries: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let details: String?
    let role: RestingEnergyDiagnosticSeriesRole
    let days: [RestingEnergyDiagnosticDay]
    let hours: [RestingEnergyDiagnosticHour]
}

struct RestingEnergyDiagnosticsSnapshot: Sendable, Equatable {
    let interval: DateInterval
    let series: [RestingEnergyDiagnosticSeries]
}
