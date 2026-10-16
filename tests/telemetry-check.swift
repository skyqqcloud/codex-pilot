import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}
private func jsonLine(_ type: String, _ payload: [String: Any], _ date: Date) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: [
        "timestamp": date.formatted(.iso8601), "type": type, "payload": payload
    ], options: [.sortedKeys])
    data.append(10)
    return data
}
private func usage(_ input: Int, _ output: Int, cached: Int = 0, reasoning: Int = 0) -> [String: Any] {
    ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
     "reasoning_output_tokens": reasoning, "total_tokens": input + output]
}
private func token(_ total: [String: Any], _ last: [String: Any]?, at date: Date) throws -> Data {
    var info: [String: Any] = ["total_token_usage": total]
    if let last { info["last_token_usage"] = last }
    return try jsonLine("event_msg", ["type": "token_count", "info": info], date)
}
private func temporarySession() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-swap-check-\(UUID())")
    let directory = root.appendingPathComponent("sessions/2020/01/01")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (root, directory.appendingPathComponent("rollout.jsonl"))
}

@main
struct TelemetryChecks {
    static func main() async throws {
        try accountingAndDedup()
        try windowDenominators()
        try forkReplay()
        try historyReference()
        try await oldMetadataAndBaseline()
        try await perModelAndPartialAppend()
        try await resumedSessions()
        try await missingFolder()
        try await rollingWindowsNewCompletion()
        try requestSpeeds()
        try nonReasoningRequestSpeeds()
        try speedIntegrityBoundaries()
        try indexedSpeedsPreserveResults()
        print("Telemetry: 13 checks passed, including indexed all-model results, latest/last-five request speeds and insufficient/invalid samples.")
        if CommandLine.arguments.contains("--live") {
            let snapshot = await SessionScanner().refreshByModel()
            print("Live collection: \(snapshot.aggregate.status.rawValue); models: \(snapshot.modelNames.count); malformed structural records: \(snapshot.aggregate.malformedRelevantLines)")
        }
    }

