import Foundation

struct RequestCallContent: Codable, Sendable, Hashable {
    let kind: String
    let title: String
    let text: String

    var displayTitle: String {
        if kind == "tool", title.hasPrefix("工具调用：") {
            let rawName = String(title.dropFirst("工具调用：".count))
            let name = rawName == "未记录名称" ? L10n.key(rawName) : rawName
            return L10n.string("工具调用：\(name)")
        }
        return L10n.key(title)
    }

    var displayText: String { kind == "source" ? L10n.key(text) : text }
}

struct RequestCallContext: Codable, Sendable, Hashable {
    var groupID: String?
    var groupPreview: String?
    var groupTimestamp: Double?
    var outputPreview: String?
    var outputKind: String?
    var message: String?
    var content: [RequestCallContent]?
    var sourceKind: String?
    var sourceTitle: String?
    var sourceDescription: String?
    var conversationTitle: String?
    var projectPath: String?
    var associationIssue: String?
    var subtaskID: String?
    var subtaskTitle: String?
    var subtaskTurnID: String?
    var parentConversationID: String?
    var rootConversationID: String?
    var rootConversationTitle: String?
    var attributionEvidence: String?
    var callSource: RequestCallContent?

    var associationExplanation: String? {
        switch associationIssue {
        case "overlap": return L10n.string("同一对话的调用时间重叠，无法可靠对应输出。")
        case "no_rollout": return L10n.string("未找到这次调用对应的本地对话文件，可能是未保存普通对话的后台调用。")
        case "no_user": return L10n.string("已找到对话记录，但无法确认这次调用对应的用户消息。")
        case "no_output": return L10n.string("已找到发起消息，但本地尚无可可靠关联的输出记录。")
        case "subtask_usage_ambiguous": return L10n.string("已确认子任务，但用量记录缺失或不唯一，暂不归入用户消息。")
        case "subtask_parent_missing", "subtask_dispatch_missing", "subtask_user_ambiguous", "subtask_turn_conflict", "subtask_cycle":
            return L10n.string("子任务的派发记录缺失或存在冲突，用户消息待关联。")
        default: return nil
        }
    }

    var displaySourceDescription: String? { sourceDescription.map(L10n.key) }
    var displaySubtaskTitle: String? { subtaskTitle.map { $0 == "子任务" ? L10n.key($0) : $0 } }

    var displayOutputPreview: String? {
        guard let outputPreview else { return nil }
        if ["suggestion", "compaction"].contains(outputKind ?? "") { return L10n.key(outputPreview) }
        if outputKind == "tool", outputPreview.hasPrefix("调用 ") {
            let names = outputPreview.dropFirst(3).components(separatedBy: "、")
                .map { $0 == "未记录名称" ? L10n.key($0) : $0 }
                .joined(separator: L10n.isChinese ? "、" : ", ")
            return L10n.string("调用 \(names)")
        }
        return outputPreview
    }

    var historyResolved: Bool {
        if ["suggestion", "compaction"].contains(sourceKind ?? ""), sourceTitle != nil, sourceDescription != nil { return true }
        return groupID != nil && groupPreview != nil && outputPreview != nil
    }

    var detailSections: [RequestCallContent] {
        let knownSource = callSource != nil || (["suggestion", "compaction"].contains(sourceKind ?? "") &&
            sourceTitle != nil && sourceDescription != nil)
        var sections: [RequestCallContent] = []
        if let message {
            sections.append(RequestCallContent(kind: "user", title: L10n.string("发起消息"), text: message))
        } else if !knownSource {
            sections.append(RequestCallContent(kind: "user", title: L10n.string("发起消息"), text: L10n.string("未找到关联的本地消息")))
        }
        if let callSource {
            sections.append(callSource)
        } else if knownSource {
            sections.append(RequestCallContent(kind: "source", title: sourceTitle!, text: sourceDescription!))
        }
        if sourceKind == "subagent" {
            sections.append(RequestCallContent(kind: "subtask", title: L10n.string("子任务"),
                text: [displaySubtaskTitle, associationExplanation].compactMap { $0 }.joined(separator: "\n")))
        }
        if let content, !content.isEmpty { sections += content }
        else if !knownSource {
            sections.append(RequestCallContent(kind: "output", title: L10n.string("本次调用"), text: L10n.string("未找到关联的本地输出")))
        }
        return sections
    }
}

