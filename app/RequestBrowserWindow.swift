import AppKit
import SwiftUI

@MainActor
final class RequestBrowserState: ObservableObject {
    @Published var project = ""
    @Published var conversation = ""
    @Published var query = ""
    @Published var source = ""
    @Published var expanded: Set<String> = []
    @Published var pinned = false
}

/// Closing the window releases its observed SwiftUI tree; filter state is cheap
/// and remains in memory. This never starts another collector or scan timer.
@MainActor
final class RequestBrowserWindow: NSObject, NSWindowDelegate {
    private static let shared = RequestBrowserWindow()
    private let state = RequestBrowserState()
    private var window: NSWindow?

    static func show(store: SwapStore) {
        let owner = shared
        if let window = owner.window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("调用详情")
        window.identifier = NSUserInterfaceItemIdentifier("request-browser")
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RequestBrowser3")
        window.delegate = owner
        window.level = owner.state.pinned ? .floating : .normal
        window.contentView = NSHostingView(rootView: RequestBrowserView(store: store, state: owner.state))
        owner.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }

    static var isOpen: Bool { shared.window != nil }
    static func setPinned(_ pinned: Bool) { shared.window?.level = pinned ? .floating : .normal }
}

struct RequestBrowserView: View {
    @ObservedObject var store: SwapStore
    @ObservedObject var state: RequestBrowserState
    @Environment(\.colorScheme) private var scheme

    private var palette: PanelPalette { PanelPalette(scheme: scheme) }
    private var filter: RequestBrowseFilter {
        RequestBrowseFilter(projectPath: state.project, conversationID: state.conversation,
                            query: state.query, source: state.source)
    }
    private var samples: [RequestSpeedSample] {
        store.recentSpeeds.filter { filter.matches($0, context: store.requestContexts[$0.id]) }
    }
    private var projects: [String] { Array(Set(store.requestContexts.values.compactMap(\.projectPath))).sorted() }
    private var conversations: [(id: String, title: String)] {
        let candidates = store.recentSpeeds.filter { state.project.isEmpty || store.requestContexts[$0.id]?.projectPath == state.project }
        var seen: Set<String> = []
        return candidates.compactMap { sample in
            guard let id = sample.conversationID, seen.insert(id).inserted else { return nil }
            return (id, store.requestContexts[sample.id]?.conversationTitle ?? String(id.prefix(8)))
        }
    }
    private var groups: [RequestHistoryGroup] { RequestHistoryGroup.make(samples, contexts: store.requestContexts) }
    private var rows: [RequestHistoryRow] { RequestHistoryRow.make(groups, expanded: state.expanded) }
    private var selection: RequestSpeedSample? {
        samples.first { $0.id == store.selectedRequestID } ?? rows.first?.sample
    }

