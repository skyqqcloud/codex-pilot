import AppKit
import SwiftUI
import SQLite3

@MainActor
final class ScrollFixtureState: ObservableObject {
    @Published var pulse = 0
}

final class FileEventCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

struct ScrollFixture: View {
    @ObservedObject var state: ScrollFixtureState
    @ObservedObject var store: SwapStore
    let maximumHeight: CGFloat
    let scheme: ColorScheme
    var body: some View {
        VStack(spacing: 0) {
            Text("模型吞吐").frame(height: 43)
            BoundedPanelScrollView(maximumHeight: maximumHeight) {
                ThroughputDetailPanel(store: store)
                    .overlay(alignment: .topLeading) { Color.clear.id(state.pulse) }
            }
        }
        .frame(width: PanelLayout.width)
        .environment(\.colorScheme, scheme)
    }
}

struct NaturalDetailFixture: View {
    @ObservedObject var store: SwapStore
    let scheme: ColorScheme
    var body: some View {
        VStack(spacing: 0) {
            Text("输出测速").frame(height: 43)
            ThroughputDetailPanel(store: store).fixedSize(horizontal: false, vertical: true)
        }.frame(width: PanelLayout.width)
            .background(PanelPalette(scheme: scheme).paper)
            .environment(\.colorScheme, scheme)
    }
}

