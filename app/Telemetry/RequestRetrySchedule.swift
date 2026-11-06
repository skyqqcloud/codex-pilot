import Foundation

/// Finite, per-call retries. New traffic never resets an older call's budget.
/// A single batch may run at most once every 15 seconds; idle state has no timer.
struct RequestRetrySchedule {
    private struct Entry { var attempt = 0; var next: Double }
    private var entries: [String: Entry] = [:]
    private var lastAttempt = -Double.infinity
    static let lifetime: Double = 120
    static let minimumInterval: Double = 15
    private let delays: [Double] = [2, 10, 60]

    mutating func update(unresolved: Set<String>, attempted: Set<String>, now: Double) {
        entries = entries.filter { unresolved.contains($0.key) }
        if !attempted.isEmpty { lastAttempt = now }
        for id in unresolved {
            var entry = entries[id] ?? Entry(next: now + delays[0])
            if attempted.contains(id) {
                entry.attempt += 1
                entry.next = entry.attempt < delays.count ? now + delays[entry.attempt] : .infinity
            }
            entries[id] = entry
        }
    }
    var next: Double? {
        guard let first = entries.values.map(\.next).min(), first.isFinite else { return nil }
        return max(first, lastAttempt + Self.minimumInterval)
    }
    mutating func noteRead(now: Double) { lastAttempt = now }
    func due(now: Double, piggyback: Bool = false) -> Set<String> {
        guard piggyback || now >= lastAttempt + Self.minimumInterval else { return [] }
        return Set(entries.filter { $0.value.next <= now }.keys)
    }
}
