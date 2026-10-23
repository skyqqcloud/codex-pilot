import SwiftUI
import AppKit

struct ThroughputPanel: View {
    @ObservedObject var store: SwapStore
    let showDetails: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.string("输出速度")).font(.system(size: 12)).foregroundStyle(palette.secondary)
                Spacer()
                SpeedModelPicker(store: store, width: PanelLayout.modelControlWidth)
            }
            HStack(alignment: .top, spacing: PanelLayout.metricSpacing) {
                speed(L10n.string("最近 1 次"), value: store.latestSpeed?.rate, id: "speed-latest")
                speed(L10n.string("最近 5 次平均"), value: store.averageSpeed, id: "speed-average")
            }
            HStack {
                Text(summary).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: showDetails) {
                    HStack(spacing: 3) {
                        Text(L10n.string("统计详情"))
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.ink)
                    .padding(.horizontal, 8).frame(minHeight: 28)
                }.buttonStyle(PanelButtonStyle(kind: .neutral, cornerRadius: 6))
                    .accessibilityIdentifier("throughput-details")
            }.font(.system(size: 10)).foregroundStyle(palette.tertiary)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, PanelLayout.contentInset).padding(.top, 6).padding(.bottom, 10)
    }

    private var summary: String {
        if !store.throughputLoaded { return L10n.string("正在读取统计…") }
        if let sample = store.latestSpeed {
            let date = Date(timeIntervalSince1970: sample.completedAt)
            let average = store.requestSpeeds.averageResult(model: store.selectedModel)
            let count = average.measuredCount < 5 ? L10n.string(" · 均值 \(average.measuredCount) 次有效") : ""
            return L10n.string("上次 \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))\(count)")
        }
        if store.captureError != nil { return L10n.string("测速采集暂不可用") }
        return store.captureEnabled ? L10n.string("等待新的测速数据") : L10n.string("在设置中开启测速采集")
    }

    private func speed(_ title: String, value: Double?, id: String) -> some View {
        let palette = PanelPalette(scheme: scheme)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map(PanelFormat.rate) ?? "—")
                    .font(.system(size: 26, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityIdentifier(id)
                Text("token/s").font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityValue(value.map { "\(PanelFormat.rate($0)) token/s" } ?? L10n.string("暂无样本"))
            .help(L10n.string("每次 API 的非推理输出 token ÷ 对应输出阶段耗时；推理 token 单独展示。") + store.requestSpeeds.averageResult(model: store.selectedModel).explanation)
    }
}

struct SpeedModelPicker: View {
    @ObservedObject var store: SwapStore
    let width: CGFloat
    var body: some View {
        PanelPicker(L10n.string("选择统计模型"), selection: $store.selectedModel,
            options: [PanelPickerOption(value: "", title: L10n.string("全部模型"))] +
                store.modelNames.map { PanelPickerOption(value: $0, title: PanelFormat.model($0)) }, width: width)
            .frame(width: width, height: PanelLayout.controlHeight)
            .accessibilityIdentifier("throughput-model")
    }
}

