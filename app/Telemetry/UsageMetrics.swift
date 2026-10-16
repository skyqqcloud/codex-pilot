// Derived from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
// Modified for Codex Swap. See ThirdParty/OPLFleetAgent/NOTICE.
import Foundation

public struct WindowMetrics: Codable, Equatable, Sendable {
  public let windowSeconds: Int
  public let requestCount: Int
  public let requestsPerMinute: Double
  public let tokensPerSecond: Double
  public let inputTokensPerSecond: Double
  public let cachedInputTokensPerSecond: Double
  public let outputTokensPerSecond: Double
  public let reasoningTokensPerSecond: Double
  public let cacheRatio: Double
  public let totalTokens: Int64

  public static func empty(windowSeconds: Int) -> WindowMetrics {
    WindowMetrics(
      windowSeconds: windowSeconds,
      requestCount: 0,
      requestsPerMinute: 0,
      tokensPerSecond: 0,
      inputTokensPerSecond: 0,
      cachedInputTokensPerSecond: 0,
      outputTokensPerSecond: 0,
      reasoningTokensPerSecond: 0,
      cacheRatio: 0,
      totalTokens: 0
    )
  }
}

public enum CollectionStatus: String, Codable, Sendable {
  case ready
  case sessionsDirectoryMissing
  case readFailed
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let oneMinute: WindowMetrics
  public let fiveMinutes: WindowMetrics
  public let thirtyMinutes: WindowMetrics
  public let oneHour: WindowMetrics
  public let activeSessions: Int
  public let malformedRelevantLines: Int
  public let status: CollectionStatus

  public static func empty(at date: Date, status: CollectionStatus) -> UsageSnapshot {
    UsageSnapshot(
      generatedAt: date,
      oneMinute: .empty(windowSeconds: 60),
      fiveMinutes: .empty(windowSeconds: 300),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 0,
      malformedRelevantLines: 0,
      status: status
    )
  }
}

public enum UsageMetricsCalculator {
  public static func snapshot(
    events: [UsageEvent],
    now: Date,
    activeSessions: Int,
    malformedRelevantLines: Int,
    status: CollectionStatus = .ready
  ) -> UsageSnapshot {
    UsageSnapshot(
      generatedAt: now,
      oneMinute: metrics(events: events, now: now, seconds: 60),
      fiveMinutes: metrics(events: events, now: now, seconds: 300),
      thirtyMinutes: metrics(events: events, now: now, seconds: 1_800),
      oneHour: metrics(events: events, now: now, seconds: 3_600),
      activeSessions: activeSessions,
      malformedRelevantLines: malformedRelevantLines,
      status: status
    )
  }

  private static func metrics(events: [UsageEvent], now: Date, seconds: Int) -> WindowMetrics {
    let start = now.addingTimeInterval(-Double(seconds))
    let matching = events.filter {
      $0.timestamp > start && $0.timestamp <= now.addingTimeInterval(5)
    }

    let input = matching.reduce(Int64(0)) { $0 + $1.usage.inputTokens }
    let cached = matching.reduce(Int64(0)) { $0 + $1.usage.cachedInputTokens }
    let output = matching.reduce(Int64(0)) { $0 + $1.usage.outputTokens }
    let reasoning = matching.reduce(Int64(0)) { $0 + $1.usage.reasoningOutputTokens }
    let total = matching.reduce(Int64(0)) { $0 + $1.usage.totalTokens }
    let duration = Double(seconds)

    return WindowMetrics(
      windowSeconds: seconds,
      requestCount: matching.count,
      requestsPerMinute: Double(matching.count) * 60 / duration,
      tokensPerSecond: Double(total) / duration,
      inputTokensPerSecond: Double(input) / duration,
      cachedInputTokensPerSecond: Double(cached) / duration,
      outputTokensPerSecond: Double(output) / duration,
      reasoningTokensPerSecond: Double(reasoning) / duration,
      cacheRatio: input > 0 ? Double(cached) / Double(input) : 0,
      totalTokens: total
    )
  }
}