@main
@MainActor
struct ScrollLayoutCheck {
    static func checkVersion3(store: SwapStore, base: URL) async throws {
        store.selectedModel = "gpt-6.1-sol::fast"
        precondition(store.recentSpeeds.count == 2 && store.averageSpeed == 140 && store.latestSpeed?.rate == 90,
                     "native Fast picker mixes standard and Fast samples")
        precondition(PanelFormat.model(store.selectedModel) == "gpt-6.1-sol · Fast", "virtual model key leaks into UI")
        store.selectedModel = "gpt-6.1-sol"
        precondition(store.averageSpeed == 62 && store.latestSpeed?.rate == 80, "standard statistics changed")
        let sample = store.latestSpeed!
        let context = store.requestContexts[sample.id]!
        precondition(context.projectPath == "/projects/Codex Pilot" && context.conversationTitle == "Native layout checks",
                     "exact project/conversation metadata was not surfaced")
        precondition(RequestBrowseFilter(projectPath: "/projects/Codex Pilot", query: "Native layout").matches(sample, context: context),
                     "project and title search do not combine")
        precondition(!RequestBrowseFilter(projectPath: "/projects/Other").matches(sample, context: context) &&
                     !RequestBrowseFilter(source: "suggestion").matches(sample, context: context), "filters fabricate provenance")
        precondition(RequestBrowseFilter(source: "conversation").matches(sample, context: context) &&
                     !RequestBrowseFilter(projectPath: "/projects/Codex Pilot").matches(sample, context: nil), "unknown source is assigned a project")
        precondition(RequestCallContext(associationIssue: "overlap").associationExplanation != nil,
                     "association evidence reason missing")
        for scheme in [ColorScheme.light, .dark] {
            let state = RequestBrowserState()
            let root = NSHostingView(rootView: RequestBrowserView(store: store, state: state).environment(\.colorScheme, scheme))
            root.setFrameSize(NSSize(width: 1000, height: 720))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFront(nil)
            for _ in 0..<20 {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let tables = findScrolls(root).compactMap { $0.documentView as? NSTableView }
            precondition(tables.count == 1 && tables[0].numberOfRows == 99, "wide history lost default collapsed groups")
            precondition(tables[0].frame.width >= 340, "wide virtual rows have invalid width")
            state.query = "NO_MATCH_FOR_ANY_CALL"
            await Task.yield(); root.layoutSubtreeIfNeeded()
            precondition(findScrolls(root).compactMap { $0.documentView as? NSTableView }.isEmpty, "empty search retained unrelated rows")
            state.query = ""; state.project = "/projects/Codex Pilot"
            await Task.yield(); root.layoutSubtreeIfNeeded()
            let filtered = findScrolls(root).compactMap { $0.documentView as? NSTableView }
            precondition(filtered.first?.numberOfRows == 2, "project filtering did not preserve the two user-message groups")
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 10_000_000)
                root.layoutSubtreeIfNeeded()
            }
            let image = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("browser-\(scheme).png"))
            window.contentView = nil; window.close()
            let status = NSHostingView(rootView: RunStatusPanel(store: store).frame(width: 380).environment(\.colorScheme, scheme))
            status.setFrameSize(NSSize(width: 380, height: 650)); status.layoutSubtreeIfNeeded()
            await Task.yield()
            precondition(status.fittingSize.height > 300 && status.fittingSize.width <= 381, "status page has invalid bounds")
        }
        RequestBrowserWindow.show(store: store)
        precondition(RequestBrowserWindow.isOpen, "details window did not open")
        RequestBrowserWindow.show(store: store)
        let windows = NSApp.windows.filter { $0.identifier?.rawValue == "request-browser" }
        precondition(windows.count == 1, "opening twice duplicated the details window")
        windows[0].close()
        precondition(!RequestBrowserWindow.isOpen && windows[0].contentView == nil, "closing retains observed views")
        let original = store.currentRow!
        let quota = SlotQuota(five: 9, fiveWhen: "", fiveResetAt: 1000, week: 50, weekWhen: "", weekResetAt: 2000, fetchedAt: 1)
        let low = original.withQuota(quota)
        precondition(LowQuotaAlerts.cycles(low).count == 1 && LowQuotaAlerts.cycles(original).isEmpty,
                     "low-quota thresholds use unknown values or the wrong account")
        let weekly = original.withQuota(SlotQuota(five: 50, fiveWhen: "", fiveResetAt: 1000, week: 9, weekWhen: "", weekResetAt: 2000, fetchedAt: 1))
        let nextFive = weekly.withQuota(SlotQuota(five: 100, fiveWhen: "", fiveResetAt: 3000, week: 9, weekWhen: "", weekResetAt: 2000, fetchedAt: 2))
        precondition(LowQuotaAlerts.cycles(weekly) == LowQuotaAlerts.cycles(nextFive), "five-hour reset repeats a weekly quota alert")
        precondition(!store.lowQuotaAlerts, "notifications enabled without user opt-in")
        store.selectedModel = "gpt-6.1-sol"
        print("3.0: isolated Fast statistics, exact project filters, search, light/dark two-pane views, window release, readiness and opt-in alerts passed.")
    }

    static func checkQuotaTrends(store: SwapStore, base: URL) async throws {
        let suite = "QuotaRangeChecks-\(UUID().uuidString)"
        let rangePrefs = UserDefaults(suiteName: suite)!
        defer { rangePrefs.removePersistentDomain(forName: suite) }
        let before = store.requestSpeeds.samples
        let url = base.appendingPathComponent("fixtures/quota-history.sqlite3")
        let row = SlotRow(name: "history-fixture", plan: "pro", email: "history@example.test", active: false,
            five: 12, fiveWhen: "", fiveResetAt: nil, week: 62, weekWhen: "", weekResetAt: nil,
            fetchedAt: Date().timeIntervalSince1970, fiveWindowSeconds: 18000, weekWindowSeconds: 604800,
            quotaHistoryID: String(repeating: "a", count: 64))
        let model = QuotaTrendModel(row: row, historyURL: url, defaults: rangePrefs)
        await model.load()
        precondition(!model.error && model.snapshot.observations.count > 250)
        precondition(QuotaTrendRange.allCases.map(\.rawValue) == [3600, 10800, 86400, 604800], "incorrect quota time ranges")
        precondition(model.range == .day && model.visibleWindows == [.primary, .secondary])
        for (range, counts) in [(QuotaTrendRange.hour, 10...13), (.threeHours, 34...37)] {
            model.range = range
            let points = model.series(for: .primary).points
            precondition(counts.contains(points.count) && points.allSatisfy { $0.time >= model.now - Double(range.rawValue) },
                         "hourly range used day units or included older samples")
        }
        let weeklyOnly = row.withQuota(SlotQuota(five: nil, fiveWhen: "", fiveResetAt: nil, week: 62, weekWhen: "", weekResetAt: nil, fetchedAt: model.now))
        let weeklyModel = QuotaTrendModel(row: weeklyOnly, historyURL: url, defaults: rangePrefs)
        weeklyModel.snapshot = model.snapshot; weeklyModel.loading = false
        precondition(weeklyModel.visibleWindows == [.secondary], "missing five-hour quota still has a chart")
        let zero = row.withQuota(SlotQuota(five: 0, fiveWhen: "", fiveResetAt: nil, week: 62, weekWhen: "", weekResetAt: nil, fetchedAt: model.now))
        precondition(QuotaTrendModel(row: zero, defaults: rangePrefs).visibleWindows == [.primary, .secondary], "zero quota was treated as missing")
        let free = row.withQuota(SlotQuota(five: 100, fiveWhen: "", fiveResetAt: nil, week: nil, weekWhen: "", weekResetAt: nil,
                                         fetchedAt: model.now, plan: "free", fiveWindowSeconds: 2592000))
        precondition(QuotaTrendModel(row: free, defaults: rangePrefs).visibleWindows == [.primary], "Free's 30-day quota was hidden")
        let mainHost = NSHostingView(rootView: ContentView(store: store, quotaHistoryURL: url))
        mainHost.setFrameSize(NSSize(width: 380, height: 650))
        for _ in 0..<10 { await Task.yield(); mainHost.layoutSubtreeIfNeeded() }
        func anchors(_ view: NSView) -> [QuotaTrendAnchorView] {
            (view as? QuotaTrendAnchorView).map { [$0] } ?? view.subviews.flatMap { anchors($0) }
        }
        let mainAnchors = anchors(mainHost)
        precondition(mainAnchors.count == store.slots.count && mainAnchors.allSatisfy { $0.frame.height >= 70 && $0.frame.width >= 340 },
                     "account background has no usable native hover target")
        for scheme in [ColorScheme.light, .dark] {
            for range in QuotaTrendRange.allCases {
                model.range = range
                let host = NSHostingView(rootView: QuotaTrendPanel(model: model).environment(\.colorScheme, scheme))
                host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: 480))
                for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
                let height = host.fittingSize.height
                precondition(height > 260 && height < 420, "quota panel does not fit its compact layout")
                host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: height)); host.layoutSubtreeIfNeeded()
                let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("quota-\(scheme)-\(range.rawValue).png"))
            }
            let single = NSHostingView(rootView: QuotaTrendPanel(model: weeklyModel).environment(\.colorScheme, scheme))
            single.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: 480))
            for _ in 0..<10 { await Task.yield(); single.layoutSubtreeIfNeeded() }
            precondition(single.fittingSize.height < 260, "single quota panel retained unnecessary rows")
            single.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: single.fittingSize.height)); single.layoutSubtreeIfNeeded()
            let image = single.bitmapImageRepForCachingDisplay(in: single.bounds)!
            single.cacheDisplay(in: single.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("quota-week-only-\(scheme).png"))
        }
        let curveSuite = suite + "-curve"
        let curvePrefs = UserDefaults(suiteName: curveSuite)!
        defer { curvePrefs.removePersistentDomain(forName: curveSuite) }
        let curveRow = SlotRow(name: "curve-preview", plan: "team", email: "curve@example.test", active: false,
            five: 83, fiveWhen: "", fiveResetAt: model.now+10000, week: 79, weekWhen: "", weekResetAt: model.now+500000,
            fetchedAt: model.now-300, fiveWindowSeconds: 18000, weekWindowSeconds: 604800)
        let curveModel = QuotaTrendModel(row: curveRow, defaults: curvePrefs)
        curveModel.range = .hour; curveModel.loading = false; curveModel.now = model.now
        let fiveValues = [100,100,100,100,100,97,94,90,83], weekValues = [82,82,82,82,81,81,81,79,79]
        curveModel.snapshot = QuotaHistorySnapshot(observations: fiveValues.indices.map { i in
            QuotaObservation(time: model.now-2700+Double(i)*300, plan: "team", five: fiveValues[i], week: weekValues[i],
                fiveSeconds: 18000, weekSeconds: 604800, fiveReset: curveRow.fiveResetAt, weekReset: curveRow.weekResetAt)
        })
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: QuotaTrendPanel(model: curveModel).environment(\.colorScheme, scheme))
            host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: 420))
            for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: host.fittingSize.height)); host.layoutSubtreeIfNeeded()
            let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("quota-smooth-\(scheme).png"))
        }
        let freeModel = QuotaTrendModel(row: free, defaults: curvePrefs)
        freeModel.range = .hour; freeModel.loading = false; freeModel.now = model.now
        freeModel.snapshot = QuotaHistorySnapshot(observations: (0..<12).map { i in
            let sampledAt = model.now - 3420 + Double(i) * 300
            return QuotaObservation(time: sampledAt, plan: "free", five: 100, week: nil,
                fiveSeconds: 2592000, weekSeconds: nil, fiveReset: sampledAt + 2592000 - 1, weekReset: nil)
        })
        let freeSeries = freeModel.series(for: .primary)
        precondition(freeSeries.segments.count == 1 && freeSeries.boundaries.isEmpty &&
                     QuotaTrendCurve.make(freeSeries.points).count == 11,
                     "Free UI split rolling full quota into isolated points")
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: QuotaTrendPanel(model: freeModel).environment(\.colorScheme, scheme))
            host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: 420))
            for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            precondition(host.fittingSize.height < 260, "Free panel retained missing quota windows")
            host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: host.fittingSize.height)); host.layoutSubtreeIfNeeded()
            let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("quota-free-idle-\(scheme).png"))
        }
        let gapRow = weeklyOnly.withQuota(SlotQuota(five: nil, fiveWhen: "", fiveResetAt: nil,
            week: 88, weekWhen: "", weekResetAt: model.now + 5*86400, fetchedAt: model.now-360))
        let gapModel = QuotaTrendModel(row: gapRow, defaults: curvePrefs)
        gapModel.range = .day; gapModel.loading = false; gapModel.now = model.now
        let hoursAgo: [Double] = [23,22.9,22.8,21,20,19,18,17,16,15,14,13,12,9,8.9,8.8,0.1]
        gapModel.snapshot = QuotaHistorySnapshot(observations: hoursAgo.enumerated().map { i, hours in
            QuotaObservation(time: model.now-hours*3600, plan: "pro", five: nil, week: max(88,100-i),
                fiveSeconds: nil, weekSeconds: 604800, fiveReset: nil, weekReset: gapRow.weekResetAt)
        })
        let gapSeries = gapModel.series(for: .secondary)
        precondition(gapSeries.segments.count > 10 && gapSeries.displaySegments.count == 1 &&
                     gapSeries.boundaries.isEmpty && gapSeries.hourlyDrop(now: model.now) == nil,
                     "gap preview lost continuous display or changed sampling-based statistics")
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: QuotaTrendPanel(model: gapModel).environment(\.colorScheme, scheme))
            host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: 420))
            for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            host.setFrameSize(NSSize(width: QuotaTrendPanel.width, height: host.fittingSize.height)); host.layoutSubtreeIfNeeded()
            let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("quota-connected-gaps-\(scheme).png"))
        }
        let controller = QuotaTrendController(defaults: rangePrefs)
        let parent = NSWindow(contentRect: NSRect(x: 500, y: 200, width: 380, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let anchor = QuotaTrendAnchorView(controller: controller, row: row, scheme: .light, historyURL: url, refresh: {})
        parent.contentView = anchor
        parent.orderFront(nil)
        controller.entered(anchor); controller.exited(anchor)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(!controller.isOpen, "quick pointer crossing opened a chart")
        controller.entered(anchor)
        try await Task.sleep(nanoseconds: 450_000_000)
        precondition(controller.isOpen && parent.childWindows?.count == 1, "hover did not open one child panel")
        controller.exited(anchor); controller.panelHover(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(controller.isOpen, "moving into the chart closed it")
        let child = parent.childWindows!.first!
        controller.panelHover(false)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(controller.isOpen, "chart closed while choosing the time range")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        controller.inspectInfo(true)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(controller.isOpen, "chart closed while reading its information popover")
        controller.inspectInfo(false)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(!controller.isOpen && child.contentView == nil && parent.childWindows?.isEmpty != false,
                     "closed quota panel retained its hosted graph")
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900), size = NSSize(width: 360, height: 440)
        let right = QuotaTrendController.frame(anchor: NSRect(x: 10, y: 100, width: 360, height: 78), parent: NSRect(x: 0, y: 100, width: 380, height: 600), screen: screen, size: size)
        precondition(right.minX == 388 && screen.contains(right), "left-edge panel didn't open on the right")
        controller.open(row.name)
        precondition(controller.isOpen)
        parent.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: parent)
        precondition(!controller.isOpen, "hiding the menu retained its chart")
        parent.orderFront(nil); controller.open(row.name)
        controller.removed(anchor)
        precondition(!controller.isOpen, "removing the main panel left an orphan chart")
        controller.register(anchor)
        controller.open(row.name)
        let active = parent.childWindows!.first!
        let picker = findPickers(active.contentView!).first!
        picker.selectItem(at: 0)
        _ = picker.sendAction(picker.action!, to: picker.target)
        precondition(rangePrefs.integer(forKey: QuotaTrendModel.rangePreferenceKey) == 3600, "picker did not persist its range")
        let other = SlotRow(name: "other-account", plan: "team", email: "other@example.test", active: false,
            five: nil, fiveWhen: "", fiveResetAt: nil, week: 80, weekWhen: "", weekResetAt: nil, fetchedAt: model.now)
        let otherAnchor = QuotaTrendAnchorView(controller: controller, row: other, scheme: .light, historyURL: url, refresh: {})
        anchor.addSubview(otherAnchor); otherAnchor.frame = NSRect(x: 0, y: 0, width: 380, height: 70)
        controller.register(otherAnchor); controller.open(other.name)
        for _ in 0..<8 { await Task.yield(); parent.childWindows?.first?.contentView?.layoutSubtreeIfNeeded() }
        precondition(findPickers(parent.childWindows!.first!.contentView!).first?.title == QuotaTrendRange.hour.title,
                     "switching account reset the globally selected range")
        controller.close()
        let reopened = QuotaTrendController(defaults: UserDefaults(suiteName: suite)!)
        let reopenedAnchor = QuotaTrendAnchorView(controller: reopened, row: row, scheme: .light, historyURL: url, refresh: {})
        anchor.addSubview(reopenedAnchor); reopenedAnchor.frame = otherAnchor.frame
        reopened.register(reopenedAnchor); reopened.open(row.name)
        for _ in 0..<8 { await Task.yield(); parent.childWindows?.first?.contentView?.layoutSubtreeIfNeeded() }
        precondition(findPickers(parent.childWindows!.first!.contentView!).first?.title == QuotaTrendRange.hour.title,
                     "reopening a card lost the persisted range")
        reopened.close()
        try checkQuotaRangeAcrossProcesses(suite: suite)
        rangePrefs.set(-1, forKey: QuotaTrendModel.rangePreferenceKey)
        precondition(QuotaTrendModel(row: row, defaults: rangePrefs).range == .day, "invalid saved range was not handled")
        parent.contentView = nil; parent.close()
        precondition(before == store.requestSpeeds.samples, "quota history changed TPS samples")
        print("Quota UI: compact layout in both themes and 4 ranges; picker persistence, cross-account sharing, process restart, 1h/3h boundaries, missing/zero/Free quotas, information popover handover, release and unchanged TPS passed.")
    }

    static func quotaRangeProbe(_ suite: String, _ action: String) {
        let prefs = UserDefaults(suiteName: suite)!
        let row = SlotRow(name: "probe", plan: "pro", email: "probe@example.test", active: false,
            five: nil, fiveWhen: "", fiveResetAt: nil, week: 50, weekWhen: "", weekResetAt: nil, fetchedAt: nil)
        let model = QuotaTrendModel(row: row, defaults: prefs)
        if action == "write" { model.range = .threeHours }
        print(model.range.rawValue)
    }

    static func checkQuotaRangeAcrossProcesses(suite: String) throws {
        func probe(_ action: String) throws -> String {
            let child = Process(), pipe = Pipe()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--quota-range-probe", suite, action]
            child.standardOutput = pipe
            try child.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            precondition(child.terminationStatus == 0)
            return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let written = try probe("write"), restored = try probe("read")
        precondition(written == "10800", "writer process failed to select three hours")
        precondition(restored == "10800", "new process lost the stored quota range")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--quota-range-probe" {
            quotaRangeProbe(CommandLine.arguments[2], CommandLine.arguments[3]); return
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        checkLocalization()
        let prefs = UserDefaults(suiteName: "ScrollLayoutCheck")!
        prefs.setVolatileDomain(["ThroughputWindow": 300], forName: "ScrollLayoutCheck")
        let store = SwapStore(defaults: prefs, scanner: SessionScanner(codexHome: base.appendingPathComponent("fixtures")),
                              speedFile: base.appendingPathComponent("fixtures/speeds.json"))
        let coldView = NSHostingView(rootView: NaturalDetailFixture(store: store, scheme: .light))
        coldView.setFrameSize(NSSize(width: 380, height: 800))
        coldView.layoutSubtreeIfNeeded()
        precondition(!store.requestHistoryReady && findScrolls(coldView).isEmpty,
                     "cold opening displayed an ungrouped history before preparation")
        var readyPublications = 0
        let observation = store.$requestPresentation.sink { snapshot in
            guard snapshot.ready else { return }
            readyPublications += 1
            precondition(snapshot.speeds.samples.isEmpty || snapshot.contexts["1"]?.groupID != nil,
                         "numeric records were published before their group contexts")
        }
        await store.refreshThroughput()
        await store.loadRequestContexts()
        observation.cancel()
        precondition(store.requestHistoryReady && readyPublications == 1,
                     "startup readers did not coalesce into one prepared publication")
        let revision = store.contextRevision, openTime = Date()
        for _ in 0..<5 { await store.loadRequestContexts() }
        precondition(Date().timeIntervalSince(openTime) < 0.05 && store.contextRevision == revision,
                     "reopening re-read all contexts instead of using the prepared history")
        try await checkHistoryPreparation(store: store, base: base)
        try await checkEnergyObserver(base: base)
        try await checkProcessPriorities(store: store, base: base)
        try await checkVersion3(store: store, base: base)
        try await checkSubtaskHierarchy(base: base)
        try await checkQuotaTrends(store: store, base: base)
        try await checkStatisticsRange(base: base)
        try await checkDelayedTimingDuringTraffic(base: base)
        precondition(PanelFormat.tokens(109114) == "109,114", "token counts are not grouped")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12, minute: 30, second: 45))!
        precondition(PanelFormat.requestTime(date.timeIntervalSince1970, now: date, calendar: calendar) == "12:30:45",
                     "today's requests still repeat the full date")
        precondition(PanelFormat.requestTime(date.addingTimeInterval(-86400).timeIntervalSince1970, now: date, calendar: calendar) == (L10n.isChinese ? "10月9日 12:30:45" : "Oct 9 12:30:45"),
                     "cross-day request dates are ambiguous")
        store.selectedModel = "gpt-6.1-sol"
        let fullMessage = await store.requestMessage(for: store.latestSpeed!)
        precondition(fullMessage?.contains("不要只显示第一句话") == true, "full message was truncated to its preview")
        store.selectRequest("1")
        let secondMessage = await store.requestMessage(for: store.detailSpeed!)
        precondition(secondMessage?.contains("检查每项数字") == true && secondMessage != fullMessage,
                     "selected API request resolved the wrong initiating message")
        await store.loadRequestContexts()
        precondition(store.recentSpeeds.count == 100, "history is not 100 per model")
        let grouped = store.requestGroups.filter { $0.context?.groupID != nil }
        precondition(grouped.count == 2 && grouped.contains { $0.samples.map(\.id) == ["1", "2"] },
                     "calls from one user message did not group, or two user messages were merged")
        let loop = grouped.first { $0.samples.count == 2 }!
        precondition(loop.firstAvailable?.id == "2" && loop.firstAvailable?.rate == 65,
                     "the message row does not carry the earliest available API call's measured TPS")
        precondition(loop.continuations.map(\.id) == ["1"], "the parent call was duplicated among children")
        let visibleCalls = store.requestGroups.flatMap { group in
            group.context?.groupID == nil ? group.samples : [group.firstAvailable!] + group.continuations
        }
        precondition(visibleCalls.count == store.recentSpeeds.count && Set(visibleCalls.map(\.id)) == Set(store.recentSpeeds.map(\.id)),
                     "group presentation added or lost measured API calls")
        let oneCall = grouped.first { $0.samples.count == 1 }!
        precondition(oneCall.firstAvailable?.id == "0" && oneCall.continuations.isEmpty,
                     "one measured call displayed as both a parent and a child")
        let collapsed = RequestHistoryRow.make(store.requestGroups, expanded: [])
        let expanded = RequestHistoryRow.make(store.requestGroups, expanded: [loop.id])
        precondition(collapsed.count == 99 && !collapsed.contains { $0.id == "1" } &&
                     collapsed.first { $0.id == "2" }?.callCount == 2,
                     "default collapse hides the parent, unrelated records or an incorrect child")
        precondition(expanded.count == 100 && Set(expanded.map(\.id)) == Set(store.recentSpeeds.map(\.id)) &&
                     expanded.first { $0.id == "1" }?.indented == true,
                     "expanding does not restore each measured API call exactly once")
        precondition(collapsed.first { $0.id == "0" }?.canExpand == false &&
                     collapsed.filter { $0.preview == nil }.allSatisfy { !$0.canExpand },
                     "single-call or unassociated records acquired a misleading disclosure")
        precondition(RequestHistoryRow.visibleSelection("1", groups: store.requestGroups, rows: collapsed) == "2" &&
                     RequestHistoryRow.visibleSelection("1", groups: store.requestGroups, rows: expanded) == "1" &&
                     RequestHistoryRow.visibleSelection("99", groups: store.requestGroups, rows: collapsed) == "99",
                     "collapsing loses selection or changes an unrelated request's details")
        await checkDisclosures(store: store, base: base, groupID: loop.id)
        precondition(store.requestContexts["1"]?.outputPreview == "正在核对项目中的原始数据。", "API output summary missing")
        let toolContext = await store.requestContext(for: store.recentSpeeds.first { $0.id == "2" }!)
        precondition(toolContext?.content?.first?.title == "工具调用：exec", "tool-only call details missing")
        precondition(toolContext?.message?.contains("完整消息末尾") == true, "long parent message was truncated")
        store.selectRequest("99")
        precondition(store.detailSpeed?.outputTokens == 99, "selected history did not update details")
        await store.refreshThroughput()
        precondition(store.detailSpeed?.id == "99", "refresh reset the selected request")
        precondition(store.latestSpeed?.rate == 80 && store.averageSpeed == 62, "selection changed averaging")
        store.selectedModel = "codex-auto-review"
        precondition(store.selectedRequestID == nil && store.detailSpeed?.id == "review", "model changed without resetting details")
        await store.loadRequestContexts()
        let suggestion = await store.requestContext(for: store.detailSpeed!)!
        precondition(suggestion.sourceTitle == "后台 · 消息建议" && suggestion.message == nil,
                     "background suggestion is shown as a human message or unknown output")
        precondition(suggestion.detailSections.map(\.kind) == ["source"] &&
                     !suggestion.detailSections.contains { $0.text.contains("PRIVATE_INSTRUCTIONS") || $0.text.contains("未找到") },
                     "background details expose internal instructions or a misleading missing-output placeholder")
        let suggestionRate = store.detailSpeed!.rate
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: NaturalDetailFixture(store: store, scheme: scheme))
            view.setFrameSize(NSSize(width: 380, height: 760))
            for _ in 0..<30 {
                await Task.yield()
                view.layoutSubtreeIfNeeded()
                view.setFrameSize(NSSize(width: 380, height: view.fittingSize.height))
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("call-source-\(scheme).png"))
        }
        precondition(store.detailSpeed!.rate == suggestionRate && store.averageSpeed == suggestionRate,
                     "source labels excluded background requests or changed their TPS")
        store.selectedModel = "gpt-5.6-terra"
        await store.loadRequestContexts()
        let compact = await store.requestContext(for: store.detailSpeed!)!
        precondition(compact.sourceTitle == "自动压缩上下文" && compact.groupID != nil,
                     "compaction lost its initiating message or source label")
        precondition(compact.detailSections.map(\.kind) == ["user", "source"] &&
                     !compact.detailSections.contains { $0.text.contains("PRIVATE_CONTEXT") || $0.text.contains("未找到") },
                     "compaction details expose hidden context or a misleading missing-output placeholder")
        store.selectedModel = "missing-model"
        precondition(store.detailSpeed == nil, "empty model displays another model's request")
        store.selectedModel = ""
        await store.refreshLocalState()
        let paid = store.slots.first { $0.name == "b" }!
        precondition(paid.planTitle == "Pro 200", "plan refresh fixture did not start from a paid plan")
        let promoted = paid.withQuota(SlotQuota(five: nil, fiveWhen: "", fiveResetAt: nil,
            week: nil, weekWhen: "", weekResetAt: nil, fetchedAt: nil, plan: "promax"))
        let missing = promoted.withQuota(SlotQuota(five: nil, fiveWhen: "", fiveResetAt: nil,
            week: nil, weekWhen: "", weekResetAt: nil, fetchedAt: nil))
        precondition(missing.planTitle == "Pro 500", "missing plan changed a confirmed tier")
        precondition(missing.withQuota(SlotQuota(five: nil, fiveWhen: "", fiveResetAt: nil,
            week: nil, weekWhen: "", weekResetAt: nil, fetchedAt: nil, plan: "prolite")).planTitle == "Pro 100",
            "server-confirmed downgrade retained the previous Pro tier")
        precondition(paid.withQuota(SlotQuota(five: 100, fiveWhen: "", fiveResetAt: nil,
            week: 100, weekWhen: "", weekResetAt: nil, fetchedAt: nil, plan: "future_pro")).planTitle == "future_pro",
            "an unknown plan was guessed from its available quota")
        await store.refreshSlot("b")
        let free = store.slots.first { $0.name == "b" }!
        precondition(free.planTitle == "Free" && free.fiveWindowTitle == (L10n.isChinese ? "30 天" : "30d") && free.hasSingleFreeWindow,
                     "manual quota refresh did not update the plan and actual Free quota period")
        let unknownPlan = free.withQuota(SlotQuota(five: 80, fiveWhen: "", fiveResetAt: nil, week: nil,
                                                 weekWhen: "", weekResetAt: nil, fetchedAt: nil))
        precondition(unknownPlan.planTitle == "Free", "an absent server plan reverted the account to its old token plan")
        await store.refreshLocalState()
        precondition(store.slots.first { $0.name == "b" }?.planTitle == "Free",
                     "reopening the panel did not retain the server-confirmed plan")
        print("Plan names: official prolite/pro/promax map to Pro 100/200/500; upgrades, downgrades, unknown and missing plans passed.")
        print("Plan refresh: manual update and reload keep Free / 30-day period; missing plan keeps last known plan.")
        try await checkMenuBar(store: store, base: base)
        // Use the production main panel and three mock accounts, not estimated row heights.
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: ContentView(store: store).environment(\.colorScheme, scheme))
            view.setFrameSize(NSSize(width: 380, height: 570))
            for _ in 0..<50 {
                await Task.yield()
                view.layoutSubtreeIfNeeded()
                view.setFrameSize(NSSize(width: 380, height: view.fittingSize.height))
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            precondition(store.slots.count == 3, "main panel account fixtures did not load")
            let picker = findPickers(view).first!
            let pickerFrame = picker.convert(picker.bounds, to: view)
            let secondColumnX = PanelLayout.contentInset + PanelLayout.modelControlWidth + PanelLayout.metricSpacing
            print("main picker frame=\(pickerFrame) expected left=\(secondColumnX)")
            precondition(abs(pickerFrame.minX - secondColumnX) < 1, "main model picker is not aligned with the second TPS column")
            let scroll = findScroll(view)!
            precondition(!scroll.hasVerticalScroller, "three fitting accounts still create a scroller")
            precondition(scroll.documentView!.frame.height <= scroll.contentView.bounds.height + 0.5,
                         "account spacing is clipped by a guessed height")
            // macOS's Always preference can force a legacy style; fitting content still has no bar.
            scroll.scrollerStyle = .legacy
            view.layoutSubtreeIfNeeded()
            precondition(!scroll.hasVerticalScroller, "Always-visible scrollers added a bar to fitting accounts")
            print("main theme=\(scheme) height=\(view.frame.height) accounts=3 no scroller; document=\(scroll.documentView!.frame.height) viewport=\(scroll.contentView.bounds.height)")
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("main-\(scheme).png"))
        }
        for scheme in [ColorScheme.light, .dark] {
            var pageHeights: [CGFloat] = []
            for model in ["", "gpt-6.1-sol"] {
                store.selectedModel = model
                let view = NSHostingView(rootView: NaturalDetailFixture(store: store, scheme: scheme))
                view.isFlipped = true
                view.setFrameSize(NSSize(width: 380, height: 760))
                for _ in 0..<30 {
                    await Task.yield()
                    view.layoutSubtreeIfNeeded()
                    view.setFrameSize(NSSize(width: 380, height: view.fittingSize.height))
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let fullWidthScrolls = findScrolls(view).filter { abs($0.frame.width - 380) < 1 }
                precondition(fullWidthScrolls.count == 1, "detail page still has an outer scroll area")
                let history = fullWidthScrolls[0]
                precondition(abs(history.contentView.bounds.height - 216) < 0.5, "natural-height page compressed history")
                let picker = findPickers(view).first!
                precondition(picker.convert(picker.bounds, to: view).minY < 100,
                             "top controls shifted outside the full page")
                pageHeights.append(view.frame.height)
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("natural-detail-\(model.isEmpty ? "all" : "filtered")-\(scheme).png"))
                print("natural detail theme=\(scheme) model=\(model.isEmpty ? "all" : model) height=\(view.frame.height), only history scrolls")
            }
            precondition(pageHeights[0] > 760 && pageHeights[0] - pageHeights[1] > 100,
                         "all-model page is still capped instead of growing")
        }
        store.selectedModel = ""
        // Keep generic bounded-host regression checks for settings/account panels.
        for limit in [CGFloat(350), CGFloat(520)] {
            for scheme in [ColorScheme.light, .dark] {
                let state = ScrollFixtureState()
                let view = NSHostingView(rootView: ScrollFixture(state: state, store: store, maximumHeight: limit, scheme: scheme))
                view.setFrameSize(NSSize(width: 380, height: limit + 43))
                var heights: [CGFloat] = []
                var widths: [CGFloat] = []
                for frame in 0..<50 {
                    state.pulse += 1
                    await Task.yield()
                    view.layoutSubtreeIfNeeded()
                    let fitting = view.fittingSize
                    view.setFrameSize(NSSize(width: 380, height: fitting.height))
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    if frame >= 30 {
                        heights.append(fitting.height)
                        if let scroll = findScroll(view) {
                            widths.append(scroll.documentView?.frame.width ?? 0)
                            precondition(scroll.scrollerStyle == .overlay, "scroller changes document width")
                            precondition(scroll.contentView.frame.width == 380, "viewport width changed")
                        }
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                precondition(!heights.isEmpty && (heights.max()! - heights.min()!) < 0.5, "viewport height oscillates")
                precondition(heights.last! > 200 && heights.last! <= limit + 43, "viewport is empty or exceeds screen limit")
                precondition(widths.count == heights.count && widths.allSatisfy { $0 == 380 }, "document width is unstable")
                print("limit=\(limit) theme=\(scheme) height=\(heights.last!) stable=\(heights.count) updates")
                let scroll = findScroll(view)!
                let document = scroll.documentView!
                let pickerY = findPickers(document).first.map { $0.convert($0.bounds, to: document).minY } ?? -1
                let detailPicker = findPickers(document).first!
                let detailPickerFrame = detailPicker.convert(detailPicker.bounds, to: document)
                let secondColumnX = PanelLayout.contentInset + PanelLayout.modelControlWidth + PanelLayout.metricSpacing
                precondition(abs(detailPickerFrame.minX - secondColumnX) < 1, "detail model picker is not aligned with the metrics column")
                precondition(document.frame.height < 1100, "history document leaked into the page height")
                precondition(pickerY >= 0 && pickerY < 40, "detail controls are outside the initial visible viewport")
                precondition(scroll.contentView.bounds.origin.y < 1, "detail page starts scrolled away from the header")
                print("detail document height=\(document.frame.height) picker y=\(pickerY), first controls visible")
                let nestedImage = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: nestedImage)
                try nestedImage.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("nested-\(scheme).png"))
                let badgePreview = NSHostingView(rootView: ThroughputDetailPanel(store: store)
                    .background(PanelPalette(scheme: scheme).paper).environment(\.colorScheme, scheme))
                badgePreview.setFrameSize(NSSize(width: 380, height: 800))
                badgePreview.layoutSubtreeIfNeeded()
                badgePreview.setFrameSize(NSSize(width: 380, height: badgePreview.fittingSize.height))
                badgePreview.layoutSubtreeIfNeeded()
                for _ in 0..<30 {
                    await Task.yield()
                    badgePreview.layoutSubtreeIfNeeded()
                    badgePreview.setFrameSize(NSSize(width: 380, height: badgePreview.fittingSize.height))
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let previewHistory = findRequestScroll(badgePreview)!
                precondition(previewHistory.contentView.bounds.origin.y < 1, "new history view starts away from the latest request")
                precondition(abs(previewHistory.contentView.bounds.height - 216) < 0.5,
                             "all-model history was compressed instead of showing 4.5 rows")
                let badgeImage = badgePreview.bitmapImageRepForCachingDisplay(in: badgePreview.bounds)!
                badgePreview.cacheDisplay(in: badgePreview.bounds, to: badgeImage)
                try badgeImage.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("detail-\(scheme).png"))
                precondition(scroll.hasVerticalScroller == (document.frame.height > scroll.contentView.bounds.height + 0.5),
                             "scroller is not conditional on actual overflow")
                let history = findRequestScroll(document)!
                precondition(abs(history.contentView.bounds.height - 216) < 0.5,
                             "page height limit compressed the request history")
                precondition(history.hasVerticalScroller, "100-request list is not scrollable")
                let historyBottom = max(0, history.documentView!.frame.height - history.contentView.bounds.height)
                let table = history.documentView as! NSTableView
                var hostedRows = 0
                table.enumerateAvailableRowViews { _, _ in hostedRows += 1 }
                precondition(hostedRows <= 12 && table.numberOfRows == RequestHistoryRow.make(store.requestGroups, expanded: []).count,
                             "history eagerly hosts offscreen records or drops retained calls")
                history.contentView.scroll(to: NSPoint(x: 0, y: historyBottom))
                history.reflectScrolledClipView(history.contentView)
                for _ in 0..<3 { await Task.yield(); history.layoutSubtreeIfNeeded() }
                precondition(abs(history.documentVisibleRect.maxY - history.documentView!.frame.height) < 1,
                             "history cannot reach the oldest retained request")
                if scheme == .light && limit == 350 {
                    let last = table.numberOfRows - 1
                    precondition(table.view(atColumn: 0, row: last, makeIfNecessary: true) != nil,
                                 "the oldest history row was not materialized after scrolling")
                    table.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
                    await Task.yield()
                    precondition(store.detailSpeed?.id == "99", "recycled row selection displays another API call")
                    let origin = history.contentView.bounds.origin.y
                    store.showMenuBarTPS.toggle()
                    await Task.yield()
                    badgePreview.layoutSubtreeIfNeeded()
                    precondition(abs(history.contentView.bounds.origin.y - origin) < 1,
                                 "an unrelated update jumped the history scroll position")
                }
                store.selectRequest("99")
                precondition(store.detailSpeed?.id == "99", "oldest visible request cannot be selected")
                history.contentView.scroll(to: .zero)
                history.reflectScrolledClipView(history.contentView)
                let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                precondition(abs(scroll.documentVisibleRect.maxY - document.frame.height) < 1,
                             "metrics content cannot scroll to the bottom")
                let pickers = findPickers(view)
                precondition(pickers.count == 2, "model and time selectors are missing or obsolete controls remain")
                let modelPicker = pickers.first { $0.itemTitles.contains(L10n.string("全部模型")) }!
                let modelIndex = modelPicker.itemTitles.firstIndex(of: "gpt-6.1-sol")!
                modelPicker.selectItem(at: modelIndex)
                _ = NSApp.sendAction(modelPicker.action!, to: modelPicker.target, from: modelPicker)
                precondition(store.selectedModel == "gpt-6.1-sol", "model selection did not reach its binding")
                precondition(store.latestSpeed?.rate == 80 && store.averageSpeed == 62,
                             "latest and average did not use the same selected model")
                for _ in 0..<20 {
                    await Task.yield()
                    badgePreview.layoutSubtreeIfNeeded()
                    badgePreview.setFrameSize(NSSize(width: 380, height: badgePreview.fittingSize.height))
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let filteredHistory = findRequestScroll(badgePreview)!
                precondition(abs(filteredHistory.contentView.bounds.height - 216) < 0.5,
                             "model filtering changed the fixed history height")
                precondition(abs(filteredHistory.documentView!.frame.height - (99 * 48)) < 1,
                             "request records have inconsistent heights")
                modelPicker.isEnabled = false
                modelPicker.selectItem(at: 0)
                _ = NSApp.sendAction(modelPicker.action!, to: modelPicker.target, from: modelPicker)
                precondition(store.selectedModel == "gpt-6.1-sol", "disabled selector changed the model")
                modelPicker.isEnabled = true
                _ = NSApp.sendAction(modelPicker.action!, to: modelPicker.target, from: modelPicker)
                precondition(store.selectedModel.isEmpty, "model selection could not be restored")
            }
        }
        print("Scroll layout: light/dark metrics passed at two height limits; 80 settled redraws with stable 380 pt document/viewport widths and reachable bottom.")
        print("Native selectors: simultaneous latest/average metrics, model binding and disabled-state checks passed.")
        print("Request history: fixed 216 pt viewport / 48 pt API rows; groups default collapsed, disclosed calls appear exactly once.")
        exit(0)
    }

    static func checkDelayedTimingDuringTraffic(base: URL) async throws {
        let root=base.appendingPathComponent("fixtures/late-timing")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let database=root.appendingPathComponent("logs_2.sqlite"),file=root.appendingPathComponent("samples.json")
        try? FileManager.default.removeItem(at:database)
        var db:OpaquePointer?
        precondition(sqlite3_open(database.path,&db)==SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db,"CREATE TABLE logs(ts INTEGER,ts_nanos INTEGER,thread_id TEXT,target TEXT,feedback_log_body TEXT)",nil,nil,nil)==SQLITE_OK)
        let now=Date().timeIntervalSince1970
        let a=RequestSpeedSample(id:"late",model:"late-model",completedAt:now-1,outputTokens:200,durationSeconds:2,
            inputTokens:1000,reasoningTokens:100,cachedTokens:0,ttftSeconds:1,conversationID:"late-conversation",startedAt:now-4)
        try JSONEncoder().encode(RequestSpeedSnapshot(samples:[a])).write(to:file)
        let suite="LateTiming-\(UUID())"
        let prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let store=SwapStore(defaults:prefs,scanner:SessionScanner(codexHome:root),speedFile:file)
        await store.refreshThroughput()
        precondition(store.latestSpeed?.rate == nil,"late timing fixture already had an output boundary")
        for (stamp,kind) in [(now-3,"reasoning"),(now-2,"message")] {
            let sec=Int(stamp),ns=Int((stamp-Double(Int(stamp)))*1e9)
            let sql="INSERT INTO logs VALUES (\(sec),\(ns),'late-conversation','codex_core::stream_events_utils','turn{model=late-model}: Output item item_type=\"\(kind)\"')"
            precondition(sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK)
        }
        try await Task.sleep(nanoseconds:2_100_000_000)
        let b=RequestSpeedSample(id:"other",model:"other-model",completedAt:Date().timeIntervalSince1970-0.01,
            outputTokens:50,durationSeconds:1,inputTokens:100,reasoningTokens:0,cachedTokens:0,ttftSeconds:1,
            conversationID:"other-conversation")
        try JSONEncoder().encode(RequestSpeedSnapshot(samples:[b,a])).write(to:file)
        await store.refreshThroughput()
        precondition(store.requestSpeeds.latest(model:"late-model")?.rate.map { abs($0-100)<0.001 } == true,
                     "unrelated new traffic starved the older call's newly available timing")
        precondition(store.latestSpeed?.id=="other" && store.requestSpeeds.samples.count==2,
                     "late timing repair replaced request identities or newest-completion order")
        print("Delayed timing: an unrelated conversation changes the file while output logs arrive; older timing is recovered in the same read with original IDs/counters intact.")
    }

    static func checkStatisticsRange(base: URL) async throws {
        let suite = "SpeedRangeChecks-\(UUID())", now = Date().timeIntervalSince1970
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        func sample(_ model: String, age: Double) -> RequestSpeedSample {
            RequestSpeedSample(id: model, model: model, completedAt: now-age,
                outputTokens: 200, durationSeconds: 2, inputTokens: 1000,
                reasoningTokens: 0, cachedTokens: 0, ttftSeconds: 1)
        }
        var samples = (0..<12).map { sample(String(format: "model-%02d",$0),age: Double($0+1)*20) }
        samples += [sample("two-hours",age:7200), sample("three-days",age:3*86400),sample("obsolete",age:8*86400)]
        samples.append(RequestSpeedSample(id:"pending",model:"model-00",completedAt:now-1,outputTokens:200,
            durationSeconds:2,inputTokens:1000,reasoningTokens:100,cachedTokens:0,ttftSeconds:1))
        let file=base.appendingPathComponent("fixtures/range-speeds.json")
        try JSONEncoder().encode(RequestSpeedSnapshot(samples:samples)).write(to:file)
        let store=SwapStore(defaults:prefs,scanner:SessionScanner(codexHome:base.appendingPathComponent("fixtures")),speedFile:file)
        await store.refreshThroughput()
        precondition(store.statisticsRange == .day && store.modelNames.count == 13 && !store.modelNames.contains("obsolete"),
                     "default time range retained obsolete models")
        precondition(store.latestSpeed?.rate == nil && store.menuBarSpeed?.id == "model-00" && store.menuBarText == "100.0 t/s" &&
                     store.menuBarHelp.contains(L10n.isChinese ? "最近一次可靠测速" : "Last reliable speed") &&
                     store.menuBarHelp.contains(L10n.isChinese ? "采样时间" : "Sample time"),
                     "missing latest timing erased the measured menu speed or its source/time")
        for scheme in [ColorScheme.light,.dark] {
            let view=NSHostingView(rootView:NaturalDetailFixture(store:store,scheme:scheme))
            view.setFrameSize(NSSize(width:380,height:1200))
            for _ in 0..<15 { await Task.yield();view.layoutSubtreeIfNeeded() }
            view.setFrameSize(NSSize(width:380,height:view.fittingSize.height));view.layoutSubtreeIfNeeded()
            let scrolls=findScrolls(view)
            let models=scrolls.first { abs($0.contentView.bounds.height-PanelLayout.modelHistoryHeight)<1 }!
            precondition(abs(models.contentView.bounds.width-344)<2 && models.documentView!.frame.height>models.contentView.bounds.height,
                         "many model rows expanded the panel instead of using a bounded viewport")
            let history=findRequestScroll(view)!
            precondition(abs(history.contentView.bounds.height-PanelLayout.requestHistoryHeight)<1,
                         "model list compressed the independent request history")
            let bottom=max(0,models.documentView!.frame.height-models.contentView.bounds.height)
            models.contentView.scroll(to:NSPoint(x:0,y:bottom));models.reflectScrolledClipView(models.contentView)
            precondition(abs(models.documentVisibleRect.maxY-models.documentView!.frame.height)<1,
                         "bottom model entries are unreachable")
            models.contentView.scroll(to:.zero);models.reflectScrolledClipView(models.contentView)
            let image=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:image)
            try image.representation(using:.png,properties:[:])!.write(to:base.appendingPathComponent("speed-model-range-\(scheme).png"))
            let picker=findPickers(view).first { $0.itemTitles.contains(L10n.string("全部时间")) }!
            let hour=picker.itemTitles.firstIndex(of:RequestStatisticsRange.hour.title)!
            picker.selectItem(at:hour);_ = NSApp.sendAction(picker.action!,to:picker.target,from:picker)
            precondition(store.statisticsRange == .hour && store.modelNames.count==12,
                         "native time selector did not filter the model list")
            store.statisticsRange = .day
        }
        store.statisticsRange = .all;store.selectedModel = "obsolete";store.statisticsRange = .day
        precondition(store.selectedModel.isEmpty && store.modelNames.count==13,"expired selected model survived time filtering")
        store.statisticsRange = .week
        let reopened=SwapStore(defaults:UserDefaults(suiteName:suite)!,scanner:SessionScanner(codexHome:base.appendingPathComponent("fixtures")),speedFile:file)
        await reopened.refreshThroughput()
        precondition(reopened.statisticsRange == .week && reopened.modelNames.count==14,"time range was not restored")
        reopened.rebuildStatistics(now:now+9*86400)
        precondition(reopened.modelNames.isEmpty && reopened.menuBarSpeed == nil,"expired data survived a foreground refresh")
        precondition(store.requestSpeeds.samples.count == samples.count,"time filtering deleted original history")
        print("Speed ranges: persistent native picker, old-model expiry, latest reliable menu source/time, bounded model viewport, reachable bottom and independent 216pt request history passed.")
    }

    static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
        return nil
    }
    static func findRequestScroll(_ view: NSView) -> NSScrollView? {
        findScrolls(view).first { ($0.documentView as? NSTableView)?.tableColumns.first?.identifier.rawValue == "request" }
    }

    static func findScrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { findScrolls($0) }
    }

    static func findPickers(_ view: NSView) -> [PanelPopUpButton] {
        if let picker = view as? PanelPopUpButton { return [picker] }
        return view.subviews.flatMap { findPickers($0) }
    }

    static func findDisclosures(_ view: NSView) -> [NSButton] {
        if let button = view as? NSButton, button.identifier?.rawValue.hasPrefix("request-group-") == true { return [button] }
        return view.subviews.flatMap { findDisclosures($0) }
    }

    static func checkHistoryPreparation(store: SwapStore, base: URL) async throws {
        let previous = store.requestPresentation
        precondition(RequestMessageReader.summarySamples(previous.speeds.history(model: ""), previous: previous).isEmpty,
                     "unchanged resolved conversations are scanned again")
        let sample = previous.speeds.latest(model: "gpt-6.1-sol")!
        let next = RequestSpeedSample(id: "next-request", model: sample.model, completedAt: sample.completedAt + 20,
            outputTokens: 100, durationSeconds: 10, inputTokens: 1000, reasoningTokens: 0, cachedTokens: 500,
            ttftSeconds: 1, nonReasoningDurationSeconds: 10, conversationID: sample.conversationID,
            startedAt: sample.completedAt + 9)
        let updated = RequestSpeedSnapshot(samples: previous.speeds.samples + [next])
        let pending = RequestMessageReader.summarySamples(updated.history(model: ""), previous: previous)
        precondition(pending.contains { $0.id == next.id } && pending.contains { $0.id == "1" } &&
                     pending.allSatisfy { $0.conversationID == sample.conversationID },
                     "incremental refresh omitted neighboring calls or reread unrelated conversations")
        var missing = previous
        missing.contexts.removeValue(forKey: "1")
        precondition(RequestMessageReader.summarySamples(previous.speeds.history(model: ""), previous: missing).isEmpty,
                     "unchanged unresolved history is retried on every refresh")
        precondition(RequestMessageReader.summarySamples(previous.speeds.history(model: ""), previous: missing, retryUnresolved: true)
                        .contains { $0.id == "1" }, "unresolved output is never retried")
        let file = base.appendingPathComponent("fixtures/speeds.json")
        let tool = Bundle.main.url(forResource: "request-context", withExtension: "py")!
        let originalFile = try Data(contentsOf: file), originalTool = try Data(contentsOf: tool)
        defer { try? originalFile.write(to: file); try? originalTool.write(to: tool) }
        let idleRevision = store.contextRevision
        try Data("raise SystemExit(1)\n".utf8).write(to: tool)
        for _ in 0..<10 { await store.refreshThroughput() }
        precondition(store.captureError == nil && store.contextRevision == idleRevision,
                     "unchanged background refresh still launches the history/timing reader")
        try JSONEncoder().encode(updated).write(to: file)
        try Data("raise SystemExit(1)\n".utf8).write(to: tool)
        let revision = store.contextRevision
        await store.refreshThroughput()
        precondition(store.requestSpeeds == previous.speeds && store.requestContexts["1"]?.groupID == previous.contexts["1"]?.groupID &&
                     store.requestHistoryReady && store.captureError != nil && store.contextRevision == revision,
                     "reader failure cleared prepared groups or replaced them with unmatched records")
        try originalFile.write(to: file)
        try originalTool.write(to: tool)
        await store.refreshThroughput()
        precondition(store.captureError == nil && store.requestHistoryReady,
                     "context reader did not recover after a failed refresh")
        print("History preparation: atomic startup, warm reopening, per-conversation cache, neighboring boundaries, pending retries and failure recovery passed.")
    }

    static func checkEnergyObserver(base: URL) async throws {
        let directory = base.appendingPathComponent("energy-observer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("samples.json")
        try Data("one".utf8).write(to: file, options: .atomic)
        let before = try TelemetryFileStamp(file)
        let count = FileEventCount()
        let observer = try TelemetryFileObserver(file: file) { count.increment() }
        try Data("two".utf8).write(to: file, options: .atomic)
        let deadline = Date().addingTimeInterval(3)
        while count.value == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let after = try TelemetryFileStamp(file)
        precondition(count.value == 1 && after != before,
                     "atomic replacement did not wake the directory observer")
        for _ in 0..<20 { try Data("two".utf8).write(to: file, options: .atomic) }
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(count.value == 1, "busy traffic bypassed the active refresh budget")
        withExtendedLifetime(observer) {}
        print("Energy: unchanged refresh launches no readers; atomic file events are observed and busy writes are coalesced.")
    }

    static func checkProcessPriorities(store: SwapStore, base: URL) async throws {
        let resources = Bundle.main.resourceURL!
        let contextTool = resources.appendingPathComponent("request-context.py")
        let accountTool = resources.appendingPathComponent("codex-swap.py")
        let captureTool = resources.appendingPathComponent("tps-capture.py")
        let report = resources.appendingPathComponent("priority-report.json")
        let originals = try [contextTool, accountTool, captureTool].map { url in
            FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        }
        defer {
            for (url, original) in zip([contextTool, accountTool, captureTool], originals) {
                if let original { try? original.write(to: url) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            try? FileManager.default.removeItem(at: report)
        }
        let probe = "import ctypes,json,sys\nqos=ctypes.CDLL('/usr/lib/libSystem.B.dylib').qos_class_self()\n"
        try Data((probe + "import os\nfor line in sys.stdin:\n request=json.loads(line)\n print(json.dumps(dict(result={s['id']:dict(outputPreview=str(qos),groupPreview=str(os.getpid())) for s in request['samples']})),flush=True)\n").utf8).write(to: contextTool)
        try Data((probe + "print(json.dumps(dict(ok=True,live=dict(plan=str(qos)),slots=[])))\n").utf8).write(to: accountTool)
        try Data((probe + "from pathlib import Path\nimport time\nPath(__file__).with_name('priority-report.json').write_text(json.dumps(qos))\nif 'serve' in sys.argv: time.sleep(30)\nelse: print(json.dumps(dict(ok=True,enabled=True)))\n").utf8).write(to: captureTool)
        let sample = store.latestSpeed!
        for (priority, expected): (TaskPriority, UInt32) in [(.background, 9), (.utility, 17), (.userInitiated, 25)] {
            let finished = FileEventCount()
            // Poll completion instead of awaiting value: a high-priority waiter
            // would intentionally promote the task under test.
            let worker = Task.detached(priority: priority) {
                defer { finished.increment() }
                let context = try RequestMessageReader.contexts([sample], home: base)
                let again = try RequestMessageReader.contexts([sample], home: base)
                precondition(again == context, "unchanged history launched a fresh worker")
                let workerPID = Int32(context[sample.id]!.groupPreview!)!
                kill(workerPID, SIGKILL)
                try await Task.sleep(nanoseconds: 30_000_000)
                let restarted = try RequestMessageReader.contexts([sample], home: base)
                precondition(restarted[sample.id]!.groupPreview != context[sample.id]!.groupPreview,
                             "history worker did not recover after unexpected exit")
                let state = try CodexSwap.list()
                let readerQoS = UInt32(context[sample.id]!.outputPreview!)!
                let accountQoS = UInt32(state.livePlan)!
                precondition(expected == 25 ? readerQoS >= expected && accountQoS >= expected :
                             readerQoS == expected && accountQoS == expected,
                             "child process ignored the caller's background/utility/interactive priority")
            }
            let deadline = Date().addingTimeInterval(10)
            while finished.value == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(finished.value == 1, "priority probe did not complete")
            try await worker.value
        }
        let capture = TelemetryCapture()
        try capture.start()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: report.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let collectorQoS = try JSONDecoder().decode(UInt32.self, from: Data(contentsOf: report))
        precondition(collectorQoS == 9, "resident collector was not launched with background QoS")
        _ = try TelemetryCapture.configure("status")
        let settingQoS = try JSONDecoder().decode(UInt32.self, from: Data(contentsOf: report))
        precondition(settingQoS >= 25, "explicit user settings inherited background QoS")
        withExtendedLifetime(capture) {}
        print("QoS: real Python children honor background/utility/user priorities; collector is background and settings remain responsive.")
    }

    static func checkLocalization() {
        let chinese = L10n.isChinese
        let expected = UserDefaults.standard.stringArray(forKey: "AppleLanguages")!.first!
        precondition(Bundle.main.preferredLocalizations.first == expected, "test language was not selected by the app bundle")
        precondition(L10n.string("保存登录") == (chinese ? "保存登录" : "Save login"), "static interface translation missing")
        let plan = "Pro 100", count = 3, one = 1, quota = 82, window = chinese ? "7 天" : "7d"
        precondition(L10n.string("切换到 \(plan)？") == (chinese ? "切换到 Pro 100？" : "Switch to Pro 100?"),
                     "account confirmation lost its interpolated plan")
        precondition(L10n.string("\(count) 条") == (chinese ? "3 条" : "3 requests"), "numeric interpolation is not localized")
        precondition(L10n.string("\(one) 条") == (chinese ? "1 条" : "1 request"), "English singular request count is incorrect")
        precondition(L10n.string("\(window)剩余 \(quota)%") == (chinese ? "7 天剩余 82%" : "7d remaining: 82%"),
                     "quota interpolation or literal percent is incorrect")
        precondition(String(format: L10n.string("%.2f 秒"), 1.25) == (chinese ? "1.25 秒" : "1.25 s"),
                     "duration format changed its numeric value")
        let accountError = SwapError.failed("另一个账号操作尚未完成，请稍后重试。").localizedDescription
        precondition(accountError == (chinese ? "另一个账号操作尚未完成，请稍后重试。" : "Another account operation is still running. Please try again shortly."),
                     "fixed backend errors are not localized")
        let userText = "设置", output = "后台 · 消息建议"
        precondition(RequestCallContent(kind: "user", title: "发起消息", text: userText).displayText == userText,
                     "a user message matching a catalog key was translated")
        let response = RequestCallContent(kind: "output", title: "输出内容", text: output)
        precondition(response.displayText == output && response.displayTitle == (chinese ? "输出内容" : "Output"),
                     "model output was translated or its label was not localized")
        let tool = RequestCallContent(kind: "tool", title: "工具调用：exec", text: "中文工具参数")
        precondition(tool.displayTitle == (chinese ? "工具调用：exec" : "Tool call: exec") && tool.displayText == "中文工具参数",
                     "tool names or arguments were changed by localization")
        let namedTool = RequestCallContent(kind: "tool", title: "工具调用：设置", text: "")
        precondition(namedTool.displayTitle == (chinese ? "工具调用：设置" : "Tool call: 设置"),
                     "an actual tool name matching a localization key was translated")
        let preview = RequestCallContext(outputPreview: "调用 exec、send_message", outputKind: "tool")
        precondition(preview.displayOutputPreview == (chinese ? "调用 exec、send_message" : "Call exec, send_message"),
                     "tool preview was not localized")
        let source = RequestCallContext(outputPreview: output, outputKind: "suggestion")
        precondition(source.displayOutputPreview == (chinese ? output : "Background · Message suggestion"),
                     "background source label was not localized")
        precondition(RequestCallContext(outputPreview: output, outputKind: "output").displayOutputPreview == output,
                     "ordinary model output was mistaken for an internal source label")
        print("Localization: \(expected); labels, dynamic counts, percent, duration, backend errors and untouched user/model/tool text passed.")
    }

    static func checkMenuBar(store: SwapStore, base: URL) async throws {
        let cache = base.appendingPathComponent("Checker.app/Contents/Resources/layout-slot-state.json")
        let original = try Data(contentsOf: cache)
        defer { try? original.write(to: cache) }
        let speed = store.menuBarText
        func reload(_ overrides: [String: Any], expected: String) async throws {
            try JSONSerialization.data(withJSONObject: overrides).write(to: cache)
            await store.refreshLocalState()
            precondition(store.menuBarQuota.text == expected, "menu bar selected the wrong account/quota")
            precondition(store.menuBarText == speed, "quota refresh changed the selected model's TPS")
        }
        try await reload(["b": ["five": 1, "week": 2]], expected: "74%")
        try await reload(["a": ["five": 40, "week": 82]], expected: "40%")
        try await reload(["a": ["five": 82, "week": 40]], expected: "40%")
        try await reload(["a": ["five": 0, "week": 82]], expected: "0%")
        try await reload(["a": ["plan": "free", "five": 100, "week": NSNull(),
                                "five_window_seconds": 2592000]], expected: "100%")
        precondition(store.menuBarHelp.contains(L10n.isChinese ? "30 天剩余 100%" : "30d remaining: 100%"), "Free quota tooltip used a five-hour period")
        try await reload(["a": ["five": NSNull(), "week": NSNull()]], expected: "—")
        try await reload(["a": ["active": false], "b": ["active": true]], expected: "63%")
        precondition(store.menuBarHelp.contains("second@example.com"), "account switch retained the previous tooltip")
        try await reload(["a": ["active": false]], expected: "—")
        try original.write(to: cache)
        await store.refreshLocalState()
        for (index, values) in [("51.3 t/s", "82%"), ("— t/s", "—"), ("1024.8 t/s", "0%")].enumerated() {
            let image = MenuBarMetrics.image(speed: values.0, quota: values.1)
            precondition(image.isTemplate && image.size.height == 22, "menu bar image does not fit the native bar")
            precondition(MenuBarMetrics.image(speed: values.0, quota: values.1) === image,
                         "unrelated updates rebuilt an unchanged menu bar image")
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: base.appendingPathComponent("menu-bar-\(index).png"))
        }
        print("Menu bar: active-account switch, lower available quota, zero/unknown, Free 30-day period and unchanged TPS passed; 22pt template image cached.")
    }

    static func checkSubtaskHierarchy(base: URL) async throws {
        let root = base.appendingPathComponent("hierarchy-fixture")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let parent = "019f1000-1111-7000-8000-000000000001"
        let children = (2...4).map { "019f1000-1111-7000-8000-00000000000\($0)" }
        let now = Date().timeIntervalSince1970
        func record(_ age: Double, _ kind: String, _ payload: [String: Any]) -> [String: Any] {
            ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now-age)), "type": kind, "payload": payload]
        }
        func user(_ text: String) -> [String: Any] { ["role": "user", "content": [["type": "input_text", "text": text]]] }
        var records = [parent: [record(120, "session_meta", ["id": parent]),
            record(100, "event_msg", ["type": "task_started", "turn_id": "human-turn"]),
            record(99, "response_item", user("收集行情，再给我分析结论。"))]]
        for (index, cid) in children.enumerated() {
            records[cid] = [record(110, "session_meta", ["id": cid]),
                record(76-Double(index)*10, "event_msg", ["type": "task_started", "turn_id": "task-\(index)",
                    "turn_attribution": ["turn_id": "task-\(index)", "parent_turn_id": "human-turn", "root_turn_id": "human-turn"]])]
            if index < 2 {
                records[parent]!.append(record(98-Double(index), "event_msg", ["type": "item_completed", "thread_id": parent,
                    "turn_id": "human-turn", "item": ["type": "SubAgentActivity", "kind": "started", "agent_thread_id": cid]]))
            }
        }
        func sample(_ id: String, _ cid: String, _ age: Double, _ count: Int, model: String) -> RequestSpeedSample {
            RequestSpeedSample(id: id, model: model, completedAt: now-age, outputTokens: count, durationSeconds: 2,
                inputTokens: count*10, reasoningTokens: 0, cachedTokens: 0, ttftSeconds: 1, conversationID: cid, startedAt: now-age-3)
        }
        let calls = [sample("parent-first", parent, 80, 100, model: "astra"), sample("parent-last", parent, 5, 110, model: "astra"),
            sample("quote-tool", children[0], 70, 120, model: "terra"), sample("quote-result", children[0], 60, 130, model: "terra"),
            sample("official-result", children[1], 50, 140, model: "terra"), sample("pending-result", children[2], 40, 150, model: "terra")]
        for call in calls {
            let age = now-call.completedAt
            records[call.conversationID!]!.append(record(age, "event_msg", ["type": "token_count", "info": ["last_token_usage": [
                "input_tokens": call.inputTokens, "output_tokens": call.outputTokens, "reasoning_output_tokens": 0, "cached_input_tokens": 0]]]))
            records[call.conversationID!]!.append(record(age, "response_item", ["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "Output for \(call.id)"]]]))
        }
        for (cid, rows) in records {
            let ordered = rows.sorted { ($0["timestamp"] as! String) < ($1["timestamp"] as! String) }
            let data = try ordered.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try Data(data.utf8).write(to: root.appendingPathComponent("sessions/rollout-\(cid).jsonl"))
        }
        var db: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,rollout_path TEXT,source TEXT,thread_source TEXT,agent_path TEXT,title TEXT,cwd TEXT)", nil, nil, nil) == SQLITE_OK)
        for (index, cid) in ([parent]+children).enumerated() {
            let source = index == 0 ? "\"cli\"" : "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(parent)\"}}}"
            let path = root.appendingPathComponent("sessions/rollout-\(cid).jsonl").path
            let sql = "INSERT INTO threads VALUES ('\(cid)','\(path)','\(source)','\(index == 0 ? "cli" : "subagent")','/root/\(index == 1 ? "quote_collection" : "official_collection")','\(index == 0 ? "Market analysis" : "")','/projects/Research')"
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)
        let speedFile = root.appendingPathComponent("samples.json")
        try JSONEncoder().encode(RequestSpeedSnapshot(samples: calls)).write(to: speedFile)
        let suite = "Hierarchy-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = SwapStore(defaults: prefs, scanner: SessionScanner(codexHome: root), speedFile: speedFile)
        await store.refreshThroughput()
        let groups = store.requestGroups, human = groups.first { $0.context?.groupID != nil }!
        let allKeys = Set(groups.map(\.id) + store.requestContexts.values.compactMap { $0.subtaskID.map { "subtask-\($0)" } })
        let all = RequestHistoryRow.make(groups, expanded: allKeys)
        precondition(all.filter(\.isAPI).count == calls.count && Set(all.filter(\.isAPI).map(\.id)) == Set(calls.map(\.id)),
                     "hierarchy duplicated or lost an API call")
        precondition(Set(all.map(\.id)).count == all.count && all.filter { $0.kind == .subtaskHeader }.count == 3,
                     "hierarchy has duplicate identities or missing task headings")
        precondition(all.first { $0.id == "quote-tool" }?.indent == 2 && all.first { $0.id == "parent-first" }?.sample.rate == 50,
                     "child depth or parent API speed changed")
        let childOnly = RequestHistoryGroup.make(calls.filter { $0.model == "terra" }, contexts: store.requestContexts)
        let childRows = RequestHistoryRow.make(childOnly, expanded: allKeys)
        precondition(childRows.contains { $0.kind == .userHeader } && childRows.filter(\.isAPI).count == 4,
                     "model filtering assigned a child's TPS to a structural user heading")
        let quote = store.requestContexts["quote-tool"]!
        precondition(RequestBrowseFilter(conversationID: parent, query: "quote_collection").matches(calls[2], context: quote) &&
                     RequestBrowseFilter(source: "subagent").matches(calls[2], context: quote), "root conversation or subtask search omitted children")
        let full = await store.requestContext(for: calls[2])!
        precondition(full.message == "收集行情，再给我分析结论。" && full.detailSections.contains { $0.kind == "subtask" },
                     "child details lost the actual user message or task provenance")
        let prior = store.requestPresentation
        var next = calls
        let extra = RequestSpeedSample(id: "new-parent", model: calls[0].model,
            completedAt: now, outputTokens: 10, durationSeconds: 1, inputTokens: 100, reasoningTokens: 0, cachedTokens: 0, ttftSeconds: 1, conversationID: parent)
        next.append(extra)
        precondition(RequestMessageReader.summarySamples(next, previous: prior).contains { $0.id == "quote-tool" },
                     "parent changes did not invalidate dependent child contexts")
        let compact = RequestCallContext(sourceKind: "subagent", subtaskTitle: "collect",
            callSource: RequestCallContent(kind: "source", title: "自动压缩上下文", text: "压缩说明"))
        precondition(compact.detailSections.contains { $0.kind == "source" } &&
                     !compact.detailSections.contains { $0.kind == "output" }, "subtask annotation hid a known compaction source")
        for scheme in [ColorScheme.light, .dark] {
            store.selectedModel = ""
            store.selectRequest("parent-first")
            let view = NSHostingView(rootView: NaturalDetailFixture(store: store, scheme: scheme))
            view.setFrameSize(NSSize(width: 380, height: 900))
            func settle() async {
                for _ in 0..<10 { await Task.yield(); view.layoutSubtreeIfNeeded(); view.setFrameSize(NSSize(width: 380, height: view.fittingSize.height)); try? await Task.sleep(nanoseconds: 5_000_000) }
            }
            func click(_ key: String) {
                let button = findDisclosures(view).first { $0.identifier?.rawValue == "request-group-\(key)" }!
                _ = NSApp.sendAction(button.action!, to: button.target, from: button)
            }
            await settle()
            let table = findRequestScroll(view)!.documentView as! NSTableView
            precondition(table.numberOfRows == 2, "task hierarchy did not default to collapsed")
            click(human.id); await settle()
            let taskKey = "subtask-\(quote.subtaskID!)"
            click(taskKey); await settle()
            let rows = RequestHistoryRow.make(groups, expanded: [human.id, taskKey])
            let quoteIndex = rows.firstIndex { $0.id == "quote-tool" }!
            table.selectRowIndexes(IndexSet(integer: quoteIndex), byExtendingSelection: false); await settle()
            precondition(store.detailSpeed?.id == "quote-tool", "nested API selection chose a heading or another call")
            let headingIndex = rows.firstIndex { $0.groupID == taskKey }!
            table.selectRowIndexes(IndexSet(integer: headingIndex), byExtendingSelection: false); await settle()
            precondition(store.detailSpeed?.id == "quote-tool", "structural heading changed the measured API selection")
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("hierarchy-\(scheme).png"))
            store.selectedModel = "terra"; await settle()
            precondition(RequestHistoryRow.make(store.requestGroups, expanded: [human.id, taskKey]).contains { $0.kind == .userHeader },
                         "child-only filter lost its structural user header")
            store.selectedModel = ""; await settle(); click(human.id); await settle()
            precondition(store.detailSpeed?.id == "parent-first", "collapse failed to restore the visible real parent API")
        }
        precondition(store.requestSpeeds.samples == calls && store.averageSpeed == RequestSpeedSnapshot(samples: calls).average(model: ""),
                     "hierarchy changed samples, counters, timing or average TPS")
        print("Subtasks: exact parent evidence, nested rows, default collapse, unique API identities, structural headings without TPS, filtered roots, native selection, dependent refresh and unchanged numeric samples passed.")
    }

    static func checkDisclosures(store: SwapStore, base: URL, groupID: String) async {
        store.selectRequest("1")
        let view = NSHostingView(rootView: NaturalDetailFixture(store: store, scheme: .light))
        view.setFrameSize(NSSize(width: 380, height: 800))
        func settle() async {
            for _ in 0..<10 {
                await Task.yield()
                view.layoutSubtreeIfNeeded()
                view.setFrameSize(NSSize(width: 380, height: view.fittingSize.height))
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        func clickDisclosure() {
            let button = findDisclosures(view).first { $0.identifier?.rawValue == "request-group-\(groupID)" }!
            _ = NSApp.sendAction(button.action!, to: button.target, from: button)
        }
        func capture(_ name: String) {
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try! image.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent(name))
        }
        await settle()
        let history = findRequestScroll(view)!, table = history.documentView as! NSTableView
        precondition(table.numberOfRows == 99 && findDisclosures(view).count == 1, "new page is not collapsed by default")
        precondition(store.detailSpeed?.id == "2", "opening a collapsed page leaves a hidden child selected")
        store.selectRequest("99")
        await settle()
        capture("groups-collapsed-light.png")
        clickDisclosure()
        await settle()
        precondition(table.numberOfRows == 100 && store.detailSpeed?.id == "99", "expanding changed unrelated selection")
        capture("groups-expanded-light.png")
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await settle()
        precondition(store.detailSpeed?.id == "1", "expanded API row does not select its own details")
        await store.refreshThroughput()
        await settle()
        precondition(table.numberOfRows == 100 && store.detailSpeed?.id == "1", "refresh collapsed the group or changed child selection")
        store.selectedModel = "codex-auto-review"
        await settle()
        let singleCallTable = findRequestScroll(view)!.documentView as! NSTableView
        precondition(singleCallTable.numberOfRows == 1 && findDisclosures(view).isEmpty,
                     "a single-call model is hidden behind a disclosure")
        store.selectedModel = "gpt-6.1-sol"
        await settle()
        let restored = findRequestScroll(view)!.documentView as! NSTableView
        precondition(restored.numberOfRows == 100, "model filtering lost the expanded group's state")
        store.selectRequest("1")
        await settle()
        clickDisclosure()
        await settle()
        precondition(restored.numberOfRows == 99 && store.detailSpeed?.id == "2", "collapsing a selected child does not show its parent's details")
        precondition(store.latestSpeed?.rate == 80 && store.averageSpeed == 62 && store.recentSpeeds.count == 100,
                     "disclosure changed TPS statistics or underlying retention")
        print("Disclosures: native buttons expand/collapse; child selection, refresh state, parent fallback and unchanged TPS passed.")
    }

}
