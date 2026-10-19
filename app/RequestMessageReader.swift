import Foundation

struct RequestCallContent: Codable, Sendable, Hashable {
    let kind: String
    let title: String
    let text: String
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

    var historyResolved: Bool {
        if ["suggestion", "compaction"].contains(sourceKind ?? ""), sourceTitle != nil, sourceDescription != nil { return true }
        return groupID != nil && groupPreview != nil && outputPreview != nil
    }

    var detailSections: [RequestCallContent] {
        let knownSource = ["suggestion", "compaction"].contains(sourceKind ?? "") &&
            sourceTitle != nil && sourceDescription != nil
        var sections: [RequestCallContent] = []
        if let message {
            sections.append(RequestCallContent(kind: "user", title: "发起消息", text: message))
        } else if !knownSource {
            sections.append(RequestCallContent(kind: "user", title: "发起消息", text: "未找到关联的本地消息"))
        }
        if knownSource {
            sections.append(RequestCallContent(kind: "source", title: sourceTitle!, text: sourceDescription!))
        }
        if let content, !content.isEmpty { sections += content }
        else if !knownSource {
            sections.append(RequestCallContent(kind: "output", title: "本次调用", text: "未找到关联的本地输出"))
        }
        return sections
    }
}

struct RequestPresentationSnapshot: Sendable, Equatable {
    var speeds = RequestSpeedSnapshot()
    var contexts: [String: RequestCallContext] = [:]
    var ready = false
}

struct RequestHistoryGroup: Identifiable {
    let id: String
    let context: RequestCallContext?
    var samples: [RequestSpeedSample]

    // The parent is an existing measured call, never an extra request or group average.
    // Use the oldest available call in this filtered/retained history; older calls may be missing.
    var firstAvailable: RequestSpeedSample? {
        samples.min { left, right in
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
            let key = context?.groupID.map { "group-\($0)" } ?? "request-\(sample.id)"
            if let position = positions[key] { groups[position].samples.append(sample) }
            else {
                positions[key] = groups.count
                groups.append(Self(id: key, context: context, samples: [sample]))
            }
        }
        return groups
    }
}

struct RequestHistoryRow: Identifiable {
    let sample: RequestSpeedSample
    let indented: Bool
    let preview: String?
    let groupID: String?
    let callCount: Int
    var id: String { sample.id }
    var canExpand: Bool { groupID != nil && callCount > 1 }

    static func make(_ groups: [RequestHistoryGroup], expanded: Set<String>) -> [Self] {
        groups.flatMap { group in
            guard let preview = group.context?.groupPreview, let first = group.firstAvailable else {
                return group.samples.map { Self(sample: $0, indented: false, preview: nil, groupID: nil, callCount: 1) }
            }
            let parent = Self(sample: first, indented: false, preview: preview, groupID: group.id, callCount: group.samples.count)
            guard expanded.contains(group.id) else { return [parent] }
            return [parent] + group.continuations.map {
                Self(sample: $0, indented: true, preview: nil, groupID: nil, callCount: 1)
            }
        }
    }

    static func visibleSelection(_ id: String?, groups: [RequestHistoryGroup], rows: [Self]) -> String? {
        guard let id, !rows.contains(where: { $0.id == id }) else { return id }
        return groups.first { $0.samples.contains(where: { $0.id == id }) }?.firstAvailable?.id
    }
}

enum RequestMessageReader {
    static func summarySamples(_ samples: [RequestSpeedSample], previous: RequestPresentationSnapshot,
                               retryUnresolved: Bool = false) -> [RequestSpeedSample] {
        let prior = Dictionary(grouping: previous.speeds.history(model: "").filter { $0.conversationID != nil }, by: { $0.conversationID! })
        let current = Dictionary(grouping: samples.filter { $0.conversationID != nil }, by: { $0.conversationID! })
        let changed = Set(current.compactMap { conversation, calls -> String? in
            let unresolved = calls.contains { previous.contexts[$0.id]?.historyResolved != true }
            let recent = calls.contains { Date().timeIntervalSince1970 - $0.completedAt < 120 }
            return !previous.ready || prior[conversation] != calls ||
                (retryUnresolved && recent && unresolved) ? conversation : nil
        })
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
                    throw SwapError.failed("无法读取本地对话记录")
                }
                response.append(chunk)
            }
            let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            guard let result = reply?["result"], reply?["error"] == nil else {
                throw SwapError.failed("无法读取本地对话记录")
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
