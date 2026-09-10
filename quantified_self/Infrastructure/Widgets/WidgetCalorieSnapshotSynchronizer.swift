import WidgetKit

struct WidgetCalorieSnapshotSynchronizer {
    private let store: WidgetCalorieSnapshotStore

    init(store: WidgetCalorieSnapshotStore = WidgetCalorieSnapshotStore()) {
        self.store = store
    }

    func synchronize(_ snapshot: WidgetCalorieSnapshot) {
        guard store.save(snapshot) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: QuantWidgetConfiguration.widgetKind)
    }
}
