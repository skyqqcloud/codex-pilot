import AppKit
import SwiftUI

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
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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
        precondition(PanelFormat.tokens(109114) == "109,114", "token counts are not grouped")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12, minute: 30, second: 45))!
        precondition(PanelFormat.requestTime(date.timeIntervalSince1970, now: date, calendar: calendar) == "12:30:45",
                     "today's requests still repeat the full date")
        precondition(PanelFormat.requestTime(date.addingTimeInterval(-86400).timeIntervalSince1970, now: date, calendar: calendar) == "10月9日 12:30:45",
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
        precondition(store.slots.first { $0.name == "b" }?.planTitle == "Pro", "plan refresh fixture did not start from a paid plan")
        await store.refreshSlot("b")
        let free = store.slots.first { $0.name == "b" }!
        precondition(free.planTitle == "Free" && free.fiveWindowTitle == "30 天" && free.hasSingleFreeWindow,
                     "manual quota refresh did not update the plan and actual Free quota period")
        let unknownPlan = free.withQuota(SlotQuota(five: 80, fiveWhen: "", fiveResetAt: nil, week: nil,
                                                 weekWhen: "", weekResetAt: nil, fetchedAt: nil))
        precondition(unknownPlan.planTitle == "Free", "an absent server plan reverted the account to its old token plan")
        await store.refreshLocalState()
        precondition(store.slots.first { $0.name == "b" }?.planTitle == "Free",
                     "reopening the panel did not retain the server-confirmed plan")
        print("Plan refresh: manual update and reload keep Free / 30-day period; missing plan keeps last known plan.")
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
                let previewHistory = findScroll(badgePreview)!
                precondition(previewHistory.contentView.bounds.origin.y < 1, "new history view starts away from the latest request")
                precondition(abs(previewHistory.contentView.bounds.height - 216) < 0.5,
                             "all-model history was compressed instead of showing 4.5 rows")
                let badgeImage = badgePreview.bitmapImageRepForCachingDisplay(in: badgePreview.bounds)!
                badgePreview.cacheDisplay(in: badgePreview.bounds, to: badgeImage)
                try badgeImage.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("detail-\(scheme).png"))
                precondition(scroll.hasVerticalScroller == (document.frame.height > scroll.contentView.bounds.height + 0.5),
                             "scroller is not conditional on actual overflow")
                let history = findScroll(document)!
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
                precondition(pickers.count == 1, "obsolete window selector is still present")
                let modelPicker = pickers.first { $0.itemTitles.contains("全部模型") }!
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
                let filteredHistory = findScroll(badgePreview)!
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

    static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
        return nil
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
        let history = findScroll(view)!, table = history.documentView as! NSTableView
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
        let singleCallTable = findScroll(view)!.documentView as! NSTableView
        precondition(singleCallTable.numberOfRows == 1 && findDisclosures(view).isEmpty,
                     "a single-call model is hidden behind a disclosure")
        store.selectedModel = "gpt-6.1-sol"
        await settle()
        let restored = findScroll(view)!.documentView as! NSTableView
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
