// Adapted from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
import Foundation
import XCTest

@testable import CodexSwapTelemetry

final class SessionScannerTests: XCTestCase {
  func testScannerIncludesRecentlyModifiedSessionFileFromOlderDirectory() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agent-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    let olderDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now))
    let components = calendar.dateComponents([.year, .month, .day], from: olderDate)
    let sessions =
      temporaryRoot
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let timestamp = now.addingTimeInterval(-5).formatted(.iso8601)
    let log = sessions.appendingPathComponent("rollout-session-a.jsonl")
    let contents =
      [
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(contents.utf8).write(to: log)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

    let snapshot = await SessionScanner(codexHome: temporaryRoot, calendar: calendar).refresh(now: now)

    XCTAssertEqual(snapshot.oneMinute.requestCount, 1)
    XCTAssertEqual(snapshot.oneMinute.totalTokens, 120)
    XCTAssertEqual(snapshot.activeSessions, 1)
  }

  func testScannerReadsOnlyAppendedEventsAfterBootstrap() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agent-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    let sessions =
      temporaryRoot
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let log = sessions.appendingPathComponent("rollout-session-a.jsonl")
    let firstTimestamp = now.addingTimeInterval(-20).formatted(.iso8601)
    let secondTimestamp = now.addingTimeInterval(-5).formatted(.iso8601)
    let initial =
      [
        #"{"timestamp":"\#(firstTimestamp)","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}"#,
        #"{"timestamp":"\#(firstTimestamp)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
        #"{"timestamp":"\#(firstTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(initial.utf8).write(to: log)

    let scanner = SessionScanner(codexHome: temporaryRoot, calendar: calendar)
    let first = await scanner.refresh(now: now)
    XCTAssertEqual(first.oneMinute.totalTokens, 120)

    let append =
      #"{"timestamp":"\#(secondTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":30,"total_tokens":180},"last_token_usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60}}}}"#
      + "\n"
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(append.utf8))
    try handle.close()

    let second = await scanner.refresh(now: now)
    let unchanged = await scanner.refresh(now: now)

    XCTAssertEqual(second.oneMinute.totalTokens, 180)
    XCTAssertEqual(unchanged.oneMinute.totalTokens, 180)
    XCTAssertEqual(unchanged.oneMinute.requestCount, 2)
  }

  func testScannerDeduplicatesReplayedEventAcrossFiles() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agent-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    let sessions =
      temporaryRoot
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let timestamp = now.addingTimeInterval(-5).formatted(.iso8601)
    let event =
      #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#
      + "\n"
    let parent =
      [
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
        event.trimmingCharacters(in: .newlines),
      ].joined(separator: "\n") + "\n"
    let child =
      [
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","thread_source":"subagent","model_provider":"test-provider"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
        event.trimmingCharacters(in: .newlines),
      ].joined(separator: "\n") + "\n"
    try Data(parent.utf8).write(to: sessions.appendingPathComponent("rollout-parent.jsonl"))
    try Data(child.utf8).write(to: sessions.appendingPathComponent("rollout-child.jsonl"))

    let snapshot = await SessionScanner(codexHome: temporaryRoot, calendar: calendar).refresh(
      now: now)

    XCTAssertEqual(snapshot.oneMinute.requestCount, 1)
    XCTAssertEqual(snapshot.oneMinute.totalTokens, 120)
  }

  func testScannerSkipsForkHistoryWhenReplayTimestampsAreRewritten() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agent-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    let sessions =
      temporaryRoot
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let parentTimestamp = now.addingTimeInterval(-10).formatted(.iso8601)
    let replayTimestamp = now.addingTimeInterval(-5).formatted(.iso8601)
    let childID = "019f5e41-117d-7000-8000-000000000001"
    let childTurnID = "019f5e41-117e-7000-8000-000000000001"
    let legacyTurnID = "49b1eb54-d964-4272-8c71-01c9eed13679"
    let parentEvent =
      #"{"timestamp":"\#(parentTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#
      + "\n"
    try Data(parentEvent.utf8).write(to: sessions.appendingPathComponent("rollout-parent.jsonl"))

    let child =
      [
        #"{"timestamp":"\#(replayTimestamp)","type":"session_meta","payload":{"id":"\#(childID)","forked_from_id":"parent","thread_source":"subagent","model_provider":"test-provider"}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"session_meta","payload":{"id":"parent","thread_source":"user","model_provider":"test-provider"}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(legacyTurnID)"}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"turn_context","payload":{"turn_id":"\#(legacyTurnID)","model":"gpt-test"}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(childTurnID)"}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"turn_context","payload":{"turn_id":"\#(childTurnID)","model":"gpt-test"}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
        #"{"timestamp":"\#(replayTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":22,"total_tokens":142},"last_token_usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(child.utf8).write(to: sessions.appendingPathComponent("rollout-child.jsonl"))

    let snapshot = await SessionScanner(codexHome: temporaryRoot, calendar: calendar).refresh(
      now: now)

    XCTAssertEqual(snapshot.oneMinute.requestCount, 2)
    XCTAssertEqual(snapshot.oneMinute.totalTokens, 142)
  }
}
