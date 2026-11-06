import Foundation
import SQLite3

struct QuotaObservation: Hashable {
    let time: Double
    let plan: String?
    let five: Int?
    let week: Int?
    let fiveSeconds: Int?
    let weekSeconds: Int?
    let fiveReset: Double?
    let weekReset: Double?
}

enum QuotaHistoryWindow: Hashable { case primary, secondary }

struct QuotaHistoryPoint: Hashable {
    let time: Double
    let remaining: Int
    let duration: Int?
    let reset: Double?
    let plan: String?

    func sameCycle(as other: Self) -> Bool {
        guard duration == other.duration, plan == other.plan else { return false }
        switch (reset, other.reset) {
        case let (a?, b?):
            if abs(a - b) <= 90 { return true }
            // An unused window can report a rolling full-duration horizon
            // (observed on Free), rather than a fixed reset deadline. Its
            // advance within this polling interval is not evidence of reset.
            // Also allow the first usage to anchor that previously idle window.
            guard other.remaining == 100, let duration, duration > 0,
                  abs(b - other.time - Double(duration)) <= 90 else { return false }
            let elapsed = time - other.time, advance = a - b
            return elapsed >= 0 && advance >= -90 && advance <= elapsed + 90 && a > time
        case (nil, nil): return remaining <= other.remaining
        default: return false
        }
    }
}

/// Observed segments keep polling gaps for calculations. Display segments join
/// those gaps within a cycle, without creating samples or crossing cycle/plan
/// changes or explicitly missing quota. Both stop at the last observation.
struct QuotaHistorySeries {
    static let maximumGap: Double = 15 * 60
    let segments: [[QuotaHistoryPoint]]
    let displaySegments: [[QuotaHistoryPoint]]
    let boundaries: [Double]
    let currentSegment: [QuotaHistoryPoint]

    init(_ observations: [QuotaObservation], window: QuotaHistoryWindow, since: Double, now: Double) {
        var segments: [[QuotaHistoryPoint]] = [], segment: [QuotaHistoryPoint] = []
        var displaySegments: [[QuotaHistoryPoint]] = [], displaySegment: [QuotaHistoryPoint] = []
        var boundaries: [Double] = []
        for item in observations where item.time <= now {
            let value = window == .primary ? item.five : item.week
            guard let value, (0...100).contains(value) else {
                if !segment.isEmpty { segments.append(segment); segment = [] }
                if !displaySegment.isEmpty { displaySegments.append(displaySegment); displaySegment = [] }
                continue
            }
            let point = QuotaHistoryPoint(time: item.time, remaining: value,
                duration: window == .primary ? item.fiveSeconds : item.weekSeconds,
                reset: window == .primary ? item.fiveReset : item.weekReset, plan: item.plan)
            if let previous = segment.last {
                let changed = !point.sameCycle(as: previous)
                if changed || point.time - previous.time > Self.maximumGap {
                    segments.append(segment); segment = []
                    // Unknown timing and an upward correction aren't evidence
                    // of reset. Only explicit window/plan/reset changes mark it.
                    if changed && (point.duration != previous.duration || point.plan != previous.plan ||
                        (point.reset != nil && previous.reset != nil)) { boundaries.append(point.time) }
                }
            }
            segment.append(point)
            if let previous = displaySegment.last, !point.sameCycle(as: previous) {
                displaySegments.append(displaySegment); displaySegment = []
            }
            displaySegment.append(point)
        }
        if !segment.isEmpty { segments.append(segment) }
        if !displaySegment.isEmpty { displaySegments.append(displaySegment) }
        self.currentSegment = segment
        self.segments = segments.map { $0.filter { $0.time >= since } }.filter { !$0.isEmpty }
        self.displaySegments = displaySegments.map { $0.filter { $0.time >= since } }.filter { !$0.isEmpty }
        self.boundaries = boundaries.filter { $0 >= since }
    }

    var points: [QuotaHistoryPoint] { segments.flatMap { $0 } }

    func hourlyDrop(now: Double) -> Int? {
        guard let last = currentSegment.last, now - last.time <= 600,
              let first = currentSegment.last(where: { $0.time <= now - 3600 }),
              now - 3600 - first.time <= 360, first.reset != nil,
              let reset = last.reset, reset > now else { return nil }
        return first.remaining - last.remaining
    }

    var firstLowObservation: QuotaHistoryPoint? {
        guard let last = currentSegment.last, last.remaining <= 30 else { return nil }
        return currentSegment.first { $0.remaining <= last.remaining }
    }
}

struct QuotaHistorySnapshot {
    var observations: [QuotaObservation] = []
    var truncated = false
}

/// No process, file watcher or timer. A read-only connection lives for one
/// on-demand read. Cache at most four accounts, invalidated by the file stamp.
actor QuotaHistoryReader {
    static let shared = QuotaHistoryReader()
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-swap/quota-history.sqlite3")
    }
    private var cache: [String: (stamp: String, data: QuotaHistorySnapshot)] = [:]
    private var order: [String] = []

    func load(identity: String, url: URL = QuotaHistoryReader.defaultURL, now: Double = Date().timeIntervalSince1970) throws -> QuotaHistorySnapshot {
        guard identity.count == 64, identity.allSatisfy({ $0.isHexDigit }) else { return QuotaHistorySnapshot() }
        guard FileManager.default.fileExists(atPath: url.path) else { return QuotaHistorySnapshot() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        // Date.description rounds to seconds and misses two same-size commits
        // within that second. Preserve the full filesystem timestamp instead.
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let stamp = "\(modified)-\(attributes[.size] ?? "")-\(attributes[.systemFileNumber] ?? "")"
        let key = url.path + ":" + identity
        if let saved = cache[key], saved.stamp == stamp { return saved.data }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        let sql = "SELECT sampled_at,plan,five,week,five_seconds,week_seconds,five_reset,week_reset FROM observations WHERE account=? AND sampled_at>=? AND sampled_at<=? ORDER BY sampled_at DESC LIMIT 20001"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, identity, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(statement, 2, now - 30 * 86400)
        sqlite3_bind_double(statement, 3, now)
        func integer(_ column: Int32) -> Int? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column) }
        var items: [QuotaObservation] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let plan = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            items.append(QuotaObservation(time: sqlite3_column_double(statement, 0), plan: plan,
                five: integer(2), week: integer(3), fiveSeconds: integer(4), weekSeconds: integer(5),
                fiveReset: double(6), weekReset: double(7)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        let result = QuotaHistorySnapshot(observations: Array(items.prefix(20000).reversed()), truncated: items.count > 20000)
        order.removeAll { $0 == key }; order.append(key)
        cache[key] = (stamp, result)
        if order.count > 4 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
}
