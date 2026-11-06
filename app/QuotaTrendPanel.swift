import AppKit
import SwiftUI

enum QuotaTrendRange: Int, CaseIterable {
    case hour = 3600, threeHours = 10800, day = 86400, week = 604800
    var title: String {
        switch self {
        case .hour: return L10n.string("最近 1 小时")
        case .threeHours: return L10n.string("最近 3 小时")
        case .day: return L10n.string("最近 24 小时")
        case .week: return L10n.string("最近 7 天")
        }
    }
}

@MainActor
final class QuotaTrendModel: ObservableObject {
    static let rangePreferenceKey = "QuotaTrendRangeSeconds"
    @Published var row: SlotRow
    @Published var range: QuotaTrendRange {
        didSet {
            if range != oldValue { defaults.set(range.rawValue, forKey: Self.rangePreferenceKey) }
        }
    }
    @Published var snapshot = QuotaHistorySnapshot()
    @Published var loading = true
    @Published var error = false
    @Published var now = Date().timeIntervalSince1970
    let historyURL: URL
    private let defaults: UserDefaults
    init(row: SlotRow, historyURL: URL = QuotaHistoryReader.defaultURL, defaults: UserDefaults = .standard) {
        self.row = row; self.historyURL = historyURL; self.defaults = defaults
        // One app-wide preference: every newly opened account card reads the
        // same range. Only user selection writes it; no observer or polling.
        range = QuotaTrendRange(rawValue: defaults.integer(forKey: Self.rangePreferenceKey)) ?? .day
    }
    var visibleWindows: [QuotaHistoryWindow] {
        (row.five == nil ? [] : [.primary]) + (row.week == nil ? [] : [.secondary])
    }
    func series(for window: QuotaHistoryWindow) -> QuotaHistorySeries {
        QuotaHistorySeries(snapshot.observations, window: window, since: now - Double(range.rawValue), now: now)
    }
    func load() async {
        guard let identity = row.quotaHistoryID else { loading = false; return }
        let stamp = Date().timeIntervalSince1970
        do {
            let result = try await Task.detached(priority: .utility) { [historyURL] in
                try await QuotaHistoryReader.shared.load(identity: identity, url: historyURL, now: stamp)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = result; now = stamp; error = false
        } catch { if !Task.isCancelled { self.error = true } }
        loading = false
    }
}

struct QuotaTrendPanel: View {
    static let width: CGFloat = 340
    @ObservedObject var model: QuotaTrendModel
    var refresh: () -> Void = {}
    var close: () -> Void = {}
    var onInspectionChanged: (Bool) -> Void = { _ in }
    @State private var showInfo = false
    @Environment(\.colorScheme) private var scheme
    private var palette: PanelPalette { PanelPalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.row.planTitle).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    PanelPicker(L10n.string("时间范围"), selection: $model.range,
                        options: QuotaTrendRange.allCases.map { PanelPickerOption(value: $0, title: $0.title) }, width: 118)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(PanelButtonStyle(cornerRadius: 5)).foregroundStyle(palette.secondary)
                    .help(L10n.string("关闭")).accessibilityLabel(L10n.string("关闭"))
                }
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity).frame(height: 88)
            } else if model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("未能读取额度历史"))
                    Button(L10n.string("重新读取")) { Task { await model.load() } }
                }.font(.system(size: 12)).frame(height: 72)
            } else if model.snapshot.observations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("从下一次成功刷新开始记录")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Button(L10n.string("刷新这个账号额度"), action: refresh)
                        .font(.system(size: 11)).buttonStyle(PanelButtonStyle(kind: .neutral, cornerRadius: 5, backgroundPadding: 4))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                ForEach(model.visibleWindows, id: \.self) { window in
                    if window != model.visibleWindows.first { Divider() }
                    section(window, title: window == .primary ? model.row.fiveWindowTitle : model.row.weekWindowTitle,
                            value: window == .primary ? model.row.five : model.row.week)
                }
                if model.visibleWindows.isEmpty {
                    Text(L10n.string("暂无数据")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            HStack(spacing: 4) {
                Text(PanelFormat.updated(model.snapshot.observations.last.map { Date(timeIntervalSince1970: $0.time) }))
                Spacer()
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 11)).frame(width: 22, height: 22)
                }
                .buttonStyle(PanelButtonStyle(cornerRadius: 5))
                .accessibilityLabel(L10n.string("额度历史说明")).help(L10n.string("额度历史说明"))
                .accessibilityIdentifier("quota-history-info")
                .popover(isPresented: $showInfo) {
                    QuotaTrendInfo(model: model).onExitCommand { showInfo = false }
                }
            }.font(.system(size: 10)).foregroundStyle(palette.tertiary)
        }
        .padding(16).frame(width: Self.width)
        .background(palette.paper).foregroundStyle(palette.ink)
        .accessibilityIdentifier("quota-trend-panel")
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.string("额度变化"))
        .onChange(of: showInfo) { onInspectionChanged(showInfo) }
        .onDisappear { onInspectionChanged(false) }
        .onExitCommand(perform: close)
    }

    private func section(_ window: QuotaHistoryWindow, title: String, value: Int?) -> some View {
        let start = model.now - Double(model.range.rawValue)
        let series = model.series(for: window)
        let matchesCurrent = series.currentSegment.last?.remaining == value
        let drop = matchesCurrent ? series.hourlyDrop(now: model.now) : nil
        let low = matchesCurrent ? series.firstLowObservation : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.string("\(title)剩余")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer()
                Text(value.map { "\($0)%" } ?? "—").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            }
            if series.segments.isEmpty {
                Text(L10n.string("这个时间范围内暂无采样"))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).frame(height: 70)
            } else {
                QuotaTrendChart(series: series, start: start, end: model.now)
            }
            Group {
                if let low, let value {
                    Text(L10n.string("\(Self.time(low.time)) 首次记录到 ≤\(value)%"))
                } else if let drop, drop != 0 {
                    Text(drop > 0 ? L10n.string("约 1 小时下降 \(drop) 个百分点") : L10n.string("约 1 小时回升 \(-drop) 个百分点"))
                }
            }.font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
    }

    static func time(_ stamp: Double) -> String {
        Date(timeIntervalSince1970: stamp).formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))
    }
}

