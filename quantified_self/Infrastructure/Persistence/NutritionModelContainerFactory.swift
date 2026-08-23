import SwiftData

enum NutritionStoreMode: Equatable, Sendable {
    case local
    case cloudKit

    /// CloudKit stays opt-in at build time. Enabling this flag must be paired
    /// with the iCloud/CloudKit entitlement and a paid developer team.
    nonisolated static var current: NutritionStoreMode {
#if CLOUDKIT_ENABLED
        .cloudKit
#else
        .local
#endif
    }
}

@MainActor
enum NutritionModelContainerFactory {
    static func makeContainer(
        mode: NutritionStoreMode = .current,
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema(NutritionSchemaV1.models)
        let configuration: ModelConfiguration

        switch mode {
        case .local:
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: .none
            )
        case .cloudKit:
            configuration = ModelConfiguration(
                "NutritionCloud",
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: isStoredInMemoryOnly ? .none : .automatic
            )
        }

        return try ModelContainer(
            for: schema,
            migrationPlan: NutritionMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

enum CloudSyncReadinessIssue: Equatable, Sendable {
    case capabilityNotEnabled
    case fileBackedImagesNeedCloudAssetStorage
}

enum CloudSyncReadinessAudit {
    static func issues(
        mode: NutritionStoreMode,
        containsFileBackedImages: Bool
    ) -> [CloudSyncReadinessIssue] {
        var issues: [CloudSyncReadinessIssue] = []
        if mode != .cloudKit {
            issues.append(.capabilityNotEnabled)
        }
        if containsFileBackedImages {
            issues.append(.fileBackedImagesNeedCloudAssetStorage)
        }
        return issues
    }
}
