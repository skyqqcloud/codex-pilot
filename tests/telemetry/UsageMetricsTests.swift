// Adapted from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
import Foundation
import XCTest

@testable import CodexSwapTelemetry

final class UsageMetricsTests: XCTestCase {
  func testRollingWindowsUseFixedWindowDenominators() {
    let now = Date(timeIntervalSince1970: 1_000)
    let recent = event(
      at: now.addingTimeInterval(-30), total: 600, input: 500, cached: 400, output: 100)
    let older = event(
      at: now.addingTimeInterval(-120), total: 1_500, input: 1_200, cached: 800, output: 300)

    let snapshot = UsageMetricsCalculator.snapshot(
      events: [recent, older],
      now: now,
      activeSessions: 2,
      malformedRelevantLines: 0
    )

    XCTAssertEqual(snapshot.oneMinute.tokensPerSecond, 10, accuracy: 0.001)
    XCTAssertEqual(snapshot.oneMinute.requestsPerMinute, 1, accuracy: 0.001)
    XCTAssertEqual(snapshot.oneMinute.cacheRatio, 0.8, accuracy: 0.001)
    XCTAssertEqual(snapshot.fiveMinutes.tokensPerSecond, 7, accuracy: 0.001)
    XCTAssertEqual(snapshot.fiveMinutes.requestsPerMinute, 0.4, accuracy: 0.001)
    XCTAssertEqual(snapshot.thirtyMinutes.tokensPerSecond, 7.0 / 6.0, accuracy: 0.001)
    XCTAssertEqual(snapshot.thirtyMinutes.requestsPerMinute, 1.0 / 15.0, accuracy: 0.001)
    XCTAssertEqual(snapshot.oneHour.tokensPerSecond, 7.0 / 12.0, accuracy: 0.001)
    XCTAssertEqual(snapshot.oneHour.requestsPerMinute, 1.0 / 30.0, accuracy: 0.001)
    XCTAssertEqual(snapshot.activeSessions, 2)
  }

  private func event(
    at date: Date,
    total: Int64,
    input: Int64,
    cached: Int64,
    output: Int64
  ) -> UsageEvent {
    UsageEvent(
      timestamp: date,
      usage: TokenUsage(
        inputTokens: input,
        cachedInputTokens: cached,
        outputTokens: output,
        totalTokens: total
      ),
      sessionID: UUID().uuidString,
      deduplicationKey: UUID().uuidString
    )
  }
}