/// Details appear on demand; they use the already loaded snapshot and never
/// start another reader, timer or network request.
struct QuotaTrendInfo: View {
    @ObservedObject var model: QuotaTrendModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("额度历史说明")).font(.system(size: 12, weight: .semibold))
            Text(L10n.string("正常约每 5 分钟采样。同周期采样点连续连线，纵轴固定为 0%～100%。"))
            Text(model.snapshot.truncated ? L10n.string("显示最近 20,000 条采样。") : L10n.string("历史仅保存在本机，保留 30 天。"))
            Text(L10n.string("首次记录时间是采样时间，实际变化可能发生在两次采样之间。"))
            Text(L10n.string("虚线标记额度周期或套餐变更"))
            ForEach(model.visibleWindows, id: \.self) { window in
                let series = model.series(for: window)
                let value = window == .primary ? model.row.five : model.row.week
                if series.currentSegment.last?.remaining == value,
                   let drop = series.hourlyDrop(now: model.now) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window == .primary ? model.row.fiveWindowTitle : model.row.weekWindowTitle).fontWeight(.medium)
                        Text(drop >= 0 ? L10n.string("约 1 小时下降 \(drop) 个百分点") : L10n.string("约 1 小时回升 \(-drop) 个百分点"))
                    }
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondary)
        .fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 280)
    }
}

