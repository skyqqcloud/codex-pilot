import Foundation
import SQLite3

@main
struct QuotaHistoryChecks {
    static func item(_ t: Double, _ five: Int?, reset: Double? = 20000, plan: String = "pro", duration: Int = 18000) -> QuotaObservation {
        QuotaObservation(time: t, plan: plan, five: five, week: 80,
            fiveSeconds: duration, weekSeconds: 604800, fiveReset: reset, weekReset: 80000)
    }
    static func series(_ items: [QuotaObservation], window: QuotaHistoryWindow = .primary, now: Double = 10000) -> QuotaHistorySeries {
        QuotaHistorySeries(items, window: window, since: 0, now: now)
    }
    static func main() async throws {
        checkSmoothCurves()
        checkIdleWindows()
        checkDisplayGaps()
        let items = (0...12).map { item(6400 + Double($0) * 300, 90 - $0 * 5) }
        let normal = series(items)
        precondition(normal.segments.count == 1 && normal.hourlyDrop(now: 10000) == 60)
        precondition(normal.firstLowObservation?.time == 10000)
        precondition(series([item(1, 50), item(2000, 30)]).segments.count == 2, "gap was bridged")
        precondition(series([item(1, 50), item(100, nil), item(200, 30)]).segments.count == 2, "missing quota was interpolated")
        precondition(series([item(1, 50), item(200, 100, reset: 40000)]).boundaries == [200], "explicit reset not marked")
        precondition(series([item(1, 50), item(200, 30, plan: "free", duration: 2592000)]).segments.count == 2, "plan change was joined")
        precondition(series([item(1, 50, reset: nil), item(200, 60, reset: nil)]).boundaries.isEmpty, "unknown upward correction called a reset")
        precondition(series(items.map { item($0.time, $0.five, reset: nil) }).hourlyDrop(now: 10000) == nil)
        precondition(normal.hourlyDrop(now: 12000) == nil, "stale samples presented as current rate")
        precondition(series([item(1, 50), item(10001, 5)]).points.count == 1, "future clock data included")
        precondition(series([item(1, nil)], window: .secondary).points.first?.remaining == 80)
        precondition(series([item(1, 20), item(2000, 10)]).firstLowObservation?.time == 2000, "low time crossed a gap")
        let clipped = QuotaHistorySeries(items, window: .primary, since: 9700, now: 10000)
        precondition(clipped.points.count == 2 && clipped.currentSegment.count == 13)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite3")
        let reader = QuotaHistoryReader(), identity = String(repeating: "a", count: 64)
        let empty = try await reader.load(identity: identity, url: url)
        precondition(empty.observations.isEmpty && !FileManager.default.fileExists(atPath: url.path), "read created a database")
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970
        let create = "CREATE TABLE observations(account TEXT,sampled_at REAL,plan TEXT,five INTEGER,week INTEGER,five_seconds INTEGER,week_seconds INTEGER,five_reset REAL,week_reset REAL,PRIMARY KEY(account,sampled_at)) WITHOUT ROWID;"
        precondition(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)
        func insert(_ key: String, _ t: Double, _ value: Int) {
            let sql = "INSERT INTO observations VALUES ('\(key)',\(t),'pro',\(value),NULL,18000,NULL,\(now+10000),NULL)"
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        insert(identity, now - 300, 60)
        insert(String(repeating: "b", count: 64), now - 200, 5)
        insert(identity, now - 31 * 86400, 100)
        let before = try Data(contentsOf: url)
        let first = try await reader.load(identity: identity, url: url)
        precondition(first.observations.count == 1 && first.observations[0].five == 60, "account or retention boundary leaked")
        let cached = try await reader.load(identity: identity, url: url)
        let after = try Data(contentsOf: url)
        precondition(cached.observations == first.observations && before == after, "read changed database")
        insert(identity, now - 1, 30)
        let updated = try await reader.load(identity: identity, url: url)
        precondition(updated.observations.count == 2 && updated.observations.last?.five == 30, "cached history missed a new observation")
        let fill = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<20002) INSERT OR IGNORE INTO observations SELECT '\(identity)',\(now)-x,'pro',50,NULL,18000,NULL,\(now+10000),NULL FROM n"
        precondition(sqlite3_exec(db, fill, nil, nil, nil) == SQLITE_OK)
        let start = Date()
        let large = try await reader.load(identity: identity, url: url)
        let cold = Date().timeIntervalSince(start)
        precondition(large.truncated && large.observations.count == 20000 && large.observations.last?.time == now-1,
                     "bounded reader lost the newest observation")
        let warmStart = Date()
        for _ in 0..<100 { _ = try await reader.load(identity: identity, url: url) }
        print("Quota history performance: 20,000 rows cold=\(cold)s; 100 cached reads=\(Date().timeIntervalSince(warmStart))s")
        print("Quota history: 17 checks passed: gap/reset/plan boundaries, first observation, hourly changes, read-only storage, cache invalidation and bounded large-history reads.")
    }

