import Foundation
import Testing
@testable import Quant

@MainActor
struct DevelopmentSampleFixturesTests {
    @Test("Development fixtures cover release UI states without networking")
    func coversRoadmapScenarios() {
        let meals = DevelopmentSampleFixtures.meals()
        let states = Set(meals.map(\.analysisState))

        #expect(states.isSuperset(of: [.pending, .needsClarification, .failed, .confirmed]))
        #expect(meals.contains { $0.images.count > 1 })
        #expect(meals.contains { $0.analysisRevisions.count > 1 })
        #expect(meals.contains { meal in
            meal.analysisRevisions.contains { $0.trigger == .correction }
        })
        #expect(Set(meals.map { Calendar.current.startOfDay(for: $0.timestamp) }).count > 4)

        let goals = DevelopmentSampleFixtures.goals()
        #expect(goals.count == 2)
        #expect(goals.first?.validUntil == goals.last?.validFrom)
    }
}
