import Foundation

struct RequestSpeedSample: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let model: String
    let completedAt: Double
    let outputTokens: Int
    let durationSeconds: Double
    let inputTokens: Int
    let reasoningTokens: Int
    let cachedTokens: Int
    let ttftSeconds: Double
    var nonReasoningDurationSeconds: Double? = nil
    var serviceTier: String? = nil
    var conversationID: String? = nil
    var startedAt: Double? = nil
    var promptPreview: String? = nil

    var isFast: Bool { serviceTier == "priority" || serviceTier == "fast" }
    // A presentation key only. Keep the API model and raw counters intact.
    var statisticsModel: String { model + (isFast ? "::fast" : "") }

    // Keep the API's original total and reasoning counts. TPS measures only
    // non-reasoning output; its duration must describe the same output phase.
    var streamedOutputTokens: Int {
        guard reasoningTokens >= 0, outputTokens >= reasoningTokens else { return 0 }
        return outputTokens - reasoningTokens
    }
    var outputDuration: Double? {
        let value = nonReasoningDurationSeconds ?? (reasoningTokens == 0 ? durationSeconds : nil)
        guard let value, value.isFinite, value >= 0.001, value <= 3600 else { return nil }
        if let start = startedAt {
            guard start.isFinite, completedAt.isFinite, start < completedAt,
                  value <= completedAt - start else { return nil }
        }
        return value
    }
    var outputWait: Double? {
        if let start = startedAt, let duration = outputDuration {
            let wait = completedAt - start - duration
            return wait.isFinite && wait >= 0 ? wait : nil
        }
        return outputDuration == nil ? nil : ttftSeconds
    }
    var rate: Double? {
        guard valid, streamedOutputTokens > 0, let duration = outputDuration else { return nil }
        let value = Double(streamedOutputTokens) / duration
        return value.isFinite ? value : nil
    }
    var valid: Bool {
        outputTokens > 0 && reasoningTokens >= 0 && reasoningTokens <= outputTokens &&
        inputTokens >= 0 && cachedTokens >= 0 && cachedTokens <= inputTokens &&
        durationSeconds.isFinite && durationSeconds >= 0.001 &&
        durationSeconds <= 3600 && completedAt.isFinite && !id.isEmpty && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (startedAt.map { $0.isFinite && $0 < completedAt && durationSeconds <= completedAt - $0 } ?? true)
    }
}

struct RequestSpeedAverage {
    let requestCount: Int
    let measuredCount: Int
    let value: Double?

    var explanation: String {
        L10n.string("最近 \(requestCount) 条已采集完成记录中，\(measuredCount) 条有可靠计时；按各次速度取算术平均，缺失值不当作 0，也不从更早记录补位。")
    }
}

struct RequestSpeedSnapshot: Codable, Sendable, Equatable {
    let samples: [RequestSpeedSample]
    private let ordered: [String: [RequestSpeedSample]]
    private let histories: [String: [RequestSpeedSample]]
    let modelNames: [String]

    private enum CodingKeys: CodingKey { case samples }

    init(samples: [RequestSpeedSample] = []) {
        self.samples = samples
        let valid = samples.filter(\.valid).sorted {
            $0.completedAt == $1.completedAt ? $0.id > $1.id : $0.completedAt > $1.completedAt
        }
        modelNames = Array(Set(valid.map(\.statisticsModel))).sorted()
        var buckets = Dictionary(grouping: valid, by: \.statisticsModel)
        buckets[""] = valid
        var ordered: [String: [RequestSpeedSample]] = [:]
        var histories: [String: [RequestSpeedSample]] = [:]
        for (model, bucket) in buckets {
            var seen: Set<String> = []
            let unique = bucket.filter { seen.insert($0.id).inserted }
            ordered[model] = unique
            var counts: [String: Int] = [:]
            histories[model] = unique.filter { sample in
                guard counts[sample.statisticsModel, default: 0] < 100 else { return false }
                counts[sample.statisticsModel, default: 0] += 1
                return true
            }
        }
        self.ordered = ordered
        self.histories = histories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(samples: try container.decode([RequestSpeedSample].self, forKey: .samples))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(samples, forKey: .samples)
    }

    func recent(model: String, count: Int = 5) -> [RequestSpeedSample] {
        Array((ordered[model] ?? []).prefix(count))
    }
    func latest(model: String) -> RequestSpeedSample? { recent(model: model, count: 1).first }
    func averageResult(model: String) -> RequestSpeedAverage {
        let requests = recent(model: model)
        let rates = requests.compactMap(\.rate)
        return RequestSpeedAverage(requestCount: requests.count, measuredCount: rates.count,
            value: rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count))
    }
    func average(model: String) -> Double? { averageResult(model: model).value }
    func history(model: String) -> [RequestSpeedSample] {
        histories[model] ?? []
    }
}