private struct QuotaTrendChart: View {
    let series: QuotaHistorySeries
    let start: Double
    let end: Double
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        let curves = series.displaySegments.map { QuotaTrendCurve.make($0) }
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                VStack { Text("100%"); Spacer(); Text("0%") }
                    .font(.system(size: 9)).foregroundStyle(palette.tertiary).frame(width: 28)
                GeometryReader { geometry in
                    Canvas { context, size in
                        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / (end - start)) * size.width }
                        func y(_ v: Double) -> CGFloat { (1 - CGFloat(v) / 100) * (size.height - 6) + 3 }
                        func position(_ point: QuotaCurvePoint) -> CGPoint { CGPoint(x: x(point.time), y: y(point.value)) }
                        for level in [0, 50, 100] {
                            var rule = Path(); rule.move(to: CGPoint(x: 0, y: y(Double(level)))); rule.addLine(to: CGPoint(x: size.width, y: y(Double(level))))
                            context.stroke(rule, with: .color(palette.rule), style: StrokeStyle(lineWidth: 0.5, dash: level == 50 ? [2, 3] : []))
                        }
                        for t in series.boundaries {
                            var rule = Path(); rule.move(to: CGPoint(x: x(t), y: 0)); rule.addLine(to: CGPoint(x: x(t), y: size.height))
                            context.stroke(rule, with: .color(palette.amber), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        for (segment, curve) in zip(series.displaySegments, curves) {
                            guard let first = segment.first, let last = segment.last else { continue }
                            var line = Path(); line.move(to: CGPoint(x: x(first.time), y: y(Double(first.remaining))))
                            for span in curve {
                                line.addCurve(to: position(span.end), control1: position(span.control1), control2: position(span.control2))
                            }
                            context.stroke(line, with: .color(palette.green), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            let rect = CGRect(x: x(last.time) - 2, y: y(Double(last.remaining)) - 2, width: 4, height: 4)
                            context.fill(Path(ellipseIn: rect), with: .color(palette.green))
                        }
                    }.accessibilityHidden(true)
                    // Pointer state belongs to the overlay, so moving the mouse
                    // doesn't rebuild the paths or query storage.
                    QuotaChartCursor(points: series.points, start: start, end: end, size: geometry.size)
                }
            }.frame(height: 70)
            HStack {
                Text(axisTime(start)); Spacer(); Text(axisTime(end))
            }.font(.system(size: 9)).foregroundStyle(palette.tertiary).padding(.leading, 33)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("额度历史，\(series.points.count) 次采样"))
    }
    private func axisTime(_ value: Double) -> String {
        let date = Date(timeIntervalSince1970: value)
        if end - start > 86400 { return date.formatted(.dateTime.month().day().locale(L10n.locale)) }
        if Calendar.current.isDate(Date(timeIntervalSince1970: start), inSameDayAs: Date(timeIntervalSince1970: end)) {
            return date.formatted(.dateTime.hour().minute().locale(L10n.locale))
        }
        return value == start ? date.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)) :
            date.formatted(.dateTime.hour().minute().locale(L10n.locale))
    }
}

private struct QuotaChartCursor: View {
    let points: [QuotaHistoryPoint]
    let start: Double
    let end: Double
    let size: CGSize
    @State private var selected: QuotaHistoryPoint?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let selected {
                let x = CGFloat((selected.time - start) / (end - start)) * size.width
                let y = (1 - CGFloat(selected.remaining) / 100) * (size.height - 6) + 3
                Rectangle().fill(PanelPalette(scheme: scheme).secondary.opacity(0.4)).frame(width: 1, height: size.height).offset(x: x)
                Circle().fill(PanelPalette(scheme: scheme).green).frame(width: 6, height: 6).offset(x: x - 3, y: y - 3)
                Text("\(QuotaTrendPanel.time(selected.time))  \(selected.remaining)%")
                    .font(.system(size: 10)).padding(4).background(PanelPalette(scheme: scheme).inset, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize().offset(x: min(max(0, x - 80), max(0, size.width - 158)), y: -18)
            }
        }.contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .ended: selected = nil
                case .active(let location):
                    let t = start + Double(location.x / max(1, size.width)) * (end - start)
                    var lo = 0, hi = points.count
                    while lo < hi { let mid = (lo + hi) / 2; if points[mid].time < t { lo = mid + 1 } else { hi = mid } }
                    let candidates = [lo - 1, lo].filter { points.indices.contains($0) }
                    let nearest = candidates.min { abs(points[$0].time - t) < abs(points[$1].time - t) }.map { points[$0] }
                    selected = nearest.flatMap { abs($0.time - t) <= QuotaHistorySeries.maximumGap ? $0 : nil }
                }
            }
    }
}
