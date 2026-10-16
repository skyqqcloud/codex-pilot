import Foundation

final class TelemetryCapture: @unchecked Sendable {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-swap")
    static let samplesURL = root.appendingPathComponent("telemetry/samples.json")
    private var process: Process?
    private var shutdown: NSObjectProtocol?
    var onExit: (@Sendable () -> Void)?

    private static var python: URL {
        URL(fileURLWithPath: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3")
    }

    func start() throws {
        guard process?.isRunning != true else { return }
        guard let tool = Bundle.main.url(forResource: "tps-capture", withExtension: "py") else { throw SwapError.missingTool }
        let p = Process()
        p.qualityOfService = .background
        p.executableURL = Self.python
        p.arguments = [tool.path, "serve", "--parent", String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.onExit?() }
        try p.run()
        process = p
        if shutdown == nil {
            shutdown = NotificationCenter.default.addObserver(forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
                object: nil, queue: .main) { [weak self] _ in self?.process?.terminate() }
        }
    }

    static func isConfigured(home: URL) -> Bool {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
        return text.contains("# BEGIN CODEX PILOT TPS\n") && text.contains("# END CODEX PILOT TPS\n")
    }

    static func configure(_ command: String) throws -> Bool {
        guard let tool = Bundle.main.url(forResource: "tps-capture", withExtension: "py") else { throw SwapError.missingTool }
        let p = Process()
        p.qualityOfService = .userInitiated
        p.executableURL = python
        p.arguments = [tool.path, command]
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SwapError.badJSON }
        guard result["ok"] as? Bool == true else { throw SwapError.failed(result["error"] as? String ?? "测速采集设置失败") }
        return result["enabled"] as? Bool ?? false
    }

    deinit {
        if let shutdown { NotificationCenter.default.removeObserver(shutdown) }
        if process?.isRunning == true { process?.terminate() }
    }
}