    var body: some View {
        // Freeze IDs and row content together. A bridge callback can run after
        // ObservableObject filters changed but before the next NSView update.
        let listRows = rows
        VStack(spacing: 0) {
            controls
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.string("最近请求")).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(L10n.string("\(samples.count) 条")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }.padding(14)
                    if !store.requestHistoryReady {
                        ProgressView(L10n.string("正在整理对话…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if listRows.isEmpty {
                        emptyList
                    } else {
                        GeometryReader { geometry in
                            RequestHistoryList(ids: listRows.map(\.id), onSelect: store.selectRequest,
                                width: geometry.size.width, viewportHeight: geometry.size.height, selection: selection?.id) { index in
                                browserRow(listRows[index]).padding(.horizontal, 14)
                            }
                        }
                    }
                }.frame(minWidth: 340, idealWidth: 400, maxWidth: 480)
                Group {
                    if let sample = selection {
                        RequestInspector(store: store, sample: sample)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(palette.tertiary)
                            Text(L10n.string("选择一次调用查看详情"))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Image(systemName: "internaldrive")
                Text(L10n.string("搜索已保留的消息与输出摘要；完整内容在选中时读取。"))
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(palette.paper).foregroundStyle(palette.ink)
        .preferredColorScheme(store.appearance.colorScheme)
        .onChange(of: state.project) { state.conversation = "" }
        .onChange(of: state.pinned) { RequestBrowserWindow.setPinned(state.pinned) }
        .onChange(of: listRows.map(\.id)) {
            if let sample = selection, !rows.contains(where: { $0.id == sample.id }),
               let visible = RequestHistoryRow.visibleSelection(sample.id, groups: groups, rows: rows) {
                store.selectRequest(visible)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker(L10n.string("项目"), selection: $state.project) {
                    Text(L10n.string("全部项目")).tag("")
                    ForEach(projects, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                    }
                }.frame(maxWidth: .infinity).accessibilityIdentifier("browser-project")
                Picker(L10n.string("对话"), selection: $state.conversation) {
                    Text(L10n.string("全部对话")).tag("")
                    ForEach(conversations, id: \.id) { item in Text(verbatim: item.title).tag(item.id) }
                }.frame(maxWidth: .infinity).accessibilityIdentifier("browser-conversation")
                SpeedModelPicker(store: store, width: 225)
            }
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
                    TextField(L10n.string("搜索消息、输出或模型"), text: $state.query)
                        .textFieldStyle(.plain).accessibilityIdentifier("browser-search")
                    if !state.query.isEmpty {
                        Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.string("清除搜索"))
                    }
                }.padding(8).background(palette.inset, in: RoundedRectangle(cornerRadius: 6))
                Picker(L10n.string("来源"), selection: $state.source) {
                    Text(L10n.string("全部来源")).tag("")
                    Text(L10n.string("用户对话")).tag("conversation")
                    Text(L10n.string("消息建议")).tag("suggestion")
                    Text(L10n.string("上下文压缩")).tag("compaction")
                    Text(L10n.string("来源待确认")).tag("unknown")
                }.frame(width: 210).accessibilityIdentifier("browser-source")
                Button { state.pinned.toggle() } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(state.pinned ? palette.green : palette.secondary).frame(width: 24, height: 26)
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("窗口置顶"))
                    .help(L10n.string("保持在其他窗口上方"))
            }
        }.font(.system(size: 12)).padding(14)
    }

    private var emptyList: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 26)).foregroundStyle(palette.tertiary)
            Text(L10n.string("没有符合条件的调用"))
            Button(L10n.string("清除筛选")) {
                state.query = ""; state.project = ""; state.conversation = ""; state.source = ""; store.selectedModel = ""
            }.buttonStyle(.bordered)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func browserRow(_ row: RequestHistoryRow) -> some View {
        let sample = row.sample
        let context = store.requestContexts[sample.id]
        let selected = selection?.id == sample.id
        return HStack(spacing: 6) {
            if row.canExpand, let id = row.groupID {
                Button {
                    if state.expanded.contains(id) { state.expanded.remove(id) } else { state.expanded.insert(id) }
                } label: {
                    Image(systemName: state.expanded.contains(id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).frame(width: 16, height: 34)
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("展开或折叠关联调用"))
            } else {
                Image(systemName: row.indented ? "arrow.turn.down.right" : row.preview != nil ? "bubble.left" :
                        context?.sourceKind == "suggestion" ? "sparkles" : context?.sourceKind == "compaction" ?
                        "arrow.triangle.2.circlepath" : "arrow.left.arrow.right")
                    .font(.system(size: 10)).foregroundStyle(palette.tertiary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: row.preview ?? PanelFormat.model(sample.statisticsModel))
                        .font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(sample.rate.map(PanelFormat.rate) ?? "—") token/s")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().fixedSize()
                }
                HStack(spacing: 5) {
                    Text(verbatim: row.preview != nil ? PanelFormat.model(sample.statisticsModel) :
                         (context?.displayOutputPreview ?? L10n.string("来源待确认"))).lineLimit(1)
                    if row.preview != nil {
                        Text(row.canExpand ? L10n.string("本组首条 · \(row.callCount) 次") : L10n.string("本组首条"))
                            .font(.system(size: 9)).fixedSize()
                            .help(L10n.string("当前筛选下，此消息关联 \(row.callCount) 次已采集调用；这里显示本组最早的一笔调用及其 TPS，更早的调用可能未采集或已超出保留范围。"))
                    }
                    Spacer(minLength: 4)
                    Text(PanelFormat.requestTime(sample.completedAt)).monospacedDigit().fixedSize()
                }.font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
        }
        .padding(.leading, row.indented ? 14 : 0)
        .frame(maxWidth: .infinity, minHeight: PanelLayout.requestRowHeight)
        .padding(.horizontal, 6)
        .background(selected ? palette.inset : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) { if selected { Capsule().fill(palette.green).frame(width: 2, height: 24) } }
        .contentShape(Rectangle()).onTapGesture { store.selectRequest(sample.id) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("browser-row-\(sample.id)")
    }
}

struct RequestInspector: View {
    @ObservedObject var store: SwapStore
    let sample: RequestSpeedSample
    @Environment(\.colorScheme) private var scheme
    @State private var fullContext: RequestCallContext?
    @State private var loadedID: String?
    @State private var readFailed = false
    @State private var readAttempt = 0

    private var context: RequestCallContext? { loadedID == sample.id ? fullContext : store.requestContexts[sample.id] }
    private var palette: PanelPalette { PanelPalette(scheme: scheme) }
    private var sections: [RequestCallContent] {
        loadedID == sample.id ? (context ?? RequestCallContext()).detailSections : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(PanelFormat.model(sample.statisticsModel)).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(sample.rate.map(PanelFormat.rate) ?? "—") token/s")
                        .font(.system(size: 20, weight: .medium)).monospacedDigit()
                        .help(L10n.string("每次 API 的非推理输出 token ÷ 对应输出阶段耗时；推理 token 单独展示。"))
                }
                Text(Date(timeIntervalSince1970: sample.completedAt).formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                provenance
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 16) {
                    GridRow {
                        value(L10n.string("非推理输出 token"), PanelFormat.tokens(sample.streamedOutputTokens))
                        value(L10n.string("输入 token"), PanelFormat.tokens(sample.inputTokens))
                    }
                    GridRow {
                        value(L10n.string("输出耗时"), seconds(sample.outputDuration))
                        value(L10n.string("推理 token"), PanelFormat.tokens(sample.reasoningTokens))
                    }
                    GridRow {
                        value(L10n.string("输出前等待"), seconds(sample.outputWait))
                        value(L10n.string("缓存比例"), sample.inputTokens > 0 ? "\(Int((Double(sample.cachedTokens) / Double(sample.inputTokens) * 100).rounded()))%" : "—")
                    }
                }
                Divider()
                if loadedID != sample.id {
                    ProgressView(L10n.string("正在读取输出…")).controlSize(.small)
                } else {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, part in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(part.displayTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                            Text(verbatim: part.displayText).font(.system(size: 13)).lineSpacing(4)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if readFailed {
                    HStack {
                        Text(L10n.string("本地内容读取失败，请重试。"))
                            .font(.system(size: 11)).foregroundStyle(palette.amber)
                        Button(L10n.string("重新读取")) { readAttempt += 1 }.buttonStyle(.bordered)
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("browser-inspector")
        .task(id: InspectorKey(id: sample.id, context: store.requestContexts[sample.id], attempt: readAttempt)) {
            loadedID = nil; fullContext = nil; readFailed = false
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let resolved = await store.requestContext(for: sample)
            guard !Task.isCancelled else { return }
            fullContext = resolved ?? store.requestContexts[sample.id]
            readFailed = resolved == nil && sample.conversationID != nil
            loadedID = sample.id
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let path = context?.projectPath {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                    .help(path).textSelection(.enabled)
            }
            if let title = context?.conversationTitle {
                Label { Text(verbatim: title).textSelection(.enabled) } icon: { Image(systemName: "bubble.left") }
            } else if let id = sample.conversationID {
                Label(String(id.prefix(8)), systemImage: "bubble.left").help(id)
            }
            Text(context?.sourceTitle.map(L10n.key) ?? (context?.groupID != nil ? L10n.string("用户对话") : L10n.string("来源待确认")))
                .foregroundStyle(palette.secondary)
            if let description = context?.displaySourceDescription ?? context?.associationExplanation {
                Text(description).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            } else if sample.conversationID == nil {
                Text(L10n.string("采集记录缺少对话标识，无法确认项目与消息归属。"))
                    .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if sample.serviceTier == nil {
                Text(L10n.string("服务档位未记录；此调用未计入 Fast。"))
                    .foregroundStyle(palette.secondary)
            }
        }.font(.system(size: 11))
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text(text).font(.system(size: 17, weight: .medium)).monospacedDigit().textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func seconds(_ value: Double?) -> String {
        value.map { String(format: L10n.string("%.2f 秒"), $0) } ?? "—"
    }
    private struct InspectorKey: Hashable { let id: String; let context: RequestCallContext?; let attempt: Int }
}