    static func accountingAndDedup() throws {
        let now = Date()
        var state = TokenParserState()
        let value = usage(100, 20, cached: 80, reasoning: 10)
        let event = try token(value, value, at: now)
        let lines = [
            try jsonLine("session_meta", ["id": "session"], now),
            try jsonLine("turn_context", ["model": "gpt-a"], now),
            event, event
        ]
        let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: "fallback")
        try expect(batch.events.count == 1, "repeated cumulative usage was counted twice")
        try expect(batch.events[0].usage.totalTokens == 120, "cached/reasoning subsets were added twice")
        try expect(batch.events[0].model == "gpt-a", "model attribution was lost")
        try expect(batch.malformedRelevantLines == 0, "sorted-key JSON did not parse")
    }

    static func windowDenominators() throws {
        let now = Date()
        let events = [
            UsageEvent(timestamp: now.addingTimeInterval(-30), usage: TokenUsage(inputTokens: 500,
                outputTokens: 100), sessionID: "a", deduplicationKey: "a", model: "gpt-a"),
            UsageEvent(timestamp: now.addingTimeInterval(-120), usage: TokenUsage(inputTokens: 1200,
                outputTokens: 300), sessionID: "b", deduplicationKey: "b", model: "gpt-b")
        ]
        let result = UsageMetricsCalculator.snapshot(events: events, now: now, activeSessions: 2,
            malformedRelevantLines: 0)
        try expect(result.oneMinute.tokensPerSecond == 10, "1m denominator is not 60 seconds")
        try expect(result.fiveMinutes.tokensPerSecond == 7, "5m denominator is not 300 seconds")
        try expect(result.oneMinute.outputTokensPerSecond == 100.0 / 60, "input tokens leaked into output rate")
    }

    static func requestSpeeds() throws {
        func sample(_ id: Int, _ model: String, _ output: Int, _ duration: Double) -> RequestSpeedSample {
            RequestSpeedSample(id: String(id), model: model, completedAt: Double(id), outputTokens: output,
                durationSeconds: duration, inputTokens: 100, reasoningTokens: 0, cachedTokens: 0, ttftSeconds: 10)
        }
        let speed = RequestSpeedSnapshot(samples: [sample(1,"a",1000,10),sample(2,"a",50,1),
            sample(3,"b",900,1),sample(4,"a",300,1),sample(5,"a",100,1),
            sample(6,"a",10,1),sample(7,"a",200,1),sample(7,"a",200,1),sample(8,"a",100,0)])
        try expect(speed.latest(model: "a")?.rate == 200, "latest request is not filtered/deduplicated/validated")
        try expect(speed.average(model: "a") == 132, "last-five rate is not the arithmetic mean of individual speeds")
        try expect(speed.average(model: "b") == 900, "fewer than five samples were divided by five")
        try expect(speed.average(model: "missing") == nil, "missing model falsely shows zero TPS")
        try expect(speed.recent(model: "a").count == 5, "last-five sample count differs")
        let legacy = try JSONDecoder().decode(RequestSpeedSample.self, from: JSONEncoder().encode(sample(1,"a",1000,10)))
        try expect(legacy.serviceTier == nil && !legacy.isFast, "legacy samples guessed Fast")
        var fast = legacy
        fast.serviceTier = "priority"
        let decoded = try JSONDecoder().decode(RequestSpeedSample.self, from: JSONEncoder().encode(fast))
        try expect(decoded.isFast, "Fast tier lost during decoding")
        fast.serviceTier = "fast"
        try expect(fast.isFast, "fast alias not recognized")
        fast.serviceTier = "default"
        try expect(!fast.isFast, "standard tier labeled Fast")
        let mixed = RequestSpeedSnapshot(samples: [legacy, sample(2,"a",50,1)])
        try expect(mixed.average(model: "a") == 75, "tier changed averaging")
        let history = RequestSpeedSnapshot(samples: (1...150).map { sample($0,"a",$0,1) } +
            (151...270).map { sample($0,"b",$0,1) })
        try expect(history.history(model: "a").count == 100, "model history is not capped at 100")
        try expect(history.history(model: "a").last?.id == "51", "history lost the most recent 100")
        try expect(history.history(model: "").count == 200, "all models were capped globally")
        try expect(history.average(model: "a") == 148, "history expansion changed the five-request average")
    }

    static func indexedSpeedsPreserveResults() throws {
        // Compare the index with the previous scan-on-read definition, including
        // duplicate identities, tied timestamps, invalid counts and missing timing.
        let samples = (0..<1800).map { index in
            RequestSpeedSample(id: "\(index % 1401)", model: "model-\(index % 6)",
                completedAt: Double(index / 3 + 10), outputTokens: index % 97 == 0 ? 0 : 100 + index,
                durationSeconds: index % 53 == 0 ? 0 : 2, inputTokens: 10000,
                reasoningTokens: index % 13 == 0 ? 50 : 0,
                cachedTokens: index % 41 == 0 ? 10001 : 8000, ttftSeconds: 1,
                nonReasoningDurationSeconds: index % 2 == 0 ? 1.5 : nil)
        }
        let snapshot = RequestSpeedSnapshot(samples: samples)
        for model in [""] + snapshot.modelNames + ["missing"] {
            var seen: Set<String> = []
            let expected = samples.filter { $0.valid && (model.isEmpty || $0.model == model) }
                .sorted { $0.completedAt == $1.completedAt ? $0.id > $1.id : $0.completedAt > $1.completedAt }
                .filter { seen.insert($0.id).inserted }
            for count in [1, 5, 101, 2000] {
                try expect(snapshot.recent(model: model, count: count) == Array(expected.prefix(count)),
                           "indexed recent requests changed ordering, validation or deduplication")
            }
            var counts: [String: Int] = [:]
            let history = expected.filter { sample in
                guard counts[sample.model, default: 0] < 100 else { return false }
                counts[sample.model, default: 0] += 1
                return true
            }
            try expect(snapshot.history(model: model) == history, "index changed per-model history retention")
            let recent = Array(expected.prefix(5)), rates = recent.compactMap(\.rate)
            let average = snapshot.averageResult(model: model)
            try expect(average.requestCount == recent.count && average.measuredCount == rates.count &&
                       average.value == (rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)),
                       "index changed the measured sample count or TPS average")
        }
        let encoded = try JSONEncoder().encode(snapshot)
        let keys = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try expect(Set(keys.keys) == ["samples"], "derived UI index leaked into persisted telemetry")
        let restored = try JSONDecoder().decode(RequestSpeedSnapshot.self, from: encoded)
        try expect(restored == snapshot && restored.samples == samples, "index roundtrip changed raw numeric samples")
    }

    static func nonReasoningRequestSpeeds() throws {
        var sample = RequestSpeedSample(id: "screenshot", model: "gpt-6.1-sol", completedAt: 1791650913.539,
            outputTokens: 304, durationSeconds: 0.7330000400543213, inputTokens: 91860,
            reasoningTokens: 253, cachedTokens: 24832, ttftSeconds: 14.518)
        sample.startedAt = 1791650898.288
        try expect(sample.rate == nil, "reasoning-inclusive usage was divided by an unverified output duration")
        sample.nonReasoningDurationSeconds = 1791650913.539 - 1791650912.791932
        try expect(sample.streamedOutputTokens == 51 && abs(sample.rate! - 68.2669) < 0.01,
                   "the 414.7 TPS screenshot was not corrected using the matching output phase")
        let decoded = try JSONDecoder().decode(RequestSpeedSample.self, from: JSONEncoder().encode(sample))
        try expect(decoded.outputTokens == 304 && decoded.reasoningTokens == 253,
                   "raw API token usage was rewritten instead of preserving the source")
        var missing = sample
        missing = RequestSpeedSample(id: "missing", model: "gpt-6.1-sol", completedAt: 1791650914,
            outputTokens: 100, durationSeconds: 1, inputTokens: 100, reasoningTokens: 50,
            cachedTokens: 0, ttftSeconds: 1)
        let pair = RequestSpeedSnapshot(samples: [sample, missing])
        try expect(pair.history(model: "").count == 2 && pair.latest(model: "")?.rate == nil,
                   "a missing timing disappeared or was replaced with an older API's speed")
        try expect(abs(pair.average(model: "")! - sample.rate!) < 0.0001,
                   "missing timing was included as zero or an estimated rate")
        var records: [RequestSpeedSample] = []
        for index in 1...6 {
            let output: Int = index == 1 ? 999 : 100
            let reasoning: Int = index == 6 ? 50 : 0
            records.append(RequestSpeedSample(id: String(index), model: "a", completedAt: Double(index),
                outputTokens: output, durationSeconds: 1, inputTokens: 100, reasoningTokens: reasoning,
                cachedTokens: 0, ttftSeconds: 1))
        }
        try expect(RequestSpeedSnapshot(samples: records).average(model: "a") == 100,
                   "last-five averaging pulled in an older high rate to replace unavailable timing")
        records[0] = RequestSpeedSample(id: "fast", model: "fast", completedAt: 1, outputTokens: 600,
            durationSeconds: 1, inputTokens: 100, reasoningTokens: 0, cachedTokens: 0, ttftSeconds: 1)
        try expect(records[0].rate == 600, "the fix is merely capping legitimately measured high rates")
    }

    static func rollingWindowsNewCompletion() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var lines = Data()
        lines.append(try jsonLine("session_meta", ["id": "rolling"], now))
        lines.append(try jsonLine("turn_context", ["model": "gpt-a"], now))
        lines.append(try token(usage(100, 300), usage(100, 300), at: now.addingTimeInterval(-120)))
        try lines.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let scanner = SessionScanner(codexHome: root)
        let before = await scanner.refreshByModel(now: now)
        try expect(before.metrics(seconds: 60, model: "").requestCount == 0, "older request leaked into 1m")
        try expect(before.metrics(seconds: 300, model: "").outputTokensPerSecond == 1, "5m lost older request")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: token(usage(200, 900), usage(100, 600), at: now))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let after = await scanner.refreshByModel(now: now)
        try expect(after.metrics(seconds: 60, model: "").outputTokensPerSecond == 10, "new completion did not populate 1m")
        try expect(after.metrics(seconds: 300, model: "").outputTokensPerSecond == 3, "new completion cleared or duplicated 5m history")
        try expect(after.metrics(seconds: 60, model: "gpt-a") == after.aggregate.oneMinute, "per-model window differs from aggregate")
        let expired = await scanner.refreshByModel(now: now.addingTimeInterval(60))
        try expect(expired.aggregate.oneMinute.requestCount == 0, "1m boundary did not expire request")
        try expect(expired.aggregate.fiveMinutes.requestCount == 2, "1m expiration cleared 5m history")
    }

    static func speedIntegrityBoundaries() throws {
        var sample = RequestSpeedSample(id: "bounds", model: "a", completedAt: 10,
            outputTokens: 100, durationSeconds: 1, inputTokens: 200, reasoningTokens: 0,
            cachedTokens: 100, ttftSeconds: 1)
        sample.startedAt = 5
        sample.nonReasoningDurationSeconds = 6
        try expect(sample.valid && sample.rate == nil, "an output duration longer than its API call produced a rate")
        sample.nonReasoningDurationSeconds = 1
        try expect(sample.rate == 100, "valid numeric sample was rejected")
        let original = sample
        sample.startedAt = .nan
        try expect(!sample.valid && sample.rate == nil, "non-finite request start produced a rate")
        let invalidCache = RequestSpeedSample(id: "cache", model: "a", completedAt: 11,
            outputTokens: 100, durationSeconds: 1, inputTokens: 10, reasoningTokens: 0,
            cachedTokens: 11, ttftSeconds: 1)
        let snapshot = RequestSpeedSnapshot(samples: [original, invalidCache])
        try expect(snapshot.recent(model: "a").count == 1, "contradictory input/cache counters reached the average")
        let average = RequestSpeedSnapshot(samples: [original, original]).averageResult(model: "a")
        try expect(average.requestCount == 1 && average.measuredCount == 1,
                   "duplicate IDs changed the actual average sample count")
        let reasoning = RequestSpeedSample(id: "missing", model: "a", completedAt: 12,
            outputTokens: 100, durationSeconds: 1, inputTokens: 100, reasoningTokens: 50,
            cachedTokens: 0, ttftSeconds: 1)
        let partial = RequestSpeedSnapshot(samples: [original, reasoning]).averageResult(model: "a")
        try expect(partial.requestCount == 2 && partial.measuredCount == 1 && partial.value == 100,
                   "unavailable timing changed or concealed the actual average count")
    }

    static func forkReplay() throws {
        let now = Date()
        let child = "019f5e41-117d-7000-8000-000000000001"
        let ownTurn = "019f5e41-117e-7000-8000-000000000001"
        let legacyTurn = "49b1eb54-d964-4272-8c71-01c9eed13679"
        let original = usage(100, 20)
        let own = usage(20, 2)
        var state = TokenParserState()
        let lines = [
            try jsonLine("session_meta", ["id": child, "parent_thread_id": "parent"], now),
            try jsonLine("session_meta", ["id": "parent"], now),
            try jsonLine("turn_context", ["turn_id": legacyTurn, "model": "gpt-parent"], now),
            try token(original, original, at: now),
            try jsonLine("turn_context", ["turn_id": ownTurn, "model": "gpt-child"], now),
            try token(original, original, at: now),
            try token(usage(120, 22), own, at: now)
        ]
        let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: child)
        try expect(batch.events.map(\.usage.totalTokens) == [22], "fork replay inflated throughput")
        try expect(batch.events.first?.model == "gpt-child", "child model was not retained")
    }

    static func historyReference() throws {
        let now = Date()
        var state = TokenParserState()
        let lines = [
            try jsonLine("session_meta", ["id": "same-thread",
                "history_base": ["thread_id": "same-thread", "end_byte_offset": 100]], now),
            try jsonLine("turn_context", ["model": "gpt-a"], now),
            try token(usage(20, 10), usage(20, 10), at: now)
        ]
        let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: "same-thread")
        try expect(batch.events.count == 1, "same-thread history reference was treated as inherited replay")
    }

    static func oldMetadataAndBaseline() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), old = Date().addingTimeInterval(-10800)
        var data = try jsonLine("session_meta", ["id": "session"], old)
        data.append(try jsonLine("turn_context", ["model": "gpt-a"], old))
        data.append(try token(usage(100, 10), nil, at: old))
        data.append(try token(usage(120, 40), nil, at: now.addingTimeInterval(-5)))
        try data.write(to: file)
        let scanner = SessionScanner(codexHome: root)
        let snapshot = await scanner.refreshByModel(now: now)
        try expect(snapshot.aggregate.oneMinute.totalTokens == 50, "old cumulative baseline was counted as current usage")
        try expect(snapshot.models["gpt-a"]?.oneMinute.totalTokens == 50, "old model context was discarded")
        let second = await scanner.refreshByModel(now: now)
        try expect(second.aggregate.oneMinute == snapshot.aggregate.oneMinute, "unchanged scan increased counters")
    }

    static func perModelAndPartialAppend() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var data = try jsonLine("session_meta", ["id": "session"], now)
        data.append(try jsonLine("turn_context", ["model": "gpt-a"], now))
        data.append(try token(usage(100, 60), usage(100, 60), at: now))
        data.append(try jsonLine("turn_context", ["model": "gpt-b"], now))
        var pending = try token(usage(120, 90), usage(20, 30), at: now)
        pending.removeLast()
        data.append(pending)
        try data.write(to: file)
        let scanner = SessionScanner(codexHome: root)
        let first = await scanner.refreshByModel(now: now)
        try expect(first.aggregate.oneMinute.requestCount == 1, "unterminated JSONL record was counted")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        let second = await scanner.refreshByModel(now: now)
        try expect(second.aggregate.oneMinute.requestCount == 2, "completed partial record was lost")
        try expect(second.models["gpt-a"]?.oneMinute.outputTokensPerSecond == 1, "model A output is incorrect")
        try expect(second.models["gpt-b"]?.oneMinute.outputTokensPerSecond == 0.5, "model B output is incorrect")
        try expect(second.aggregate.oneMinute.outputTokensPerSecond == 1.5, "model groups do not sum to aggregate")
        let third = await scanner.refreshByModel(now: now)
        try expect(third.aggregate.oneMinute == second.aggregate.oneMinute, "incremental event was counted again")
    }

    static func resumedSessions() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var data = try jsonLine("session_meta", ["id": "same-thread"], now)
        data.append(try jsonLine("turn_context", ["model": "gpt-a"], now))
        data.append(try token(usage(100, 60), usage(100, 60), at: now))
        try data.write(to: file)
        try data.write(to: file.deletingLastPathComponent().appendingPathComponent("resume.jsonl"))
        let snapshot = await SessionScanner(codexHome: root).refreshByModel(now: now)
        try expect(snapshot.aggregate.oneMinute.requestCount == 1, "resumed files duplicated one request")
        try expect(snapshot.aggregate.activeSessions == 1, "resumed files duplicated an active session")
        try expect(snapshot.models["gpt-a"]?.activeSessions == 1, "per-model session count is incorrect")
    }

    static func missingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID())")
        let snapshot = await SessionScanner(codexHome: root).refreshByModel()
        try expect(snapshot.aggregate.status == .sessionsDirectoryMissing, "missing logs were shown as valid zero throughput")
    }
}