struct ThroughputDetailPanel: View {
    private struct DetailKey: Hashable {
        let id: String?
        let context: RequestCallContext?
    }
    @ObservedObject var store: SwapStore
    @Environment(\.colorScheme) private var scheme
    @State private var callContext: RequestCallContext?
    @State private var loadedMessageID: String?
    @State private var showCalculationInfo = false
    @State private var expandedGroups: Set<String> = []
    private let calculationInfo = L10n.string("测速 token = API 总输出 token − 推理 token（仍含工具参数与格式 token）。从首个正文或工具输出项到完成计时，排除此前等待及请求间空闲；期间的推理或缓冲停顿仍会计入。缺少可靠起点显示「—」。最近 5 次请求中有计时的速度取算术平均，不足 5 次按实际数量计算；这表示客户端输出阶段速率。极短输出可能集中到达，瞬时高值不代表模型持续生成速度。")

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        let detail = store.detailSpeed
        let groups = store.requestGroups
        let rows = RequestHistoryRow.make(groups, expanded: expandedGroups)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string("统计模型"))
                Spacer()
                SpeedModelPicker(store: store, width: PanelLayout.modelControlWidth)
            }.padding(.vertical, 10)
            Divider()
            HStack {
                Text(L10n.string("输出速度"))
                Button { showCalculationInfo.toggle() } label: {
                    Image(systemName: "info.circle").frame(width: 22, height: 22)
                }
                .buttonStyle(PanelButtonStyle(cornerRadius: 5))
                .accessibilityLabel(L10n.string("测速统计说明"))
                .accessibilityIdentifier("speed-calculation-info")
                .popover(isPresented: $showCalculationInfo) {
                    Text(calculationInfo).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14).frame(width: 280)
                }
                Spacer()
                Text(L10n.string("最近 1 次")).frame(width: 67, alignment: .trailing)
                Text(L10n.string("5 次平均")).frame(width: 67, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.top, 12).padding(.bottom, 4)
            if displayedModels.isEmpty {
                Text(store.requestHistoryReady ? L10n.string("暂无测速样本") : L10n.string("正在读取测速…"))
                    .foregroundStyle(palette.secondary).padding(.vertical, 15)
            } else {
                ForEach(displayedModels, id: \.self) { model in
                    HStack {
                        Text(PanelFormat.model(model)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(rate(store.requestSpeeds.latest(model: model)?.rate)).frame(width: 67, alignment: .trailing)
                        Text(rate(store.requestSpeeds.average(model: model))).frame(width: 67, alignment: .trailing)
                            .help(store.requestSpeeds.averageResult(model: model).explanation)
                    }.monospacedDigit().padding(.vertical, 11)
                    Divider()
                }
            }
            HStack {
                section(L10n.string("最近请求"))
                Spacer()
                Text(store.requestHistoryReady ? L10n.string("\(store.recentSpeeds.count) 条") : L10n.string("整理中"))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.tertiary).padding(.top, 16).padding(.bottom, 3)
            }
            if store.requestHistoryReady {
                RequestHistoryList(ids: rows.map { $0.sample.id }, onSelect: store.selectRequest) { index in
                    let row = rows[index]
                    return requestRow(row, selectedID: detail?.id)
                        .padding(.horizontal, PanelLayout.contentInset)
                }
                .frame(height: PanelLayout.requestHistoryHeight)
                .padding(.horizontal, -PanelLayout.contentInset)
                .id(store.selectedModel)
                .accessibilityIdentifier("request-history")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("正在整理对话…")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }.frame(maxWidth: .infinity).frame(height: PanelLayout.requestHistoryHeight)
                    .accessibilityIdentifier("request-history-loading")
            }
            Divider().padding(.top, 8)
            if let sample = detail {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string("请求详情")).font(.system(size: 11))
                    Spacer()
                    Text("\(rate(sample.rate)) token/s")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.ink)
                        .monospacedDigit().accessibilityIdentifier("request-detail-rate")
                }.foregroundStyle(palette.secondary).padding(.top, 12)
                Text(Date(timeIntervalSince1970: sample.completedAt).formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)))
                    .font(.system(size: 9)).foregroundStyle(palette.tertiary)
                    .padding(.top, 3).padding(.bottom, 10)
                    .accessibilityIdentifier("request-detail-time")
                Grid(alignment: .leading, horizontalSpacing: PanelLayout.metricSpacing, verticalSpacing: 10) {
                    GridRow {
                        metric(L10n.string("非推理输出 token"), PanelFormat.tokens(sample.streamedOutputTokens), id: "request-detail-output")
                            .help(L10n.string("API 总输出 \(PanelFormat.tokens(sample.outputTokens)) token，其中推理 \(PanelFormat.tokens(sample.reasoningTokens)) token；测速使用其余 \(PanelFormat.tokens(sample.streamedOutputTokens)) token。"))
                        metric(L10n.string("输入 token"), PanelFormat.tokens(sample.inputTokens), id: "request-detail-input")
                    }
                    GridRow {
                        metric(L10n.string("输出耗时"), sample.outputDuration.map { String(format: L10n.string("%.2f 秒"), $0) } ?? "—", id: "request-detail-duration")
                            .help(L10n.string("首个正文或工具输出项到完成的客户端观测区间。短输出可能集中到达，速率不等于模型内部持续生成速度。"))
                        metric(L10n.string("推理 token"), PanelFormat.tokens(sample.reasoningTokens), id: "request-detail-reasoning")
                    }
                    GridRow {
                        metric(L10n.string("输出前等待"), sample.outputWait.map { String(format: L10n.string("%.2f 秒"), $0) } ?? "—", id: "request-detail-wait")
                            .help(L10n.string("正文或工具输出前的准备与推理等待；官方原始 TTFT 为 \(String(format: "%.3f", sample.ttftSeconds)) 秒。"))
                        metric(L10n.string("缓存比例"), sample.inputTokens == 0 ? "—" : "\(Int((Double(sample.cachedTokens) / Double(sample.inputTokens) * 100).rounded()))%", id: "request-detail-cache")
                    }
                }
                requestText(sample).padding(.top, 16)
            }
            if let error = store.captureError {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.amber).padding(.top, 8)
            }
        }
        .font(.system(size: 12)).foregroundStyle(palette.ink)
        .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 18)
        .onAppear { keepSelectionVisible(groups: groups, rows: rows) }
        .onChange(of: rows.map(\.id)) { keepSelectionVisible(groups: groups, rows: rows) }
        .task(id: DetailKey(id: detail?.id, context: detail.flatMap { store.requestContexts[$0.id] })) {
            guard let sample = detail else { return }
            if loadedMessageID != sample.id {
                callContext = nil
                loadedMessageID = nil
            }
            let context = await store.requestContext(for: sample)
            guard !Task.isCancelled, store.detailSpeed?.id == sample.id else { return }
            callContext = context
            loadedMessageID = sample.id
        }
    }

    private var displayedModels: [String] {
        store.selectedModel.isEmpty ? store.requestSpeeds.modelNames : [store.selectedModel]
    }
    private func keepSelectionVisible(groups: [RequestHistoryGroup], rows: [RequestHistoryRow]) {
        let selected = store.detailSpeed?.id
        if let visible = RequestHistoryRow.visibleSelection(selected, groups: groups, rows: rows), visible != selected {
            store.selectRequest(visible)
        }
    }
    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) }
        else { expandedGroups.insert(id) }
        let groups = store.requestGroups
        keepSelectionVisible(groups: groups, rows: RequestHistoryRow.make(groups, expanded: expandedGroups))
    }
    private func requestText(_ sample: RequestSpeedSample) -> some View {
        let palette = PanelPalette(scheme: scheme)
        let loaded = loadedMessageID == sample.id
        let sections = loaded ? (callContext ?? RequestCallContext()).detailSections : [
            RequestCallContent(kind: "user", title: L10n.string("发起消息"), text: L10n.string("正在读取消息…")),
            RequestCallContent(kind: "output", title: L10n.string("本次调用"), text: L10n.string("正在读取输出…")),
        ]
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, part in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(part.displayTitle).font(.system(size: 10)).foregroundStyle(palette.secondary)
                        messageText(part.displayText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(part.kind == "source" ? "request-detail-source" :
                            (part.kind == "user" ? "request-detail-message" : "request-detail-content-\(index)"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: textHeight(sections), alignment: .topLeading)
    }
    private func textHeight(_ sections: [RequestCallContent]) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let width = PanelLayout.width - 2 * PanelLayout.contentInset
        let height = sections.reduce(CGFloat(0)) { sum, part in
            let attributed = NSAttributedString(string: String(part.displayText.prefix(2048)), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph,
            ])
            let height = attributed.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            return sum + 18 + ceil(height) + 3
        } + CGFloat(max(0, sections.count - 1)) * 12
        return min(144, height)
    }
    private func messageText(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func rate(_ value: Double?) -> String { value.map(PanelFormat.rate) ?? "—" }
    private func section(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(PanelPalette(scheme: scheme).secondary)
            .padding(.top, 12).padding(.bottom, 3)
    }
    private func requestRow(_ row: RequestHistoryRow, selectedID: String?) -> some View {
        let sample = row.sample
        let initiatingPreview = row.preview
        let indented = row.indented
        let palette = PanelPalette(scheme: scheme)
        let selected = selectedID == sample.id
        let context = store.requestContexts[sample.id]
        return VStack(spacing: 0) {
            Button { store.selectRequest(sample.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let preview = initiatingPreview {
                            HStack(spacing: 6) {
                                if row.canExpand { Color.clear.frame(width: 10, height: 10) }
                                else { Image(systemName: "bubble.left").font(.system(size: 10)).foregroundStyle(palette.secondary) }
                                Text(verbatim: preview).font(.system(size: 11, weight: .medium))
                                    .lineLimit(1).truncationMode(.tail).help(preview)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            requestModel(sample)
                        }
                        Spacer(minLength: 6)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(rate(sample.rate)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            Text("token/s").font(.system(size: 10)).foregroundStyle(palette.secondary)
                        }.fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if initiatingPreview != nil {
                            HStack(spacing: 5) {
                                requestModel(sample).font(.system(size: 10))
                                if let source = context?.sourceTitle {
                                    Text(L10n.key(source)).font(.system(size: 9)).lineLimit(1)
                                        .help(context?.displaySourceDescription ?? L10n.key(source))
                                }
                                Text(row.canExpand ? L10n.string("本组首条 · \(row.callCount) 次") : L10n.string("本组首条"))
                                    .font(.system(size: 9)).foregroundStyle(palette.tertiary).fixedSize()
                                    .help(L10n.string("当前筛选下，此消息关联 \(row.callCount) 次已采集调用；这里显示本组最早的一笔调用及其 TPS，更早的调用可能未采集或已超出保留范围。"))
                            }.foregroundStyle(palette.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 4) {
                                if context?.outputKind == "tool" {
                                    Image(systemName: "wrench").font(.system(size: 9))
                                }
                                Text(verbatim: context?.displayOutputPreview ?? L10n.string("未关联本地输出"))
                                    .lineLimit(1).truncationMode(.tail)
                            }.font(.system(size: 10)).foregroundStyle(palette.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(context?.displaySourceDescription ?? context?.displayOutputPreview ?? L10n.string("未找到该次 API 调用的本地输出记录"))
                        }
                        Text(PanelFormat.requestTime(sample.completedAt))
                            .font(.system(size: 10)).foregroundStyle(palette.tertiary).monospacedDigit().fixedSize()
                            .help(Date(timeIntervalSince1970: sample.completedAt).formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)))
                    }
                }.frame(height: PanelLayout.requestRowHeight - 0.5).padding(.horizontal, 8)
                    .overlay(alignment: .leading) {
                        if selected {
                            RoundedRectangle(cornerRadius: 1).fill(palette.green)
                                .frame(width: 2, height: 24).offset(x: 2)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(PanelButtonStyle(cornerRadius: 6, highlighted: selected))
            .padding(.horizontal, -8)
            .accessibilityIdentifier("request-row-\(sample.id)")
            .accessibilityValue(selected ? L10n.string("已选中") : "")
            .overlay(alignment: .topLeading) {
                if row.canExpand, let groupID = row.groupID {
                    RequestGroupDisclosure(groupID: groupID, expanded: expandedGroups.contains(groupID), callCount: row.callCount) {
                        toggleGroup(groupID)
                    }.frame(width: 22, height: 24).offset(x: -6, y: 5)
                }
            }
            Rectangle().fill(palette.rule.opacity(0.65)).frame(height: 0.5)
        }.padding(.leading, indented ? 14 : 0)
            .overlay(alignment: .leading) {
                if indented {
                    Rectangle().fill(palette.rule).frame(width: 1).padding(.leading, 3)
                        .accessibilityHidden(true)
                }
            }
    }
    private func requestModel(_ sample: RequestSpeedSample) -> some View {
        let palette = PanelPalette(scheme: scheme)
        return HStack(spacing: 5) {
            Text(PanelFormat.model(sample.model)).lineLimit(1).truncationMode(.middle)
                .help(PanelFormat.model(sample.model))
            if sample.isFast {
                Text("Fast").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.green)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(palette.green.opacity(0.10), in: Capsule())
                    .fixedSize().help(L10n.string("此请求选择了 Fast 模式"))
            }
        }
    }
    private func metric(_ title: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(PanelPalette(scheme: scheme).secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
                .accessibilityIdentifier(id)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