    static func checkDisplayGaps() {
        let input = [item(1, 50), item(2000, 40), item(2100, 30),
                     item(6000, 100, reset: 40000), item(7000, 90, reset: 40000)]
        let history = series(input)
        precondition(history.segments.map(\.count) == [1, 2, 1, 1] && history.currentSegment.count == 1,
                     "display continuity changed the sampling boundaries used by calculations")
        precondition(history.displaySegments.map(\.count) == [3, 2] && history.boundaries == [6000],
                     "same-cycle polling gaps were not joined or an actual reset was bridged")
        precondition(history.points.map(\.time) == input.map(\.time) &&
                     history.displaySegments.flatMap { $0 }.map(\.remaining) == [50,40,30,100,90],
                     "joining display gaps created or changed samples")
        let spans = history.displaySegments.flatMap { QuotaTrendCurve.make($0) }
        precondition(spans.count == 3 && spans.last?.end.time == 7000 &&
                     !spans.contains { $0.start.time < 6000 && $0.end.time >= 6000 },
                     "curve extended beyond a sample or crossed a real reset")
        precondition(series([item(1, 50), item(100, nil), item(2000, 30)]).displaySegments.count == 2,
                     "explicitly missing quota was joined")
        precondition(series([item(1, 50), item(2000, 30, plan: "free", duration: 2592000)]).displaySegments.count == 2,
                     "display crossed a plan or duration change")
        precondition(series([item(1, 50, reset: nil), item(2000, 60, reset: nil)]).displaySegments.count == 2,
                     "unknown upward quota change was joined")
        let gap = series([item(6400, 40), item(10000, 20)])
        precondition(gap.displaySegments.count == 1 && gap.hourlyDrop(now: 10000) == nil &&
                     gap.firstLowObservation?.time == 10000,
                     "display gap filled in hourly statistics or first-low timing")
        let clipped = QuotaHistorySeries(input, window: .primary, since: 2050, now: 10000)
        precondition(clipped.displaySegments.map(\.count) == [1,2] && clipped.displaySegments.flatMap { $0 }.allSatisfy { $0.time >= 2050 },
                     "display gap joining ignored the selected time range")
        let free = series([item(100, 100, reset: 2592100, plan: "free", duration: 2592000),
                           item(5000, 100, reset: 2597000, plan: "free", duration: 2592000)])
        precondition(free.segments.count == 2 && free.displaySegments.count == 1 && free.boundaries.isEmpty,
                     "idle Free quota was not joined across a long polling gap")
        print("Display gaps: same-cycle continuity, real reset/plan/missing quota boundaries, unchanged samples, selected range and unchanged hourly/low statistics passed.")
    }

    static func checkIdleWindows() {
        let duration = 30 * 86400
        func idle(_ time: Double, _ remaining: Int = 100, shift: Double = 0) -> QuotaObservation {
            item(time, remaining, reset: time + Double(duration) + shift, plan: "free", duration: duration)
        }
        // Replay the observed Free shape: reset advances with each successful
        // refresh while remaining stays at 100%, including integer rounding.
        let observations = (0...12).map { idle(6400 + Double($0) * 300, shift: $0 == 12 ? -1 : 0) }
        let continuous = series(observations)
        precondition(continuous.segments.count == 1 && continuous.boundaries.isEmpty,
                     "rolling unused quota was split into reset dots")
        precondition(QuotaTrendCurve.make(continuous.points).count == 12 && continuous.hourlyDrop(now: 10000) == 0,
                     "unchanged unused quota did not form a flat continuous history")
        let anchored = series([idle(100), idle(400, 95, shift: -150),
                               item(700, 90, reset: 250 + Double(duration), plan: "free", duration: duration)])
        precondition(anchored.segments.count == 1 && anchored.boundaries.isEmpty,
                     "first usage anchoring an idle deadline was called a reset")
        let actualReset = series([idle(100, 50), idle(400)])
        precondition(actualReset.segments.count == 2 && actualReset.boundaries == [400],
                     "a consumed window resetting to full quota was joined")
        let fullNearReset = series([idle(100, shift: -Double(duration) + 150), idle(400)])
        precondition(fullNearReset.segments.count == 2 && fullNearReset.boundaries == [400],
                     "a fixed deadline expiring at full quota was joined")
        precondition(series([idle(100), idle(2000)]).segments.count == 2, "idle window bridged missing polling")
        precondition(series([idle(100), item(200, nil, plan: "free", duration: duration), idle(400)]).segments.count == 2,
                     "idle window bridged missing quota")
        precondition(series([idle(100), idle(400, shift: 3600)]).segments.count == 2,
                     "an unrelated deadline jump was accepted as an idle horizon")
        precondition(series([idle(100), idle(400, shift: -1000)]).segments.count == 2,
                     "a backwards deadline jump was accepted as an idle horizon")
        let otherPlan = series([item(100, 100, reset: 18100), item(400, 100, reset: 18400)])
        precondition(otherPlan.segments.count == 1 && otherPlan.boundaries.isEmpty,
                     "idle horizon handling was incorrectly tied to a plan name")
        print("Idle windows: rolling full quota, first usage, fixed deadlines, genuine resets, gaps, missing quota and unrelated deadline jumps passed.")
    }