struct RequestPresentationSnapshot: Sendable, Equatable {
    var speeds = RequestSpeedSnapshot()
    var contexts: [String: RequestCallContext] = [:]
    var ready = false
}

struct RequestBrowseFilter {
    var projectPath = ""
    var conversationID = ""
    var query = ""
    var source = ""

    func matches(_ sample: RequestSpeedSample, context: RequestCallContext?) -> Bool {
        if !projectPath.isEmpty && context?.projectPath != projectPath { return false }
        if !conversationID.isEmpty && (context?.rootConversationID ?? sample.conversationID) != conversationID { return false }
        let kind = context?.sourceKind ?? (context?.groupID == nil ? "unknown" : "conversation")
        if !source.isEmpty && source != kind { return false }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let text = [sample.model, context?.conversationTitle, context?.projectPath,
                    context?.groupPreview, context?.outputPreview,
                    context?.sourceTitle, context?.subtaskTitle, context?.rootConversationTitle].compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }
}

struct RequestHistoryGroup: Identifiable {
    let id: String
    let context: RequestCallContext?
    var samples: [RequestSpeedSample]
    var contexts: [String: RequestCallContext] = [:]

    var directSamples: [RequestSpeedSample] { samples.filter { contexts[$0.id]?.sourceKind != "subagent" } }

    // The parent is an existing measured call, never an extra request or group average.
    // Use the oldest available call in this filtered/retained history; older calls may be missing.
    var firstAvailable: RequestSpeedSample? {
        (directSamples.isEmpty ? samples : directSamples).min { left, right in
            let leftStart = left.startedAt ?? (left.completedAt - left.durationSeconds - left.ttftSeconds)
            let rightStart = right.startedAt ?? (right.completedAt - right.durationSeconds - right.ttftSeconds)
            if leftStart != rightStart { return leftStart < rightStart }
            return left.completedAt == right.completedAt ? left.id < right.id : left.completedAt < right.completedAt
        }
    }
    var continuations: [RequestSpeedSample] {
        guard let first = firstAvailable else { return [] }
        return samples.filter { $0.id != first.id }
    }

    static func make(_ samples: [RequestSpeedSample], contexts: [String: RequestCallContext]) -> [Self] {
        var groups: [Self] = []
        var positions: [String: Int] = [:]
        for sample in samples {
            let context = contexts[sample.id]
            let key = context?.groupID.map { "group-\($0)" } ?? context?.subtaskID.map { "subtask-\($0)" } ?? "request-\(sample.id)"
            if let position = positions[key] {
                groups[position].samples.append(sample)
                groups[position].contexts[sample.id] = context
            }
            else {
                positions[key] = groups.count
                groups.append(Self(id: key, context: context, samples: [sample], contexts: context.map { [sample.id: $0] } ?? [:]))
            }
        }
        return groups
    }
}

struct RequestHistoryRow: Identifiable {
    enum Kind { case api, userHeader, subtaskHeader }
    let sample: RequestSpeedSample
    let indented: Bool
    let preview: String?
    let groupID: String?
    let callCount: Int
    var kind: Kind = .api
    var depth: Int = 0
    var isAPI: Bool { kind == .api }
    var indent: Int { max(depth, indented ? 1 : 0) }
    var id: String { isAPI ? sample.id : "header-\(groupID!)" }
    var canExpand: Bool { groupID != nil && (!isAPI || callCount > 1) }
    var subtitle: String? {
        switch kind {
        case .subtaskHeader: return L10n.string("子任务")
        case .userHeader: return L10n.string("用户消息")
        case .api: return nil
        }
    }

