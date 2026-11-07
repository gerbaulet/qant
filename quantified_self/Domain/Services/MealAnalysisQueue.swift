import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class MealAnalysisQueue {
    static let shared = MealAnalysisQueue()
    private static let recoveryCorrection = "Nährwerte vollständig neu berechnen"

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func resumePendingAnalyses(
        in context: ModelContext,
        provider: (any NutritionAnalysisProviding)? = nil,
        imageStorage: (any ImageStorageProviding)? = nil
    ) throws {
        let resolvedProvider = provider ?? OpenRouterNutritionAnalysisService()
        let resolvedImageStorage = imageStorage ?? FileImageStorage()
        let meals = try context.fetch(FetchDescriptor<Meal>())
        var pendingAnalyses = try context.fetch(FetchDescriptor<PendingMealAnalysis>())
        let mealIDs = Set(meals.map(\.id))

        for pendingAnalysis in pendingAnalyses where !mealIDs.contains(pendingAnalysis.mealID) {
            context.delete(pendingAnalysis)
        }
        pendingAnalyses.removeAll { !mealIDs.contains($0.mealID) }

        let queuedMealIDs = Set(pendingAnalyses.map(\.mealID))
        for meal in meals where
            (meal.analysisState == .pending || meal.analysisState == .analyzing) &&
            !queuedMealIDs.contains(meal.id) {
            let pendingAnalysis = PendingMealAnalysis(
                mealID: meal.id,
                createdAt: meal.modifiedAt,
                trigger: meal.activeRevision == nil ? .initial : .retry
            )
            context.insert(pendingAnalysis)
            pendingAnalyses.append(pendingAnalysis)
        }
        try context.save()

        for pendingAnalysis in pendingAnalyses {
            start(
                pendingAnalysis,
                in: context,
                provider: resolvedProvider,
                imageStorage: resolvedImageStorage
            )
        }
    }

    func analyze(
        _ meal: Meal,
        in context: ModelContext,
        provider: (any NutritionAnalysisProviding)? = nil,
        imageStorage: (any ImageStorageProviding)? = nil
    ) async {
        let resolvedProvider = provider ?? OpenRouterNutritionAnalysisService()
        let resolvedImageStorage = imageStorage ?? FileImageStorage()
        guard meal.analysisState == .pending || meal.analysisState == .failed || meal.analysisState == .analyzing else {
            return
        }
        if let existing = pendingAnalysis(for: meal.id, in: context) {
            await start(existing, in: context, provider: resolvedProvider, imageStorage: resolvedImageStorage).value
            return
        }

        let failedCorrection = meal.analysisState == .failed ? latestFailedCorrection(for: meal) : nil
        let pendingAnalysis = PendingMealAnalysis(
            mealID: meal.id,
            trigger: failedCorrection == nil
                ? (meal.analysisState == .failed ? .retry : .initial)
                : .correction,
            userCorrection: failedCorrection
        )
        guard persist(pendingAnalysis, in: context) else { return }
        await start(pendingAnalysis, in: context, provider: resolvedProvider, imageStorage: resolvedImageStorage).value
    }

    func answerClarification(
        _ answer: String,
        for meal: Meal,
        in context: ModelContext,
        provider: (any NutritionAnalysisProviding)? = nil,
        imageStorage: (any ImageStorageProviding)? = nil
    ) async {
        let resolvedProvider = provider ?? OpenRouterNutritionAnalysisService()
        let resolvedImageStorage = imageStorage ?? FileImageStorage()
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            meal.analysisState == .needsClarification,
            meal.activeRevision != nil,
            meal.clarificationCount < MealAnalysisCoordinator.maximumClarificationCount,
            !trimmedAnswer.isEmpty,
            pendingAnalysis(for: meal.id, in: context) == nil
        else { return }

        let pendingAnalysis = PendingMealAnalysis(
            mealID: meal.id,
            trigger: .clarification,
            clarificationAnswer: trimmedAnswer
        )
        guard persist(pendingAnalysis, in: context) else { return }
        await start(pendingAnalysis, in: context, provider: resolvedProvider, imageStorage: resolvedImageStorage).value
    }

    func correct(
        _ correction: String,
        for meal: Meal,
        in context: ModelContext,
        provider: (any NutritionAnalysisProviding)? = nil,
        imageStorage: (any ImageStorageProviding)? = nil
    ) async {
        let resolvedProvider = provider ?? OpenRouterNutritionAnalysisService()
        let resolvedImageStorage = imageStorage ?? FileImageStorage()
        let trimmedCorrection = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            meal.analysisState == .awaitingConfirmation || meal.analysisState == .confirmed,
            meal.activeRevision != nil,
            !trimmedCorrection.isEmpty,
            pendingAnalysis(for: meal.id, in: context) == nil
        else { return }

        let pendingAnalysis = PendingMealAnalysis(
            mealID: meal.id,
            trigger: .correction,
            userCorrection: trimmedCorrection
        )
        guard persist(pendingAnalysis, in: context) else { return }
        await start(pendingAnalysis, in: context, provider: resolvedProvider, imageStorage: resolvedImageStorage).value
    }

    func repairIncompleteAnalyses(
        for date: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        in context: ModelContext,
        provider: (any NutritionAnalysisProviding)? = nil,
        imageStorage: (any ImageStorageProviding)? = nil
    ) async {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return }
        let resolvedProvider = provider ?? OpenRouterNutritionAnalysisService()
        let resolvedImageStorage = imageStorage ?? FileImageStorage()
        let meals = ((try? context.fetch(FetchDescriptor<Meal>())) ?? [])
            .filter { meal in
                guard
                    meal.mealState != .archived,
                    meal.timestamp >= day.start,
                    meal.timestamp < day.end,
                    meal.analysisState == .confirmed,
                    let revision = meal.activeRevision,
                    revision.status == .confirmed
                else { return false }
                return RevisionNutritionRecovery.needsRepair(revision)
            }
            .sorted { $0.timestamp < $1.timestamp }

        for meal in meals {
            guard pendingAnalysis(for: meal.id, in: context) == nil else { continue }
            let pendingAnalysis = PendingMealAnalysis(
                mealID: meal.id,
                trigger: .correction,
                userCorrection: Self.recoveryCorrection
            )
            guard persist(pendingAnalysis, in: context) else { continue }
            await start(
                pendingAnalysis,
                in: context,
                provider: resolvedProvider,
                imageStorage: resolvedImageStorage
            ).value
        }
    }

    func cancel(for mealID: UUID, in context: ModelContext) {
        let matching = pendingAnalyses(in: context).filter { $0.mealID == mealID }
        for pendingAnalysis in matching {
            tasks[pendingAnalysis.id]?.cancel()
            tasks[pendingAnalysis.id] = nil
            context.delete(pendingAnalysis)
        }
        try? context.save()
    }

    @discardableResult
    private func start(
        _ pendingAnalysis: PendingMealAnalysis,
        in context: ModelContext,
        provider: any NutritionAnalysisProviding,
        imageStorage: any ImageStorageProviding
    ) -> Task<Void, Never> {
        if let task = tasks[pendingAnalysis.id] { return task }
        let jobID = pendingAnalysis.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(
                jobID: jobID,
                in: context,
                provider: provider,
                imageStorage: imageStorage
            )
        }
        tasks[jobID] = task
        return task
    }

    private func execute(
        jobID: UUID,
        in context: ModelContext,
        provider: any NutritionAnalysisProviding,
        imageStorage: any ImageStorageProviding
    ) async {
        defer { tasks[jobID] = nil }
        guard
            let pendingAnalysis = pendingAnalyses(in: context).first(where: { $0.id == jobID }),
            let meal = (try? context.fetch(FetchDescriptor<Meal>()))?.first(where: { $0.id == pendingAnalysis.mealID })
        else { return }

        await MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: imageStorage
        ).resume(pendingAnalysis, for: meal)

        guard !Task.isCancelled else { return }
        context.delete(pendingAnalysis)
        try? context.save()
    }

    private func persist(_ pendingAnalysis: PendingMealAnalysis, in context: ModelContext) -> Bool {
        context.insert(pendingAnalysis)
        do {
            try context.save()
            return true
        } catch {
            context.delete(pendingAnalysis)
            return false
        }
    }

    private func pendingAnalysis(for mealID: UUID, in context: ModelContext) -> PendingMealAnalysis? {
        pendingAnalyses(in: context).first { $0.mealID == mealID }
    }

    private func pendingAnalyses(in context: ModelContext) -> [PendingMealAnalysis] {
        (try? context.fetch(FetchDescriptor<PendingMealAnalysis>())) ?? []
    }

    private func latestFailedCorrection(for meal: Meal) -> String? {
        meal.analysisRevisions
            .filter { $0.status == .failed && $0.trigger == .correction }
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .userCorrection
    }
}
