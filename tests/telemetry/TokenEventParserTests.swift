// Adapted from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
import Foundation
import XCTest

@testable import CodexSwapTelemetry

final class TokenEventParserTests: XCTestCase {
  func testUsesLastUsageWithoutDoubleCountingCachedOrReasoningSubsets() throws {
    var state = TokenParserState()
    let lines = fixtureLines(
      #"{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}"#,
      #"{"timestamp":"2026-07-14T00:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
      #"{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}"#
    )

    let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: "fallback")

    XCTAssertEqual(batch.events.count, 1)
    XCTAssertEqual(batch.events[0].usage.totalTokens, 120)
    XCTAssertEqual(batch.events[0].usage.cachedInputTokens, 80)
    XCTAssertEqual(batch.events[0].usage.reasoningOutputTokens, 10)
  }

  func testRepeatedCumulativeSnapshotIsSuppressed() throws {
    var state = TokenParserState()
    let tokenLine =
      #"{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#
    let lines = fixtureLines(
      #"{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}"#,
      tokenLine,
      tokenLine
    )

    let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: "fallback")

    XCTAssertEqual(batch.events.count, 1)
  }

  func testForkedChildSkipsInheritedHistoryUntilOwnTurn() throws {
    var state = TokenParserState()
    let childID = "019f5e41-117d-7000-8000-000000000001"
    let childTurnID = "019f5e41-117e-7000-8000-000000000001"
    let lines = fixtureLines(
      #"{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"\#(childID)","forked_from_id":"parent","thread_source":"subagent","model_provider":"test-provider"}}"#,
      #"{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}"#,
      #"{"timestamp":"2026-07-14T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
      #"{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(childTurnID)"}}"#,
      #"{"timestamp":"2026-07-14T00:00:03Z","type":"turn_context","payload":{"turn_id":"\#(childTurnID)","model":"gpt-test"}}"#,
      #"{"timestamp":"2026-07-14T00:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
      #"{"timestamp":"2026-07-14T00:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":22,"total_tokens":142},"last_token_usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}}"#
    )

    let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: childID)

    XCTAssertEqual(batch.events.map(\.usage.totalTokens), [22])
    XCTAssertEqual(batch.events.first?.sessionID, childID)
  }

  func testForkedChildKeepsSkippingReplayWithLegacyTurnIDs() throws {
    var state = TokenParserState()
    let childID = "019f602b-1e2f-7d60-ac59-83fa4dd52c92"
    let childTurnID = "019f602b-4e8a-7360-ad43-2e65035ba716"
    let legacyTurnID = "49b1eb54-d964-4272-8c71-01c9eed13679"
    let lines = fixtureLines(
      #"{"timestamp":"2026-07-14T10:27:58Z","type":"session_meta","payload":{"id":"\#(childID)","forked_from_id":"parent","thread_source":"subagent","model_provider":"test-provider"}}"#,
      #"{"timestamp":"2026-07-14T10:27:58Z","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}"#,
      #"{"timestamp":"2026-07-14T10:27:58Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(legacyTurnID)"}}"#,
      #"{"timestamp":"2026-07-14T10:27:58Z","type":"turn_context","payload":{"turn_id":"\#(legacyTurnID)","model":"gpt-test"}}"#,
      #"{"timestamp":"2026-07-14T10:27:58Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
      #"{"timestamp":"2026-07-14T10:27:59Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(childTurnID)"}}"#,
      #"{"timestamp":"2026-07-14T10:28:00Z","type":"turn_context","payload":{"turn_id":"\#(childTurnID)","model":"gpt-test"}}"#,
      #"{"timestamp":"2026-07-14T10:28:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":22,"total_tokens":142},"last_token_usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}}"#
    )

    let batch = TokenEventParser.parse(lines: lines, state: &state, fallbackSessionID: childID)

    XCTAssertEqual(batch.events.map(\.usage.totalTokens), [22])
    XCTAssertEqual(batch.events.first?.sessionID, childID)
  }

  func testCrossFileReplayUsesStableEventIdentity() throws {
    var parentState = TokenParserState()
    var childState = TokenParserState()
    let token =
      #"{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#

    let parent = TokenEventParser.parse(
      lines: fixtureLines(
        #"{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}"#,
        #"{"timestamp":"2026-07-14T00:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
        token
      ), state: &parentState, fallbackSessionID: "parent")

    let child = TokenEventParser.parse(
      lines: fixtureLines(
        #"{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","model_provider":"test-provider"}}"#,
        #"{"timestamp":"2026-07-14T00:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
        token
      ), state: &childState, fallbackSessionID: "child")

    XCTAssertEqual(parent.events.first?.deduplicationKey, child.events.first?.deduplicationKey)
    XCTAssertEqual(parent.events.count, 1)
    XCTAssertEqual(child.events.count, 1)
  }

  private func fixtureLines(_ lines: String...) -> [Data] {
    lines.map { Data($0.utf8) }
  }
}
