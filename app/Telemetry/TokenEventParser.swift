// Derived from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
// Modified for Codex Swap. See ThirdParty/OPLFleetAgent/NOTICE.
import Foundation

public struct TokenParserState: Sendable {
  var currentModel: String?
  var provider: String?
  var sessionIDFromMeta: String?
  var forkParentID: String?
  var childSessionID: String?
  var childProvider: String?
  var replaySessionID: String?
  var waitingForChildTurn = false
  var childIsUserFork = false
  var childTaskStartedTurnIDs: Set<String> = []
  var previousTotals: UsageTotals?
  var inheritedBaseline: UsageTotals?
  var inheritedReportedTotal: Int64?

  public init() {}
}

public struct TokenParseBatch: Sendable {
  public let events: [UsageEvent]
  public let malformedRelevantLines: Int

  public init(events: [UsageEvent], malformedRelevantLines: Int) {
    self.events = events
    self.malformedRelevantLines = malformedRelevantLines
  }
}

public enum TokenEventParser {
  static let relevantMarkers = [
    Data("\"type\":\"token_count\"".utf8),
    Data("\"type\": \"token_count\"".utf8),
    Data("\"type\":\"session_meta\"".utf8),
    Data("\"type\": \"session_meta\"".utf8),
    Data("\"type\":\"turn_context\"".utf8),
    Data("\"type\": \"turn_context\"".utf8),
    Data("\"type\":\"task_started\"".utf8),
    Data("\"type\": \"task_started\"".utf8),
  ]

  public static func parse(
    lines: [Data],
    state: inout TokenParserState,
    fallbackSessionID: String
  ) -> TokenParseBatch {
    var events: [UsageEvent] = []
    var malformed = 0
    let decoder = JSONDecoder()

    for line in lines where shouldInspect(line) {
      let entry: CodexLogEntry
      do {
        entry = try decoder.decode(CodexLogEntry.self, from: line)
      } catch {
        malformed += 1
        continue
      }

      events.append(
        contentsOf: process(
          entry,
          state: &state,
          fallbackSessionID: fallbackSessionID
        ))
    }

    return TokenParseBatch(events: events, malformedRelevantLines: malformed)
  }

  static func shouldInspect(_ line: Data) -> Bool {
    relevantMarkers.contains { line.range(of: $0) != nil }
  }

  private static func process(
    _ entry: CodexLogEntry,
    state: inout TokenParserState,
    fallbackSessionID: String
  ) -> [UsageEvent] {
    guard let payload = entry.payload else { return [] }

    if state.waitingForChildTurn {
      if entry.type == "turn_context",
        childTurnStartsOwnSession(state: state, turnID: payload.turnID)
      {
        state.waitingForChildTurn = false
        state.replaySessionID = nil
        state.childTaskStartedTurnIDs.removeAll()
        state.childIsUserFork = false
        state.sessionIDFromMeta = state.childSessionID
        state.provider = state.childProvider ?? state.provider
        state.currentModel = payload.resolvedModel ?? state.currentModel
      } else {
        rememberReplayState(entry, payload: payload, state: &state)
        return []
      }
    }

    if entry.type == "session_meta" {
      processSessionMeta(payload, state: &state)
      return []
    }

    if entry.type == "turn_context" {
      state.currentModel = payload.resolvedModel ?? state.currentModel
      return []
    }

    guard entry.type == "event_msg", payload.type == "token_count", let info = payload.info else {
      return []
    }

    state.currentModel = payload.resolvedModel ?? state.currentModel
    return processTokenCount(
      entry,
      info: info,
      state: &state,
      fallbackSessionID: fallbackSessionID
    )
  }

  private static func processSessionMeta(_ payload: CodexPayload, state: inout TokenParserState) {
    if let parentID = payload.resolvedForkParentID {
      let repeatedChild =
        !state.waitingForChildTurn
        && state.childSessionID != nil
        && state.childSessionID == payload.id

      state.forkParentID = parentID
      state.childSessionID = payload.id
      state.childProvider = payload.modelProvider.nonEmpty ?? state.childProvider
      state.sessionIDFromMeta = payload.id ?? state.sessionIDFromMeta
      state.provider = payload.modelProvider.nonEmpty ?? state.provider

      if !repeatedChild {
        state.waitingForChildTurn = true
        state.replaySessionID = nil
        state.inheritedBaseline = nil
        state.inheritedReportedTotal = nil
        state.childTaskStartedTurnIDs.removeAll()
        state.childIsUserFork = payload.threadSource == "user"
      }
      return
    }

    state.sessionIDFromMeta = payload.id ?? state.sessionIDFromMeta
    state.provider = payload.modelProvider.nonEmpty ?? state.provider
    state.currentModel = payload.resolvedModel ?? state.currentModel
  }