    static func checkSmoothCurves() {
        func points(_ values: [(Double, Int)]) -> [QuotaHistoryPoint] {
            values.map { QuotaHistoryPoint(time: $0.0, remaining: $0.1, duration: 18000, reset: 20000, plan: "pro") }
        }
        func ordinate(_ span: QuotaCurveSegment, _ u: Double) -> Double {
            let v = 1 - u
            return v*v*v*span.start.value + 3*v*v*u*span.control1.value + 3*v*u*u*span.control2.value + u*u*u*span.end.value
        }
        func verify(_ input: [QuotaHistoryPoint]) {
            let curve = QuotaTrendCurve.make(input)
            precondition(curve.count == input.count - 1)
            for (i, span) in curve.enumerated() {
                precondition(span.start.time == input[i].time && span.end.time == input[i+1].time &&
                    span.start.value == Double(input[i].remaining) && span.end.value == Double(input[i+1].remaining),
                    "smoothing moved an actual sample")
                let lower = min(span.start.value, span.end.value), upper = max(span.start.value, span.end.value)
                var previous = span.start.value
                for step in 0...50 {
                    let y = ordinate(span, Double(step)/50)
                    precondition(y >= lower - 1e-9 && y <= upper + 1e-9, "curve overshot actual quota values")
                    if upper == lower { precondition(abs(y - lower) < 1e-9, "flat quota developed a curve") }
                    else if span.end.value > span.start.value { precondition(y >= previous - 1e-9, "curve invented a decrease") }
                    else { precondition(y <= previous + 1e-9, "curve invented an increase") }
                    previous = y
                }
                if i > 0 {
                    let prior = curve[i-1]
                    let left = (prior.end.value-prior.control2.value)/(prior.end.time-prior.control2.time)
                    let right = (span.control1.value-span.start.value)/(span.control1.time-span.start.time)
                    precondition(abs(left-right) <= 1e-8*max(1,abs(left),abs(right)), "curve has a sharp tangent at a sample")
                }
            }
        }
        precondition(QuotaTrendCurve.make([]).isEmpty && QuotaTrendCurve.make(points([(0,50)])).isEmpty)
        precondition(QuotaTrendCurve.make(points([(0,50),(0,40)])).isEmpty, "duplicate timestamps caused an invalid curve")
        verify(points([(0,100),(300,83)]))
        verify(points([(0,100),(300,100),(600,100),(900,96),(1200,94),(1500,90),(1800,83)]))
        verify(points([(0,0),(1,0),(700,100),(701,100),(1500,0)]))
        verify(points([(0,90),(1,89),(800,10),(850,9),(1500,1)]))
        var seed: UInt64 = 0x43af9b
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
        for _ in 0..<500 {
            var t = 0.0, values: [(Double,Int)] = []
            for _ in 0..<8 { t += Double(next()%900+1); values.append((t,Int(next()%101))) }
            verify(points(values))
        }
        let separated = series([item(1,100),item(100,90),item(2000,80),item(2100,70),item(2200,100,reset:40000),item(2300,90,reset:40000)])
        let spans = separated.segments.flatMap { QuotaTrendCurve.make($0) }
        precondition(spans.count == 3 && spans.allSatisfy { $0.end.time-$0.start.time <= 100 },
                     "smoothing crossed a missing interval or reset")
        let large = points((0..<20000).map { (Double($0)*300, 100-($0%101)) })
        let started = Date()
        precondition(QuotaTrendCurve.make(large).count == 19999)
        print("Smooth curve: exact sample anchors, bounded monotone intervals, flat lines, continuous tangents, 500 irregular cases and gap/reset separation passed; 20,000-point geometry=\(Date().timeIntervalSince(started))s.")
    }
}
