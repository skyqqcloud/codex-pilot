// Derived from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
// Modified for Codex Swap. See ThirdParty/OPLFleetAgent/NOTICE.
import Foundation

public struct TokenUsage: Codable, Equatable, Hashable, Sendable {
  public let inputTokens: Int64
  public let cachedInputTokens: Int64
  public let outputTokens: Int64
  public let reasoningOutputTokens: Int64
  public let totalTokens: Int64

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cachedInputTokens = "cached_input_tokens"
    case outputTokens = "output_tokens"
    case reasoningOutputTokens = "reasoning_output_tokens"
    case totalTokens = "total_tokens"
  }

  public init(
    inputTokens: Int64,
    cachedInputTokens: Int64 = 0,
    outputTokens: Int64,
    reasoningOutputTokens: Int64 = 0,
    totalTokens: Int64? = nil
  ) {
    self.inputTokens = max(inputTokens, 0)
    self.cachedInputTokens = max(min(cachedInputTokens, inputTokens), 0)
    self.outputTokens = max(outputTokens, 0)
    self.reasoningOutputTokens = max(min(reasoningOutputTokens, outputTokens), 0)
    self.totalTokens = max(totalTokens ?? (inputTokens + outputTokens), 0)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let input = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
    let cached = try container.decodeIfPresent(Int64.self, forKey: .cachedInputTokens) ?? 0
    let output = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
    let reasoning = try container.decodeIfPresent(Int64.self, forKey: .reasoningOutputTokens) ?? 0
    let total = try container.decodeIfPresent(Int64.self, forKey: .totalTokens)
    self.init(
      inputTokens: input,
      cachedInputTokens: cached,
      outputTokens: output,
      reasoningOutputTokens: reasoning,
      totalTokens: total
    )
  }
}

struct UsageTotals: Equatable, Hashable, Sendable {
  let input: Int64
  let output: Int64
  let cached: Int64
  let reasoning: Int64
  let reportedTotal: Int64

  init(_ usage: TokenUsage) {
    input = usage.inputTokens
    output = usage.outputTokens
    cached = usage.cachedInputTokens
    reasoning = usage.reasoningOutputTokens
    reportedTotal = usage.totalTokens
  }

  var comparisonTotal: Int64 {
    input + output
  }

  func delta(from previous: UsageTotals) -> UsageTotals? {
    guard input >= previous.input,
      output >= previous.output,
      cached >= previous.cached,
      reasoning >= previous.reasoning
    else {
      return nil
    }

    return UsageTotals(
      input: input - previous.input,
      output: output - previous.output,
      cached: cached - previous.cached,
      reasoning: reasoning - previous.reasoning,
      reportedTotal: max(reportedTotal - previous.reportedTotal, 0)
    )
  }

  func isWithin(_ baseline: UsageTotals) -> Bool {
    input <= baseline.input
      && output <= baseline.output
      && cached <= baseline.cached
      && reasoning <= baseline.reasoning
  }

  func looksLikeStaleRegression(previous: UsageTotals, last: UsageTotals) -> Bool {
    let old = previous.comparisonTotal
    let current = comparisonTotal
    let increment = last.comparisonTotal
    guard old > 0, current > 0, increment > 0 else { return false }
    return current * 100 >= old * 98 || current + increment * 2 >= old
  }

  func asUsage() -> TokenUsage {
    TokenUsage(
      inputTokens: input,
      cachedInputTokens: cached,
      outputTokens: output,
      reasoningOutputTokens: reasoning,
      totalTokens: reportedTotal > 0 ? reportedTotal : input + output
    )
  }

  private init(
    input: Int64,
    output: Int64,
    cached: Int64,
    reasoning: Int64,
    reportedTotal: Int64
  ) {
    self.input = max(input, 0)
    self.output = max(output, 0)
    self.cached = max(cached, 0)
    self.reasoning = max(reasoning, 0)
    self.reportedTotal = max(reportedTotal, 0)
  }
}

public struct UsageEvent: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let usage: TokenUsage
  public let sessionID: String
  public let deduplicationKey: String
  public let model: String

  public init(
    timestamp: Date,
    usage: TokenUsage,
    sessionID: String,
    deduplicationKey: String,
    model: String = "unknown"
  ) {
    self.timestamp = timestamp
    self.usage = usage
    self.sessionID = sessionID
    self.deduplicationKey = deduplicationKey
    self.model = model
  }
}

struct CodexLogEntry: Decodable {
  let timestamp: String?
  let type: String
  let payload: CodexPayload?
}

struct CodexPayload: Decodable {
  let id: String?
  let forkedFromID: String?
  let parentThreadID: String?
  let historyBase: CodexHistoryBase?
  let type: String?
  let model: String?
  let modelName: String?
  let modelInfo: CodexModelInfo?
  let info: CodexUsageInfo?
  let turnID: String?
  let threadSource: String?
  let modelProvider: String?
  let source: CodexSource?

  enum CodingKeys: String, CodingKey {
    case id
    case forkedFromID = "forked_from_id"
    case parentThreadID = "parent_thread_id"
    case historyBase = "history_base"
    case type
    case model
    case modelName = "model_name"
    case modelInfo = "model_info"
    case info
    case turnID = "turn_id"
    case threadSource = "thread_source"
    case modelProvider = "model_provider"
    case source
  }

  var resolvedModel: String? {
    modelInfo?.slug.nonEmpty ?? model.nonEmpty ?? modelName.nonEmpty ?? info?.model.nonEmpty
  }

  var resolvedForkParentID: String? {
    forkedFromID.nonEmpty ?? parentThreadID.nonEmpty ?? source?.parentThreadID.nonEmpty
      ?? (historyBase?.threadID != id ? historyBase?.threadID.nonEmpty : nil)
  }
}

struct CodexHistoryBase: Decodable {
  let threadID: String?
  enum CodingKeys: String, CodingKey { case threadID = "thread_id" }
}

struct CodexModelInfo: Decodable {
  let slug: String?
}

struct CodexUsageInfo: Decodable {
  let model: String?
  let lastTokenUsage: TokenUsage?
  let totalTokenUsage: TokenUsage?

  enum CodingKeys: String, CodingKey {
    case model
    case lastTokenUsage = "last_token_usage"
    case totalTokenUsage = "total_token_usage"
  }
}

struct CodexSource: Decodable {
  let parentThreadID: String?

  private struct ObjectSource: Decodable {
    let subagent: SubagentSource?
  }

  private struct SubagentSource: Decodable {
    let threadSpawn: ThreadSpawn?

    enum CodingKeys: String, CodingKey {
      case threadSpawn = "thread_spawn"
    }
  }

  private struct ThreadSpawn: Decodable {
    let parentThreadID: String?

    enum CodingKeys: String, CodingKey {
      case parentThreadID = "parent_thread_id"
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if (try? container.decode(String.self)) != nil {
      parentThreadID = nil
      return
    }
    let object = try container.decode(ObjectSource.self)
    parentThreadID = object.subagent?.threadSpawn?.parentThreadID
  }
}

extension Optional where Wrapped == String {
  var nonEmpty: String? {
    guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
