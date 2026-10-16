// Derived from OPL Fleet Agent, Copyright 2026 Gaofeng, Apache-2.0.
// Modified for Codex Swap. See ThirdParty/OPLFleetAgent/NOTICE.
import Foundation

public actor SessionScanner {
  private static let timestampPrefix = Data("{\"timestamp\":\"".utf8)
  private static let newline = Data([0x0A])

  private struct FileCursor: Sendable {
    var offset: UInt64 = 0
    var remainder = Data()
    var parserState = TokenParserState()
    var lastModified = Date.distantPast
  }

  private struct SessionFile: Sendable {
    let url: URL
    let size: UInt64
    let modifiedAt: Date
  }

  public let codexHome: URL
  public let sessionsRoot: URL

  private let fileManager: FileManager
  private let calendar: Calendar
  private let activeFileHorizon: TimeInterval
  private let readChunkSize = 1_048_576
  private let markerOverlapSize = 4_096
  private var cursors: [URL: FileCursor] = [:]
  private var seenDeduplicationKeys: [String: Date] = [:]
  private var events: [UsageEvent] = []
  private var malformedRelevantLines = 0

  public init(
    codexHome: URL = SessionScanner.defaultCodexHome(),
    calendar: Calendar = .current,
    activeFileHorizon: TimeInterval = 65 * 60,
    fileManager: FileManager = .default
  ) {
    self.codexHome = codexHome
    sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
    self.calendar = calendar
    self.activeFileHorizon = activeFileHorizon
    self.fileManager = fileManager
  }

  public static func defaultCodexHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !configured.isEmpty
    {
      return URL(
        fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".codex", isDirectory: true)
  }

  public func refresh(now: Date = Date()) -> UsageSnapshot {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .empty(at: now, status: .sessionsDirectoryMissing)
    }

    do {
      let retentionStart = now.addingTimeInterval(-65 * 60)
      let files = try discoverSessionFiles(now: now)
      for file in files {
        try readAppendedContent(from: file, retentionStart: retentionStart)
      }

      events.removeAll { $0.timestamp < retentionStart }
      seenDeduplicationKeys = seenDeduplicationKeys.filter { $0.value >= retentionStart }
      let activeStart = now.addingTimeInterval(-2 * 60)
      let activeSessions = Set(files.filter { $0.modifiedAt >= activeStart }.map {
        cursors[$0.url]?.parserState.sessionIDFromMeta ?? $0.url.lastPathComponent
      }).count

      return UsageMetricsCalculator.snapshot(
        events: events,
        now: now,
        activeSessions: activeSessions,
        malformedRelevantLines: malformedRelevantLines
      )
    } catch {
      return UsageSnapshot(
        generatedAt: now,
        oneMinute: .empty(windowSeconds: 60),
        fiveMinutes: .empty(windowSeconds: 300),
        thirtyMinutes: .empty(windowSeconds: 1_800),
        oneHour: .empty(windowSeconds: 3_600),
        activeSessions: 0,
        malformedRelevantLines: malformedRelevantLines,
        status: .readFailed
      )
    }
  }

  func refreshByModel(now: Date = Date()) -> ModelUsageSnapshot {
    let aggregate = refresh(now: now)
    guard aggregate.status == .ready else {
      return ModelUsageSnapshot(aggregate: aggregate, models: [:])
    }
    let groups = Dictionary(grouping: events, by: \.model)
    let activeStart = now.addingTimeInterval(-120)
    let active = cursors.filter { $0.value.lastModified >= activeStart }
    let names = Set(groups.keys).union(active.values.compactMap { $0.parserState.currentModel })
    var models: [String: UsageSnapshot] = [:]
    for name in names {
      let sessions = Set(active.filter { $0.value.parserState.currentModel == name }.map {
        $0.value.parserState.sessionIDFromMeta ?? $0.key.lastPathComponent
      }).count
      models[name] = UsageMetricsCalculator.snapshot(
        events: groups[name] ?? [], now: now,
        activeSessions: sessions, malformedRelevantLines: aggregate.malformedRelevantLines
      )
    }
    return ModelUsageSnapshot(aggregate: aggregate, models: models)
  }

  private func discoverSessionFiles(now: Date) throws -> [SessionFile] {
    let cutoff = now.addingTimeInterval(-activeFileHorizon)
    var files: [SessionFile] = []
    let resourceKeys: Set<URLResourceKey> = [
      .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
    ]
    guard let enumerator = fileManager.enumerator(
      at: sessionsRoot,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      throw CocoaError(.fileReadNoPermission)
    }

    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let values = try url.resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true else { continue }
      let modifiedAt = values.contentModificationDate ?? .distantPast
      guard modifiedAt >= cutoff || cursors[url] != nil else { continue }
      files.append(
        SessionFile(
          url: url,
          size: UInt64(max(values.fileSize ?? 0, 0)),
          modifiedAt: modifiedAt
        )
      )
    }

    return files.sorted { $0.url.path < $1.url.path }
  }

  private func readAppendedContent(from file: SessionFile, retentionStart: Date) throws {
    var cursor = cursors[file.url] ?? FileCursor()
    if file.size < cursor.offset {
      cursor = FileCursor()
    }

    guard file.size > cursor.offset else {
      cursor.lastModified = file.modifiedAt
      cursors[file.url] = cursor
      return
    }

    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: cursor.offset)
    let fallbackSessionID = file.url.deletingPathExtension().lastPathComponent

    let endOffset = file.size
    var readOffset = cursor.offset
    while readOffset < endOffset {
      let appended = try autoreleasepool {
        try handle.read(upToCount: min(readChunkSize, Int(endOffset - readOffset)))
      }
      guard let appended, !appended.isEmpty else { break }
      readOffset += UInt64(appended.count)

      autoreleasepool {
        var combined = cursor.remainder
        combined.append(appended)
        let split = splitRelevantCompleteLines(combined)
        cursor.remainder = split.remainder

        let batch = TokenEventParser.parse(
          lines: split.lines,
          state: &cursor.parserState,
          fallbackSessionID: fallbackSessionID
        )
        malformedRelevantLines += batch.malformedRelevantLines

        for event in batch.events where event.timestamp >= retentionStart {
          if seenDeduplicationKeys[event.deduplicationKey] == nil {
            seenDeduplicationKeys[event.deduplicationKey] = event.timestamp
            events.append(event)
          }
        }
      }
    }

    cursor.offset = readOffset
    cursor.lastModified = file.modifiedAt
    cursors[file.url] = cursor
  }

  private func splitRelevantCompleteLines(
    _ data: Data
  ) -> (lines: [Data], remainder: Data) {
    guard let finalNewline = data.lastIndex(of: 0x0A) else {
      return ([], retainedIncompleteLine(data))
    }

    let completeEnd = data.index(after: finalNewline)
    let completeRange = data.startIndex..<completeEnd
    var lineStarts: Set<Data.Index> = []

    for marker in TokenEventParser.relevantMarkers {
      var searchStart = completeRange.lowerBound
      while searchStart < completeRange.upperBound,
        let match = data.range(
          of: marker,
          options: [],
          in: searchStart..<completeRange.upperBound
        )
      {
        let lineStart =
          data.range(
            of: Self.newline,
            options: .backwards,
            in: data.startIndex..<match.lowerBound
          )?.upperBound ?? data.startIndex
        lineStarts.insert(lineStart)
        searchStart = match.upperBound
      }
    }

    let lines = lineStarts.sorted().compactMap { start -> Data? in
      guard
        let end = data.range(
          of: Self.newline,
          options: [],
          in: start..<completeEnd
        )?.lowerBound, start < end
      else {
        return nil
      }
      let line = Data(data[start..<end])
      return line
    }
    let remainder =
      completeEnd < data.endIndex
      ? retainedIncompleteLine(data[completeEnd...])
      : Data()
    return (lines, remainder)
  }

  private func retainedIncompleteLine(_ data: Data) -> Data {
    if TokenEventParser.relevantMarkers.contains(where: { data.range(of: $0) != nil }) {
      return data
    }
    guard data.count > markerOverlapSize else { return data }
    return Data(data.suffix(markerOverlapSize))
  }

}
