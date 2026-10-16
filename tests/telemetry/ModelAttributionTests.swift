import Foundation
import XCTest
@testable import CodexSwapTelemetry

final class ModelAttributionTests: XCTestCase {
    private func line(_ type: String, _ payload: [String: Any], at date: Date) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": date.formatted(.iso8601), "type": type, "payload": payload
        ], options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func usage(input: Int, output: Int) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "total_tokens": input + output]
    }

    private func temporarySession() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-swap-test-\(UUID())")
        let directory = root.appendingPathComponent("sessions/2020/01/01")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (root, directory.appendingPathComponent("rollout.jsonl"))
    }

    func testOlderMetadataAndCumulativeBaselinePreserveModelAndOnlyCountNewUsage() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = now.addingTimeInterval(-3 * 3600)
        var data = try line("session_meta", ["id": "same-thread"], at: old)
        data.append(try line("turn_context", ["model": "gpt-a"], at: old))
        data.append(try line("event_msg", ["type": "token_count", "info": [
            "total_token_usage": usage(input: 100, output: 10)
        ]], at: old))
        data.append(try line("event_msg", ["type": "token_count", "info": [
            "total_token_usage": usage(input: 120, output: 40)
        ]], at: now.addingTimeInterval(-5)))
        try data.write(to: file)
        let scanner = SessionScanner(codexHome: root)
        let snapshot = await scanner.refreshByModel(now: now)
        XCTAssertEqual(snapshot.aggregate.oneMinute.totalTokens, 50)
        XCTAssertEqual(snapshot.models["gpt-a"]?.oneMinute.totalTokens, 50)
        XCTAssertEqual(snapshot.models["gpt-a"]?.oneMinute.outputTokensPerSecond ?? -1, 0.5, accuracy: 0.0001)
        let repeatSnapshot = await scanner.refreshByModel(now: now)
        XCTAssertEqual(repeatSnapshot.aggregate.oneMinute, snapshot.aggregate.oneMinute)
    }

    func testPerModelOutputsAddToAggregateAndPartialLinesAreConsumedOnce() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let eventTime = now.addingTimeInterval(-5)
        var data = try line("session_meta", ["id": "session"], at: eventTime)
        data.append(try line("turn_context", ["model": "gpt-a"], at: eventTime))
        data.append(try line("event_msg", ["type": "token_count", "info": [
            "last_token_usage": usage(input: 100, output: 60),
            "total_token_usage": usage(input: 100, output: 60)
        ]], at: eventTime))
        data.append(try line("turn_context", ["model": "gpt-b"], at: eventTime))
        var pending = try line("event_msg", ["type": "token_count", "info": [
            "last_token_usage": usage(input: 20, output: 30),
            "total_token_usage": usage(input: 120, output: 90)
        ]], at: eventTime))
        pending.removeLast()
        data.append(pending)
        try data.write(to: file)
        let scanner = SessionScanner(codexHome: root)
        let first = await scanner.refreshByModel(now: now)
        XCTAssertEqual(first.aggregate.oneMinute.requestCount, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        let second = await scanner.refreshByModel(now: now)
        XCTAssertEqual(second.aggregate.oneMinute.requestCount, 2)
        XCTAssertEqual(second.models["gpt-a"]?.oneMinute.outputTokensPerSecond ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(second.models["gpt-b"]?.oneMinute.outputTokensPerSecond ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second.aggregate.oneMinute.outputTokensPerSecond, 1.5, accuracy: 0.0001)
        let third = await scanner.refreshByModel(now: now)
        XCTAssertEqual(third.aggregate.oneMinute, second.aggregate.oneMinute)
    }

    func testResumedFilesDoNotDuplicateUsageOrActiveSessionCount() async throws {
        let (root, file) = try temporarySession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var data = try line("session_meta", ["id": "same-thread",
            "history_base": ["thread_id": "same-thread", "end_byte_offset": 100]], at: now)
        data.append(try line("turn_context", ["model": "gpt-a"], at: now))
        data.append(try line("event_msg", ["type": "token_count", "info": [
            "last_token_usage": usage(input: 100, output: 60),
            "total_token_usage": usage(input: 100, output: 60)
        ]], at: now))
        try data.write(to: file)
        try data.write(to: file.deletingLastPathComponent().appendingPathComponent("resumed.jsonl"))
        let snapshot = await SessionScanner(codexHome: root).refreshByModel(now: now)
        XCTAssertEqual(snapshot.aggregate.oneMinute.requestCount, 1)
        XCTAssertEqual(snapshot.aggregate.activeSessions, 1)
        XCTAssertEqual(snapshot.models["gpt-a"]?.activeSessions, 1)
    }

    func testCurrentParentThreadMetadataSkipsReplayedHistory() throws {
        let now = Date()
        let child = "019f5e41-117d-7000-8000-000000000001"
        let ownTurn = "019f5e41-117e-7000-8000-000000000001"
        let lines = [
            try line("session_meta", ["id": child, "parent_thread_id": "parent"], at: now),
            try line("session_meta", ["id": "parent"], at: now),
            try line("event_msg", ["type": "token_count", "info": [
                "last_token_usage": usage(input: 100, output: 10),
                "total_token_usage": usage(input: 100, output: 10)
            ]], at: now),
            try line("turn_context", ["turn_id": ownTurn, "model": "gpt-child"], at: now),
            try line("event_msg", ["type": "token_count", "info": [
                "last_token_usage": usage(input: 20, output: 2),
                "total_token_usage": usage(input: 120, output: 12)
            ]], at: now)
        ]
        var state = TokenParserState()
        let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: child)
        XCTAssertEqual(batch.events.map(\.usage.totalTokens), [22])
        XCTAssertEqual(batch.events.first?.model, "gpt-child")
    }
}