  private static func rememberReplayState(
    _ entry: CodexLogEntry,
    payload: CodexPayload,
    state: inout TokenParserState
  ) {
    if entry.type == "event_msg", payload.type == "task_started",
      let turnID = payload.turnID.nonEmpty
    {
      state.childTaskStartedTurnIDs.insert(turnID)
    }

    if entry.type == "session_meta",
      let id = payload.id.nonEmpty,
      id != state.childSessionID
    {
      state.replaySessionID = id
    }

    if entry.type == "event_msg",
      payload.type == "token_count",
      let totalUsage = payload.info?.totalTokenUsage
    {
      let totals = UsageTotals(totalUsage)
      state.previousTotals = totals
      state.inheritedBaseline = totals
      state.inheritedReportedTotal = totalUsage.totalTokens
    }
  }

  private static func processTokenCount(
    _ entry: CodexLogEntry,
    info: CodexUsageInfo,
    state: inout TokenParserState,
    fallbackSessionID: String
  ) -> [UsageEvent] {
    let total = info.totalTokenUsage.map(UsageTotals.init)
    let last = info.lastTokenUsage.map(UsageTotals.init)

    if shouldSkipInherited(total: total, state: state) {
      return []
    }
    state.inheritedBaseline = nil
    state.inheritedReportedTotal = nil

    let usage: TokenUsage
    let nextTotals: UsageTotals?

    switch (total, last, state.previousTotals) {
    case (.some(let current), .some(let increment), .some(let previous)):
      if current == previous {
        return []
      }
      if current.delta(from: previous) == nil,
        current.looksLikeStaleRegression(previous: previous, last: increment)
      {
        return []
      }
      usage = increment.asUsage()
      nextTotals = current

    case (.some(let current), .some(let increment), .none):
      usage = increment.asUsage()
      nextTotals = current

    case (.some(let current), .none, .some(let previous)):
      guard let delta = current.delta(from: previous) else {
        state.previousTotals = current
        return []
      }
      usage = delta.asUsage()
      nextTotals = current

    case (.some(let current), .none, .none):
      usage = current.asUsage()
      nextTotals = current

    case (.none, .some(let increment), _):
      usage = increment.asUsage()
      nextTotals = state.previousTotals

    case (.none, .none, _):
      return []
    }

    guard usage.totalTokens > 0 else { return [] }
    state.previousTotals = nextTotals

    let timestamp = parseTimestamp(entry.timestamp) ?? Date()
    let sessionID = state.sessionIDFromMeta ?? fallbackSessionID
    let scopeID = state.forkParentID ?? sessionID
    let provider = state.provider ?? "unknown"
    let model = info.model.nonEmpty ?? state.currentModel ?? "unknown"
    let key = deduplicationKey(
      timestamp: timestamp,
      usage: usage,
      total: total,
      scopeID: scopeID,
      provider: provider,
      model: model
    )

    return [
      UsageEvent(
        timestamp: timestamp,
        usage: usage,
        sessionID: sessionID,
        deduplicationKey: key,
        model: model
      )
    ]
  }

  private static func shouldSkipInherited(total: UsageTotals?, state: TokenParserState) -> Bool {
    if let reported = total?.reportedTotal,
      let baseline = state.inheritedReportedTotal,
      reported <= baseline
    {
      return true
    }

    if let total, let baseline = state.inheritedBaseline {
      return total.isWithin(baseline)
    }
    return false
  }

  private static func childTurnStartsOwnSession(state: TokenParserState, turnID: String?) -> Bool {
    guard state.replaySessionID != nil else { return true }
    guard
      let childID = state.childSessionID,
      let turnID,
      let childPrefix = uuidV7MillisecondPrefix(childID),
      let turnPrefix = uuidV7MillisecondPrefix(turnID)
    else {
      return false
    }

    if turnPrefix > childPrefix { return true }
    if turnPrefix < childPrefix { return false }
    return state.childIsUserFork || state.childTaskStartedTurnIDs.contains(turnID)
  }

  private static func uuidV7MillisecondPrefix(_ id: String) -> String? {
    let parts = id.split(separator: "-")
    guard parts.count == 5,
      parts[0].count == 8,
      parts[1].count == 4,
      parts[2].count == 4,
      parts[2].first == "7"
    else {
      return nil
    }
    let prefix = String(parts[0] + parts[1]).lowercased()
    guard prefix.allSatisfy({ $0.isHexDigit }) else { return nil }
    return prefix
  }

  private static func parseTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return try? Date(value, strategy: .iso8601)
  }

  private static func deduplicationKey(
    timestamp: Date,
    usage: TokenUsage,
    total: UsageTotals?,
    scopeID: String,
    provider: String,
    model: String
  ) -> String {
    if let total {
      return [
        "codex", "total", scopeID, provider, model, timestamp.formatted(.iso8601),
        String(total.input), String(total.output), String(total.cached),
        String(total.reasoning), String(total.reportedTotal),
      ].joined(separator: ":")
    }

    return [
      "codex", "event", scopeID, provider, model, timestamp.formatted(.iso8601),
      String(usage.inputTokens), String(usage.cachedInputTokens),
      String(usage.outputTokens), String(usage.reasoningOutputTokens),
    ].joined(separator: ":")
  }
}