    static func make(_ groups: [RequestHistoryGroup], expanded: Set<String>) -> [Self] {
        groups.flatMap { group in
            guard let first = group.firstAvailable else { return [Self]() }
            func children(_ samples: [RequestSpeedSample], depth: Int) -> [Self] {
                var buckets: [String: [RequestSpeedSample]] = [:]
                for sample in samples {
                    let key = group.contexts[sample.id]?.subtaskID.map { "subtask-\($0)" } ?? sample.id
                    buckets[key, default: []].append(sample)
                }
                return buckets.values.sorted {
                    $0[0].completedAt == $1[0].completedAt ? $0[0].id < $1[0].id : $0[0].completedAt > $1[0].completedAt
                }.flatMap { calls -> [Self] in
                    let sample = calls[0]
                    guard let context = group.contexts[sample.id], let task = context.subtaskID else {
                        return calls.map { Self(sample: $0, indented: depth > 0, preview: nil, groupID: nil, callCount: 1, depth: depth) }
                    }
                    let key = "subtask-\(task)"
                    let header = Self(sample: sample, indented: depth > 0, preview: context.displaySubtaskTitle ?? L10n.string("子任务"),
                        groupID: key, callCount: calls.count, kind: .subtaskHeader, depth: depth)
                    guard expanded.contains(key) else { return [header] }
                    return [header] + calls.map { Self(sample: $0, indented: true, preview: nil, groupID: nil, callCount: 1, depth: depth + 1) }
                }
            }
            guard let preview = group.context?.groupPreview else { return children(group.samples, depth: 0) }
            // A structural heading is not an API request and must never borrow
            // a child's TPS. Direct parent calls retain their measured header.
            let structural = group.directSamples.isEmpty
            let parent = Self(sample: first, indented: false, preview: preview, groupID: group.id,
                callCount: group.samples.count, kind: structural ? .userHeader : .api)
            guard expanded.contains(group.id) else { return [parent] }
            return [parent] + children(structural ? group.samples : group.continuations, depth: 1)
        }
    }

    static func visibleSelection(_ id: String?, groups: [RequestHistoryGroup], rows: [Self]) -> String? {
        guard let id, !rows.contains(where: { $0.id == id }) else { return id }
        guard let first = groups.first(where: { $0.samples.contains(where: { $0.id == id }) })?.firstAvailable,
              rows.contains(where: { $0.isAPI && $0.id == first.id }) else { return id }
        return first.id
    }
}

enum RequestMessageReader {
    static func summarySamples(_ samples: [RequestSpeedSample], previous: RequestPresentationSnapshot,
                               retryUnresolved: Bool = false, retryIDs: Set<String>? = nil) -> [RequestSpeedSample] {
        let prior = Dictionary(grouping: previous.speeds.history(model: "").filter { $0.conversationID != nil }, by: { $0.conversationID! })
        let current = Dictionary(grouping: samples.filter { $0.conversationID != nil }, by: { $0.conversationID! })
        var changed = Set(current.compactMap { conversation, calls -> String? in
            let unresolved = calls.contains { previous.contexts[$0.id]?.historyResolved != true &&
                (retryIDs == nil || retryIDs!.contains($0.id)) }
            let recent = calls.contains { Date().timeIntervalSince1970 - $0.completedAt < 120 }
            return !previous.ready || prior[conversation] != calls ||
                (retryUnresolved && recent && unresolved) ? conversation : nil
        })
        // Parent dispatch evidence can arrive after the child's output. Revisit
        // dependents on that same scheduled read, without another poll/timer.
        for _ in 0..<4 {
            let dependents = samples.compactMap { sample -> String? in
                guard let cid = sample.conversationID, let info = previous.contexts[sample.id],
                      [info.parentConversationID, info.rootConversationID].compactMap({ $0 }).contains(where: changed.contains) else { return nil }
                return cid
            }
            let count = changed.count; changed.formUnion(dependents)
            if changed.count == count { break }
        }
        // Include neighboring calls from each changed conversation: the
        // resolver needs their boundaries to reject ambiguous associations.
        return samples.filter { $0.conversationID.map(changed.contains) ?? false }
    }

    static func read(_ sample: RequestSpeedSample, home: URL) throws -> String? {
        try contexts([sample], home: home, fullID: sample.id)[sample.id]?.message
    }

