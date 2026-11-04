import Foundation
import Observation

struct LiveAnalysisCall: Identifiable, Equatable {
    let id: Int
    let sampleNumber: Int?
    let attemptNumber: Int
    let requestedAt: Date
    var requestStartedAt: Date?
    var responseStartedAt: Date?
    var firstContentAt: Date?
    var responseCompletedAt: Date?
    var streamedJSON = ""
    var result: AnalysisCallSummary?
}

struct MealAnalysisProgress: Equatable {
    var startedAt: Date = .now
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
    private static let maximumStreamCharacterCount = 64_000
    private(set) var analyses: [UUID: MealAnalysisProgress] = [:]

    func begin(_ mealID: UUID, at date: Date = .now) {
        analyses[mealID] = MealAnalysisProgress(startedAt: date)
    }
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

    func recordStreamEvent(
        _ event: NutritionAnalysisStreamEvent,
        to callID: Int,
        for mealID: UUID,
        at date: Date
    ) {
        guard
            let index = analyses[mealID]?.calls.firstIndex(where: { $0.id == callID })
        else { return }

        switch event {
        case .requestStarted:
            analyses[mealID]?.calls[index].requestStartedAt = date
        case .responseStarted:
            analyses[mealID]?.calls[index].responseStartedAt = date
        case let .contentDelta(content):
            guard !content.isEmpty else { return }
            if analyses[mealID]?.calls[index].firstContentAt == nil {
                analyses[mealID]?.calls[index].firstContentAt = date
            }
            appendStreamContent(content, at: index, for: mealID)
        case .responseCompleted:
            analyses[mealID]?.calls[index].responseCompletedAt = date
        }
    }

    private func appendStreamContent(_ content: String, at index: Int, for mealID: UUID) {
        analyses[mealID]?.calls[index].streamedJSON += content
        if let count = analyses[mealID]?.calls[index].streamedJSON.count,
           count > Self.maximumStreamCharacterCount {
            analyses[mealID]?.calls[index].streamedJSON.removeFirst(
                count - Self.maximumStreamCharacterCount
            )
        }
    }
}
