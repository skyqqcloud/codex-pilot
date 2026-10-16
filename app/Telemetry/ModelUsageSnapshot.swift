import Foundation

struct ModelUsageSnapshot: Sendable {
    let aggregate: UsageSnapshot
    let models: [String: UsageSnapshot]

    var modelNames: [String] { models.keys.sorted() }

    func metrics(seconds: Int, model: String) -> WindowMetrics {
        let snapshot = model.isEmpty ? aggregate : models[model]
        guard let snapshot else { return .empty(windowSeconds: seconds) }
        return seconds == 300 ? snapshot.fiveMinutes : snapshot.oneMinute
    }

    func activeSessions(model: String) -> Int {
        (model.isEmpty ? aggregate : models[model])?.activeSessions ?? 0
    }

    static func empty(at now: Date = Date(), status: CollectionStatus = .ready) -> Self {
        Self(aggregate: .empty(at: now, status: status), models: [:])
    }
}
