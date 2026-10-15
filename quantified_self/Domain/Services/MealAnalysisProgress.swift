import Foundation
import Observation

struct LiveAnalysisCall: Identifiable, Equatable {
    let id: Int
    let sampleNumber: Int?
    let attemptNumber: Int
    let requestedAt: Date
    var result: AnalysisCallSummary?
}

struct MealAnalysisProgress: Equatable {
    var phase = "Bilder werden vorbereitet und Verpackungstext wird gelesen …"
    var calls: [LiveAnalysisCall] = []

    var runningCount: Int { calls.filter { $0.result == nil }.count }
    var succeededCount: Int { calls.filter { $0.result?.status == .succeeded }.count }
    var failedCount: Int { calls.filter { $0.result?.status == .failed }.count }
}

/// Ephemeral state shared by capture, history, and review coordinators. No user data is persisted here.
@MainActor
@Observable
final class MealAnalysisProgressStore {
    static let shared = MealAnalysisProgressStore()
    private(set) var analyses: [UUID: MealAnalysisProgress] = [:]

    func begin(_ mealID: UUID) { analyses[mealID] = MealAnalysisProgress() }
    func end(_ mealID: UUID) { analyses[mealID] = nil }
    func setPhase(_ phase: String, for mealID: UUID) { analyses[mealID]?.phase = phase }

    func startCall(for mealID: UUID, sampleNumber: Int?, attemptNumber: Int, at date: Date) -> Int {
        let number = (analyses[mealID]?.calls.count ?? 0) + 1
        analyses[mealID]?.calls.append(LiveAnalysisCall(
            id: number, sampleNumber: sampleNumber, attemptNumber: attemptNumber, requestedAt: date
        ))
        analyses[mealID]?.phase = "Antworten werden angefordert und geprüft …"
        return number
    }

    func finishCall(_ summary: AnalysisCallSummary, for mealID: UUID) {
        guard let index = analyses[mealID]?.calls.firstIndex(where: { $0.id == summary.callNumber }) else { return }
        analyses[mealID]?.calls[index].result = summary
    }
}
