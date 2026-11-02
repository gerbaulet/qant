import Foundation
import Testing
@testable import Quant

@MainActor
struct MealAnalysisProgressTests {
    @Test("Concurrent responses keep request order and expose failures and retries immediately")
    func tracksConcurrentResponsesAndRetries() {
        let store = MealAnalysisProgressStore()
        let mealID = UUID()
        let otherMealID = UUID()
        let date = Date(timeIntervalSince1970: 123)
        store.begin(mealID)
        store.begin(otherMealID)
        #expect(store.analyses[mealID]?.calls.isEmpty == true)
        let first = store.startCall(for: mealID, sampleNumber: 2, attemptNumber: 1, at: date)
        let second = store.startCall(for: mealID, sampleNumber: 3, attemptNumber: 1, at: date)
        store.recordStreamEvent(.requestStarted, to: first, for: mealID, at: date.addingTimeInterval(1))
        store.recordStreamEvent(.responseStarted, to: first, for: mealID, at: date.addingTimeInterval(3))
        store.recordStreamEvent(.contentDelta("{\"meal"), to: first, for: mealID, at: date.addingTimeInterval(5))
        store.recordStreamEvent(.contentDelta("Name\":\"Test\"}"), to: first, for: mealID, at: date.addingTimeInterval(6))
        store.recordStreamEvent(.responseCompleted, to: first, for: mealID, at: date.addingTimeInterval(7))
        store.recordStreamEvent(.contentDelta("ignored"), to: first, for: otherMealID, at: date)
        #expect(store.analyses[mealID]?.calls.first?.requestStartedAt == date.addingTimeInterval(1))
        #expect(store.analyses[mealID]?.calls.first?.responseStartedAt == date.addingTimeInterval(3))
        #expect(store.analyses[mealID]?.calls.first?.firstContentAt == date.addingTimeInterval(5))
        #expect(store.analyses[mealID]?.calls.first?.responseCompletedAt == date.addingTimeInterval(7))
        #expect(store.analyses[mealID]?.calls.first?.streamedJSON == #"{"mealName":"Test"}"#)
        #expect(store.analyses[otherMealID]?.calls.isEmpty == true)
        #expect(store.analyses[mealID]?.runningCount == 2)
        store.finishCall(summary(second, status: .failed), for: mealID)
        #expect(store.analyses[mealID]?.failedCount == 1)
        #expect(store.analyses[mealID]?.runningCount == 1)
        #expect(store.analyses[mealID]?.calls.last?.result?.errorMessage == "Ungültige Antwort")
        let retry = store.startCall(for: mealID, sampleNumber: 3, attemptNumber: 2, at: date)
        store.finishCall(summary(first, status: .succeeded), for: mealID)
        #expect(store.analyses[mealID]?.succeededCount == 1)
        #expect(store.analyses[mealID]?.calls.first?.result?.energyKilocalories == 640)
        #expect(store.analyses[mealID]?.calls.map(\.id) == [first, second, retry])
        #expect(store.analyses[mealID]?.calls.last?.attemptNumber == 2)
        #expect(store.analyses[otherMealID]?.calls.isEmpty == true)
        store.setPhase("Auf Netzwerk warten", for: mealID)
        #expect(store.analyses[mealID]?.phase == "Auf Netzwerk warten")
        store.end(mealID)
        #expect(store.analyses[mealID] == nil)
        #expect(store.analyses[otherMealID] != nil)
        store.begin(mealID)
        #expect(store.startCall(for: mealID, sampleNumber: nil, attemptNumber: 1, at: date) == 1)
    }

    private func summary(_ number: Int, status: AnalysisCallStatus) -> AnalysisCallSummary {
        AnalysisCallSummary(
            callNumber: number, sampleNumber: nil, attemptNumber: 1, status: status,
            modelIdentifier: "example/model", providerIdentifier: nil,
            energyKilocalories: status == .succeeded ? 640 : nil,
            errorMessage: status == .failed ? "Ungültige Antwort" : nil
        )
    }
}