    static func contexts(_ samples: [RequestSpeedSample], home: URL,
                         fullID: String? = nil) throws -> [String: RequestCallContext] {
        let data = try run(samples, home: home, arguments: ["--samples"] + (fullID.map { ["--full-id", $0] } ?? []))
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: RequestCallContext].self, from: data)
    }

    static func outputTimings(_ samples: [RequestSpeedSample], home: URL) throws -> [String: Double] {
        let data = try run(samples, home: home, arguments: ["--output-timings"])
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: Double].self, from: data)
    }

    private static func run(_ samples: [RequestSpeedSample], home: URL, arguments: [String]) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        guard let tool = Bundle.main.url(forResource: "request-context", withExtension: "py") else { throw SwapError.missingTool }
        return try ContextWorkerPool.run(samples, home: home, tool: tool, arguments: arguments)
    }
}

// Separate lanes preserve the existing foreground/background QoS contract.
// Each lane blocks on a pipe when idle; it has no polling or refresh timer.
// Only the current Codex home is retained (at most three lazy workers).
private enum ContextWorkerPool {
    private static let lock = NSLock()
    private static var scope = ""
    private static var workers: [Int: ContextWorker] = [:]

    static func run(_ samples: [RequestSpeedSample], home: URL, tool: URL, arguments: [String]) throws -> Data {
        let quality = WorkPriority.processQualityOfService
        let attributes = try FileManager.default.attributesOfItem(atPath: tool.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(home.path):\(tool.path):\(attributes[.systemFileNumber]!):\(attributes[.size]!):\(modified)"
        lock.lock()
        if scope != stamp { workers.removeAll(); scope = stamp }
        let worker: ContextWorker
        if let cached = workers[quality.rawValue] { worker = cached }
        else {
            worker = ContextWorker(home: home, tool: tool, quality: quality)
            workers[quality.rawValue] = worker
        }
        lock.unlock()
        return try worker.run(samples, arguments: arguments)
    }
}

private final class ContextWorker {
    private let lock = NSLock()
    private let home: URL
    private let tool: URL
    private let quality: QualityOfService
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(home: URL, tool: URL, quality: QualityOfService) {
        self.home = home; self.tool = tool; self.quality = quality
    }
    deinit { stop() }

    private func stop() {
        try? input?.close(); try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil
    }

    private func start() throws {
        let process = Process()
        process.qualityOfService = quality
        process.executableURL = URL(fileURLWithPath: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3")
        process.arguments = [tool.path, "--home", home.path, "--worker"]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
    }

    func run(_ samples: [RequestSpeedSample], arguments: [String]) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        do {
            if process?.isRunning != true { stop(); try start() }
            let request = Request(command: arguments.contains("--output-timings") ? "timings" : "contexts",
                samples: samples, fullID: arguments.firstIndex(of: "--full-id").map { arguments[$0 + 1] })
            // Bound a failed child without an idle watchdog. Killing only this
            // owned process unblocks pipe I/O; the next refresh starts fresh.
            let ownedProcess = process!
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .background))
            timeout.schedule(deadline: .now() + 30)
            timeout.setEventHandler {
                if ownedProcess.isRunning { kill(ownedProcess.processIdentifier, SIGKILL) }
            }
            timeout.resume()
            defer { timeout.cancel() }
            var encoded = try JSONEncoder().encode(request)
            encoded.append(10)
            try input!.write(contentsOf: encoded)
            var response = Data()
            while response.last != 10 {
                let chunk = output!.availableData
                guard !chunk.isEmpty, response.count + chunk.count <= 32 * 1024 * 1024 else {
                    throw SwapError.failed(L10n.string("无法读取本地对话记录"))
                }
                response.append(chunk)
            }
            let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            guard let result = reply?["result"], reply?["error"] == nil else {
                throw SwapError.failed(L10n.string("无法读取本地对话记录"))
            }
            return try JSONSerialization.data(withJSONObject: result)
        } catch {
            stop()
            throw error
        }
    }

    private struct Request: Encodable {
        let command: String
        let samples: [RequestSpeedSample]
        let fullID: String?
    }
}
