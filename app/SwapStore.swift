import Foundation
import Combine
import SwiftUI
import ServiceManagement

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "跟随系统" : self == .light ? "浅色" : "深色" }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}

@MainActor
final class SwapStore: ObservableObject {
    @Published private(set) var current = ""
    @Published private(set) var livePlan = ""
    @Published private(set) var liveEmail = ""
    @Published private(set) var hasLiveAuth = false
    @Published private(set) var warning: String?
    @Published private(set) var slots: [SlotRow] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var errorMessage: String?
    @Published private(set) var pendingSaveAfterAdd: String?
    @Published private(set) var refreshingNames: Set<String> = []
    @Published private(set) var autoRefresh: Set<String> = []
    @Published private(set) var throughputLoaded = false
    @Published private(set) var throughputRefreshing = false
    @Published private(set) var requestPresentation = RequestPresentationSnapshot()
    @Published private(set) var captureEnabled = false
    @Published private(set) var captureError: String?
    @Published private(set) var selectedRequestID: String?
    @Published private(set) var contextRevision = 0
    @Published var selectedModel: String { didSet { selectedRequestID = nil; defaults.set(selectedModel, forKey: "ThroughputModel") } }
    @Published var showMenuBarTPS: Bool { didSet { defaults.set(showMenuBarTPS, forKey: "ShowMenuBarTPS") } }
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "Appearance") } }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var loginApprovalNeeded = false

    private let defaults: UserDefaults
    private let codexHome: URL
    private let speedFile: URL
    private let capture: TelemetryCapture?
    private var quotaTimer: Timer?
    private var fileObserver: TelemetryFileObserver?
    private var sampleStamp: TelemetryFileStamp?
    private var contextRetryTask: Task<Void, Never>?
    private var contextRetryAttempt = 0
    private var collectorRestartTask: Task<Void, Never>?
    private var collectorRestartAttempt = 0
    private var messageTask: Task<Void, Never>?
    private var lastAutoAttempt: [String: Date] = [:]
    private var lastPanelRefresh = Date()
    private var throughputTask: Task<Void, Never>?
    private var refreshRequested = false
    private var retryRequested = false

    init(defaults: UserDefaults = .standard, scanner: SessionScanner = SessionScanner(), speedFile: URL? = nil) {
        self.defaults = defaults
        codexHome = scanner.codexHome
        self.speedFile = speedFile ?? TelemetryCapture.samplesURL
        capture = speedFile == nil ? TelemetryCapture() : nil
        selectedModel = defaults.string(forKey: "ThroughputModel") ?? ""
        showMenuBarTPS = defaults.bool(forKey: "ShowMenuBarTPS")
        appearance = AppAppearance(rawValue: defaults.string(forKey: "Appearance") ?? "") ?? .system
        autoRefresh = Set(defaults.stringArray(forKey: "AutoRefreshSlots") ?? [])
        pendingSaveAfterAdd = defaults.string(forKey: "PendingSaveAfterAdd")
        launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        loginApprovalNeeded = SMAppService.mainApp.status == .requiresApproval
        capture?.onExit = { [weak self] in
            Task { @MainActor in self?.scheduleCollectorRestart() }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLocalState()
            self.startTimers()
            await self.refreshThroughput()
        }
    }

    var currentRow: SlotRow? { slots.first { $0.active } }
    var needsSave: Bool { warning != nil || pendingSaveAfterAdd != nil }
    var requestSpeeds: RequestSpeedSnapshot { requestPresentation.speeds }
    var requestContexts: [String: RequestCallContext] { requestPresentation.contexts }
    var requestHistoryReady: Bool { requestPresentation.ready }
    var latestSpeed: RequestSpeedSample? { requestSpeeds.latest(model: selectedModel) }
    var averageSpeed: Double? { requestSpeeds.average(model: selectedModel) }
    var recentSpeeds: [RequestSpeedSample] { requestSpeeds.history(model: selectedModel) }
    var detailSpeed: RequestSpeedSample? {
        recentSpeeds.first { $0.id == selectedRequestID } ?? latestSpeed
    }
    func selectRequest(_ id: String) {
        if recentSpeeds.contains(where: { $0.id == id }) { selectedRequestID = id }
    }
    func requestMessage(for sample: RequestSpeedSample) async -> String? {
        let home = codexHome
        return await Task.detached(priority: .userInitiated) {
            try? RequestMessageReader.read(sample, home: home)
        }.value
    }
    var requestGroups: [RequestHistoryGroup] {
        RequestHistoryGroup.make(recentSpeeds, contexts: requestContexts)
    }
    func loadRequestContexts() async {
        // Share startup/background preparation; reopening never launches a new
        // complete scan or temporarily pairs samples with empty contexts.
        if let throughputTask { await throughputTask.value }
        else if !requestHistoryReady { await refreshThroughput() }
    }
    func requestContext(for sample: RequestSpeedSample) async -> RequestCallContext? {
        let home = codexHome
        // Only this conversation is needed, including neighboring calls for boundary checks.
        let samples = requestSpeeds.history(model: "").filter { $0.conversationID == sample.conversationID }
        return await Task.detached(priority: .userInitiated) {
            try? RequestMessageReader.contexts(samples, home: home, fullID: sample.id)[sample.id]
        }.value
    }
    var modelNames: [String] {
        var names = requestSpeeds.modelNames
        if !selectedModel.isEmpty && !names.contains(selectedModel) { names.append(selectedModel) }
        return names.sorted()
    }
    var menuBarText: String { latestSpeed?.rate.map { String(format: "%.1f t/s", $0) } ?? "— t/s" }
    var lastFetchedAt: Date? { slots.compactMap(\.fetchedAt).max().map(Date.init(timeIntervalSince1970:)) }

    func refreshThroughput(retryUnresolved: Bool = false) async {
        if let throughputTask {
            // A file may change while the previous snapshot is being prepared.
            // Coalesce that event, then check it before leaving this refresh.
            refreshRequested = true
            retryRequested = retryRequested || retryUnresolved
            await throughputTask.value
            return
        }
        let task = Task {
            var retry = retryUnresolved
            repeat {
                self.refreshRequested = false
                await self.prepareThroughput(retryUnresolved: retry)
                retry = self.retryRequested
                self.retryRequested = false
            } while self.refreshRequested
            self.throughputTask = nil
        }
        throughputTask = task
        await task.value
    }

    private func prepareThroughput(retryUnresolved: Bool) async {
        defer {
            if throughputRefreshing { throughputRefreshing = false }
            if !throughputLoaded { throughputLoaded = true }
        }
        do {
            if let capture {
                try capture.start()
                let enabled = TelemetryCapture.isConfigured(home: codexHome)
                if captureEnabled != enabled { captureEnabled = enabled }
            } else if !captureEnabled { captureEnabled = true }
            if FileManager.default.fileExists(atPath: speedFile.path) {
                let stamp = try TelemetryFileStamp(speedFile)
                guard !requestHistoryReady || stamp != sampleStamp || retryUnresolved else {
                    if captureError != nil { captureError = nil }
                    return
                }
                throughputRefreshing = true
                if stamp != sampleStamp {
                    contextRetryTask?.cancel()
                    contextRetryTask = nil
                    contextRetryAttempt = 0
                }
                let file = speedFile, home = codexHome, previous = requestPresentation
                let presentation = try await Task.detached(priority: .utility) {
                    let snapshot = try JSONDecoder().decode(RequestSpeedSnapshot.self, from: Data(contentsOf: file))
                    let prior = Dictionary(previous.speeds.samples.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    let changedIDs = Set(snapshot.samples.filter { original in
                        guard var cached = prior[original.id] else { return true }
                        cached.nonReasoningDurationSeconds = original.nonReasoningDurationSeconds
                        return cached != original
                    }.map(\.id))
                    var samples = snapshot.samples.map { original in
                        var sample = original
                        if var cached = prior[sample.id] {
                            let duration = cached.nonReasoningDurationSeconds
                            cached.nonReasoningDurationSeconds = original.nonReasoningDurationSeconds
                            if cached == original && sample.nonReasoningDurationSeconds == nil {
                                sample.nonReasoningDurationSeconds = duration
                            }
                        }
                        return sample
                    }
                    let currentIDs = Dictionary(grouping: snapshot.samples.filter { $0.conversationID != nil }, by: { $0.conversationID! })
                        .mapValues { Set($0.map(\.id)) }
                    let previousIDs = Dictionary(grouping: previous.speeds.samples.filter { $0.conversationID != nil }, by: { $0.conversationID! })
                        .mapValues { Set($0.map(\.id)) }
                    var timingConversations = Set(samples.filter { sample in
                        sample.nonReasoningDurationSeconds == nil &&
                        (!previous.ready || changedIDs.contains(sample.id) ||
                         (retryUnresolved && Date().timeIntervalSince1970 - sample.completedAt < 120))
                    }.compactMap(\.conversationID))
                    timingConversations.formUnion(currentIDs.keys.filter { currentIDs[$0] != previousIDs[$0] })
                    // Neighboring calls remain part of timing validation so
                    // cache reuse cannot conceal overlapping streams.
                    let timingSamples = samples.filter { $0.conversationID.map(timingConversations.contains) ?? false }
                    let timings = (try? RequestMessageReader.outputTimings(timingSamples, home: home)) ?? [:]
                    for index in samples.indices {
                        if samples[index].conversationID.map(timingConversations.contains) == true {
                            samples[index].nonReasoningDurationSeconds = snapshot.samples[index].nonReasoningDurationSeconds ?? timings[samples[index].id]
                        }
                    }
                    let speeds = RequestSpeedSnapshot(samples: samples)
                    let history = speeds.history(model: "")
                    let pending = RequestMessageReader.summarySamples(history, previous: previous, retryUnresolved: retryUnresolved)
                    let refreshed = try RequestMessageReader.contexts(pending, home: home)
                    let retainedIDs = Set(history.map(\.id))
                    var contexts = previous.contexts.filter { retainedIDs.contains($0.key) }
                    // For refreshed conversations, a newly missing association
                    // replaces the previous one rather than borrowing stale text.
                    for sample in pending {
                        contexts[sample.id] = refreshed[sample.id]
                    }
                    return RequestPresentationSnapshot(speeds: speeds, contexts: contexts, ready: true)
                }.value
                // One publication: grouped metadata and the corresponding
                // numeric snapshot become visible in the same UI update.
                if requestPresentation != presentation {
                    requestPresentation = presentation
                    contextRevision += 1
                }
                sampleStamp = stamp
                scheduleContextRetry()
            } else if !requestHistoryReady {
                requestPresentation = RequestPresentationSnapshot(ready: true)
            }
            captureError = nil
        } catch { captureError = error.localizedDescription }
    }

    private func scheduleContextRetry() {
        guard capture != nil, contextRetryTask == nil, contextRetryAttempt < 3 else { return }
        let unresolved = requestSpeeds.samples.contains { sample in
            Date().timeIntervalSince1970 - sample.completedAt < 120 &&
                (requestContexts[sample.id]?.historyResolved != true || sample.nonReasoningDurationSeconds == nil)
        }
        guard unresolved else { return }
        let delay = [2, 10, 60][contextRetryAttempt]
        let expectedStamp = sampleStamp
        contextRetryAttempt += 1
        contextRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.contextRetryTask = nil
            // New traffic is already covered by the coalesced file observer.
            // A late-context retry must not bypass its active refresh budget.
            guard (try? TelemetryFileStamp(self.speedFile)) == expectedStamp else { return }
            await self.refreshThroughput(retryUnresolved: true)
        }
    }

    private func scheduleCollectorRestart() {
        captureError = collectorRestartAttempt < 3 ? "本机采集器已退出，正在重试…" : "本机采集器多次退出，请重新打开面板重试。"
        guard collectorRestartTask == nil, collectorRestartAttempt < 3 else { return }
        let delay = [2, 10, 60][collectorRestartAttempt]
        collectorRestartAttempt += 1
        collectorRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.collectorRestartTask = nil
            await self.refreshThroughput()
        }
    }

    func setCaptureEnabled(_ enabled: Bool) async {
        do {
            captureEnabled = try await Task.detached { try TelemetryCapture.configure(enabled ? "enable" : "disable") }.value
            captureError = nil
            notify("测速设置已更新，重启 Codex 后生效")
        } catch { captureError = error.localizedDescription }
    }

    func refreshLocalState() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await reload()
    }

    // Appearance and key-window notifications can arrive together. Show the
    // existing snapshot immediately and run at most one refresh for that opening.
    func refreshForPanel() async {
        guard Date().timeIntervalSince(lastPanelRefresh) >= 5 else { return }
        lastPanelRefresh = Date()
        collectorRestartAttempt = 0
        await refreshLocalState()
        await refreshThroughput()
    }

    private func reload() async {
        do {
            let state = try await Task.detached { try CodexSwap.list() }.value
            current = state.current
            livePlan = state.livePlan
            liveEmail = state.liveEmail
            hasLiveAuth = state.authExists
            warning = state.warning == nil ? nil : "当前登录尚未保存，先保存登录再切换。"
            slots = state.slots
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAllFetched() async { await fetchQuotas(names: slots.map(\.name), silent: false) }
    func refreshSlot(_ name: String) async { await fetchQuotas(names: [name], silent: false) }

    private func fetchQuotas(names: [String], silent: Bool) async {
        guard !busy, !names.isEmpty, !needsSave else { return }
        busy = true
        refreshingNames = Set(names)
        if !silent { errorMessage = nil; status = "正在刷新额度…" }
        defer { busy = false; refreshingNames.removeAll() }
        do {
            let batch = try await Task.detached { try CodexSwap.quotas(names: names) }.value
            for index in slots.indices {
                if let quota = batch.quotas[slots[index].name] { slots[index] = slots[index].withQuota(quota) }
            }
            if let active = slots.first(where: { $0.active }) { livePlan = active.plan }
            if batch.failed.isEmpty {
                errorMessage = nil
                if !silent { notify("账号额度已刷新") }
            } else {
                errorMessage = "\(batch.failed.count) 个账号未获取到新额度，仍显示上次数据。"
                if !silent { status = "" }
            }
        } catch {
            errorMessage = error.localizedDescription
            if !silent { status = "" }
        }
    }

    private func startTimers() {
        if fileObserver == nil, capture != nil {
            do {
                fileObserver = try TelemetryFileObserver(file: speedFile) { [weak self] in
                    Task { @MainActor in await self?.refreshThroughput() }
                }
            } catch { captureError = error.localizedDescription }
        }
        guard quotaTimer == nil, !autoRefresh.isEmpty else { return }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoTick() }
        }
        quotaTimer?.tolerance = 10
    }

    private func autoTick() async {
        guard !busy, !needsSave, !autoRefresh.isEmpty else { return }
        let now = Date()
        let due = slots.filter { row in
            guard autoRefresh.contains(row.name) else { return false }
            let fetched = row.fetchedAt.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            return now.timeIntervalSince(max(fetched, lastAutoAttempt[row.name] ?? .distantPast)) >= 300
        }.map(\.name)
        guard !due.isEmpty else { return }
        await refreshLocalState()
        guard !busy, !needsSave else { return }
        for name in due { lastAutoAttempt[name] = now }
        await fetchQuotas(names: due, silent: true)
    }

    func toggleAutoRefresh(_ name: String) {
        if autoRefresh.contains(name) { autoRefresh.remove(name); lastAutoAttempt[name] = nil }
        else { autoRefresh.insert(name) }
        defaults.set(Array(autoRefresh).sorted(), forKey: "AutoRefreshSlots")
        if autoRefresh.isEmpty { quotaTimer?.invalidate(); quotaTimer = nil }
        else { startTimers() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginApprovalNeeded = SMAppService.mainApp.status == .requiresApproval
            launchAtLogin = enabled
        } catch { errorMessage = "登录时启动设置失败：\(error.localizedDescription)" }
    }

    func switchTo(_ row: SlotRow) async {
        guard !busy, !needsSave, !row.active else { return }
        busy = true
        errorMessage = nil
        status = "正在退出 Codex…"
        defer { busy = false }
        guard await Task.detached(operation: { DesktopClient.quit() }).value else {
            errorMessage = "Codex 尚未退出，切换已取消。请先退出 Codex 再重试。"
            status = ""
            return
        }
        do {
            try await Task.detached { try CodexSwap.switchTo(row.name) }.value
            await reload()
            let opened = await Task.detached { DesktopClient.open() }.value
            notify("已切换到 \(row.planTitle)")
            if !opened { errorMessage = "登录已切换，请手动打开 Codex。" }
        } catch {
            errorMessage = error.localizedDescription
            status = ""
            _ = await Task.detached { DesktopClient.open() }.value
        }
    }

    func saveCurrent() async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        // An untagged login must not overwrite the previously saved account.
        let name = pendingSaveAfterAdd ?? (warning != nil || current.isEmpty ? unusedInternalName() : current)
        do {
            try await Task.detached { try CodexSwap.save(name) }.value
            setPending(nil)
            await reload()
            notify("当前登录已保存")
        } catch { errorMessage = error.localizedDescription }
    }

    func addNew() async {
        guard !busy, !needsSave else { return }
        busy = true
        errorMessage = nil
        status = "正在退出 Codex…"
        defer { busy = false }
        guard await Task.detached(operation: { DesktopClient.quit() }).value else {
            errorMessage = "Codex 尚未退出，添加账号已取消。"
            status = ""
            return
        }
        let name = unusedInternalName()
        do {
            try await Task.detached { try CodexSwap.add(name) }.value
            setPending(name)
            await reload()
            if await Task.detached(operation: { DesktopClient.open() }).value { status = "" }
            else { errorMessage = "请手动打开 Codex 登录，然后保存登录。" }
        } catch {
            errorMessage = error.localizedDescription
            status = ""
            _ = await Task.detached { DesktopClient.open() }.value
        }
    }

    func returnToPreviousAccount() async {
        guard !busy, pendingSaveAfterAdd != nil, slots.contains(where: { $0.name == current }) else { return }
        let previous = current
        busy = true
        errorMessage = nil
        defer { busy = false }
        guard await Task.detached(operation: { DesktopClient.quit() }).value else {
            errorMessage = "Codex 尚未退出，请先退出再返回原账号。"; return
        }
        do {
            // Retain any newly completed login before restoring the original account.
            let fresh = try await Task.detached { try CodexSwap.list() }.value
            if fresh.authExists {
                let newSlot = pendingSaveAfterAdd ?? unusedInternalName()
                try await Task.detached { try CodexSwap.save(newSlot) }.value
            }
            try await Task.detached { try CodexSwap.switchTo(previous) }.value
            setPending(nil)
            await reload()
            let opened = await Task.detached { DesktopClient.open() }.value
            notify("已返回原账号")
            if !opened { errorMessage = "请手动打开 Codex。" }
        } catch {
            errorMessage = error.localizedDescription
            _ = await Task.detached { DesktopClient.open() }.value
        }
    }

    func delete(_ row: SlotRow) async {
        guard !busy, row.name != current else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await Task.detached { try CodexSwap.delete(row.name) }.value
            autoRefresh.remove(row.name)
            defaults.set(Array(autoRefresh).sorted(), forKey: "AutoRefreshSlots")
            await reload()
            notify("账号已删除")
        } catch { errorMessage = error.localizedDescription }
    }

    func canMoveUp(_ name: String) -> Bool { (slots.firstIndex { $0.name == name } ?? 0) > 0 }
    func canMoveDown(_ name: String) -> Bool { (slots.firstIndex { $0.name == name } ?? slots.count) < slots.count - 1 }
    func move(_ name: String, direction: Int) async {
        guard let index = slots.firstIndex(where: { $0.name == name }) else { return }
        let target = index + direction
        guard slots.indices.contains(target) else { return }
        await move(name, before: slots[target].name, insertAfter: direction > 0)
    }

    func move(_ name: String, before destination: String, insertAfter: Bool = false) async {
        guard !busy, name != destination else { return }
        var names = slots.map(\.name)
        guard let index = names.firstIndex(of: name) else { return }
        names.remove(at: index)
        guard let target = names.firstIndex(of: destination) else { return }
        names.insert(name, at: target + (insertAfter ? 1 : 0))
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await Task.detached { try CodexSwap.order(names) }.value
            await reload()
            notify("账号顺序已保存")
        } catch { errorMessage = error.localizedDescription }
    }

    func openCodex() async { _ = await Task.detached { DesktopClient.open() }.value }
    private func setPending(_ name: String?) { pendingSaveAfterAdd = name; defaults.set(name, forKey: "PendingSaveAfterAdd") }
    private func unusedInternalName() -> String {
        let used = Set(slots.map(\.name)); var index = 1
        while used.contains("n\(index)") { index += 1 }
        return "n\(index)"
    }
    private func notify(_ message: String) {
        messageTask?.cancel()
        status = message
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.status == message { self?.status = "" }
        }
    }
}
