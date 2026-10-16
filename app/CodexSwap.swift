import Foundation
import Darwin

struct SlotRow: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let plan: String
    let email: String
    let active: Bool
    let five: Int?
    let fiveWhen: String
    let fiveResetAt: Double?
    let week: Int?
    let weekWhen: String
    let weekResetAt: Double?
    let fetchedAt: Double?
    var fiveWindowSeconds: Int? = nil
    var weekWindowSeconds: Int? = nil

    func withQuota(_ q: SlotQuota) -> SlotRow {
        SlotRow(
            name: name, plan: q.plan ?? plan, email: email, active: active,
            five: q.five, fiveWhen: q.fiveWhen, fiveResetAt: q.fiveResetAt,
            week: q.week, weekWhen: q.weekWhen, weekResetAt: q.weekResetAt,
            fetchedAt: q.fetchedAt ?? fetchedAt,
            fiveWindowSeconds: q.fiveWindowSeconds, weekWindowSeconds: q.weekWindowSeconds
        )
    }

    var planTitle: String {
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "free": return "Free"
        default: return plan == "?" ? "未知套餐" : plan
        }
    }

    var fiveWindowTitle: String { Self.windowTitle(fiveWindowSeconds, fallback: "5 小时") }
    var weekWindowTitle: String { Self.windowTitle(weekWindowSeconds, fallback: "7 天") }
    var hasSingleFreeWindow: Bool {
        plan.lowercased() == "free" && five != nil && fiveWindowSeconds != nil &&
            week == nil && weekWindowSeconds == nil
    }
    private static func windowTitle(_ seconds: Int?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }
        if seconds % 86400 == 0 { return "\(seconds / 86400) 天" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }
}

struct SlotQuota {
    var five: Int?
    var fiveWhen: String
    var fiveResetAt: Double?
    var week: Int?
    var weekWhen: String
    var weekResetAt: Double?
    var fresh: Bool = true
    var fetchedAt: Double?
    var plan: String? = nil
    var fiveWindowSeconds: Int? = nil
    var weekWindowSeconds: Int? = nil
}

struct ListState {
    var current: String
    var liveEmail: String
    var livePlan: String
    var warning: String?
    var slots: [SlotRow]
    var authExists: Bool
}

struct QuotaBatch {
    let quotas: [String: SlotQuota]
    let failed: [String]
}

enum SwapError: LocalizedError {
    case missingTool
    case badJSON
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool: return "App 内缺少 codex-swap 后端脚本"
        case .badJSON: return "codex-swap 返回的不是 JSON"
        case .failed(let s): return s
        }
    }
}

enum CodexSwap {
    static var toolURL: URL? {
        Bundle.main.url(forResource: "codex-swap", withExtension: "py")
    }

    /// fetch = false：只读本地缓存，不联网（打开 App 用）。
    /// fetch = true ：联网拉全部账号额度（只应由用户点刷新触发）。
    static func list(fetch: Bool = false) throws -> ListState {
        let obj = try run(fetch ? ["--json", "--fetch"] : ["--json"])
        guard obj["ok"] as? Bool != false else {
            throw SwapError.failed(obj["error"] as? String ?? "list failed")
        }
        let live = obj["live"] as? [String: Any] ?? [:]
        let slots = (obj["slots"] as? [[String: Any]] ?? []).map { s in
            SlotRow(
                name: s["name"] as? String ?? "?",
                plan: s["plan"] as? String ?? "?",
                email: s["email"] as? String ?? "?",
                active: s["active"] as? Bool ?? false,
                five: intish(s["five"]),
                fiveWhen: s["five_when"] as? String ?? "",
                fiveResetAt: doubleish(s["five_reset_at"]),
                week: intish(s["week"]),
                weekWhen: s["week_when"] as? String ?? "",
                weekResetAt: doubleish(s["week_reset_at"]),
                fetchedAt: doubleish(s["fetched_at"]),
                fiveWindowSeconds: intish(s["five_window_seconds"]),
                weekWindowSeconds: intish(s["week_window_seconds"])
            )
        }
        return ListState(
            current: obj["current"] as? String ?? "",
            liveEmail: live["email"] as? String ?? "?",
            livePlan: live["plan"] as? String ?? "?",
            warning: obj["warning"] as? String,
            slots: slots,
            authExists: obj["auth_exists"] as? Bool ?? false
        )
    }

    static func save(_ name: String) throws {
        _ = try ok(["--json", "save", name])
    }

    static func order(_ names: [String]) throws {
        _ = try ok(["--json", "order"] + names)
    }

    static func quota(name: String) throws -> SlotQuota {
        let obj = try ok(["--json", "quota", name])
        return parseQuota(obj)
    }

    static func quotas(names: [String]) throws -> QuotaBatch {
        let obj = try ok(["--json", "quotas"] + names, timeout: max(120, Double(names.count) * 8))
        let rows = obj["quotas"] as? [[String: Any]] ?? []
        var quotas: [String: SlotQuota] = [:]
        for row in rows {
            if let name = row["name"] as? String { quotas[name] = parseQuota(row) }
        }
        return QuotaBatch(quotas: quotas, failed: obj["failed"] as? [String] ?? [])
    }

    private static func parseQuota(_ obj: [String: Any]) -> SlotQuota {
        SlotQuota(
            five: intish(obj["five"]),
            fiveWhen: obj["five_when"] as? String ?? "",
            fiveResetAt: doubleish(obj["five_reset_at"]),
            week: intish(obj["week"]),
            weekWhen: obj["week_when"] as? String ?? "",
            weekResetAt: doubleish(obj["week_reset_at"]),
            fresh: obj["fresh"] as? Bool ?? true,
            fetchedAt: doubleish(obj["fetched_at"]),
            plan: obj["plan"] as? String,
            fiveWindowSeconds: intish(obj["five_window_seconds"]),
            weekWindowSeconds: intish(obj["week_window_seconds"])
        )
    }

    static func delete(_ name: String) throws {
        _ = try ok(["--json", "delete", name])
    }

    /// 只改文件；调用方必须先确认 Codex 已退出。
    static func switchTo(_ name: String) throws {
        _ = try ok(["--json", "--no-app", name])
    }

    static func add(_ name: String) throws {
        _ = try ok(["--json", "--no-app", "add", name])
    }

    private static func intish(_ v: Any?) -> Int? {
        if v is NSNull { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleish(_ v: Any?) -> Double? {
        if v is NSNull { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func pythonURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func ok(_ args: [String], timeout: TimeInterval = 45) throws -> [String: Any] {
        let obj = try run(args, timeout: timeout)
        if obj["ok"] as? Bool == false {
            throw SwapError.failed(obj["error"] as? String ?? "failed")
        }
        return obj
    }

    private static func run(_ args: [String], timeout: TimeInterval = 45) throws -> [String: Any] {
        guard let tool = toolURL, FileManager.default.isReadableFile(atPath: tool.path) else {
            throw SwapError.missingTool
        }
        guard let python = pythonURL() else {
            throw SwapError.failed("找不到 Python 3。请安装 Command Line Tools（终端运行 xcode-select --install）或 Homebrew Python。")
        }
        let p = Process()
        p.executableURL = python
        p.arguments = [tool.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let capture = ProcessOutputCapture()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            capture.set(out.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
            throw SwapError.failed("codex-swap 超时")
        }
        p.waitUntilExit()
        guard finished.wait(timeout: .now() + 3) == .success else {
            throw SwapError.failed("后台读取超时，请重试")
        }
        let data = capture.get()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwapError.badJSON
        }
        return obj
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
