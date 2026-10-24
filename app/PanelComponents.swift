import SwiftUI
import AppKit

enum PanelLayout {
    static let width: CGFloat = 380
    static let contentInset: CGFloat = 18
    static let rowOuterInset: CGFloat = 8
    static let rowContentInset = contentInset - rowOuterInset
    static let trailingIndicatorWidth: CGFloat = 10
    static let controlHeight: CGFloat = 24
    static let accountRowHeight: CGFloat = 78
    static let actionRowHeight: CGFloat = 30
    static let windowControlWidth: CGFloat = 112
    static let metricSpacing: CGFloat = 17
    static let modelControlWidth = (width - contentInset * 2 - metricSpacing) / 2
    static let requestRowHeight: CGFloat = 48
    static let requestHistoryHeight = requestRowHeight * 4.5
}

struct PanelPalette {
    let scheme: ColorScheme
    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let rgb = scheme == .dark ? dark : light
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
    var paper: Color { color(0xfbfbfa, 0x272729) }
    var ink: Color { color(0x262628, 0xf2f2f0) }
    var secondary: Color { color(0x68686c, 0xb3b3b6) }
    var tertiary: Color { color(0x72746f, 0x96999e) }
    var rule: Color { color(0xe2e2df, 0x414144) }
    var inset: Color { color(0xf0f0ee, 0x333335) }
    var controlHover: Color { color(0xe5e6e2, 0x444448) }
    var pressed: Color { color(0xd8dad5, 0x505055) }
    var controlOutline: Color { color(0xb6b9b2, 0x85858c) }
    var primaryHover: Color { color(0x454547, 0xdcdcd9) }
    var primaryPressed: Color { color(0x171719, 0xc5c5c2) }
    var track: Color { color(0xe3e5e1, 0x454846) }
    var green: Color { color(0x35745d, 0x7eb799) }
    var selectionGreen: Color { color(0x35745d, 0x438564) }
    var amber: Color { color(0x955c1c, 0xe5b26e) }
    var red: Color { color(0xbe5148, 0xed9a91) }
    var action: Color { color(0x2d2d2f, 0xededea) }
    var actionText: Color { color(0xffffff, 0x252527) }
}

struct PanelRule: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(PanelPalette(scheme: scheme).rule).frame(height: 1).padding(.horizontal, PanelLayout.contentInset)
    }
}

struct PanelAction: View {
    let title: String
    var symbol: String?
    var shortcut: String?
    var disclosure = false
    var highlighted = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(palette.secondary).frame(width: 15)
                }
                Text(title).font(.system(size: 12, weight: highlighted ? .medium : .regular))
                Spacer(minLength: 4)
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(palette.secondary) }
                if disclosure { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(palette.secondary) }
            }
            .foregroundStyle(palette.ink)
            .padding(.horizontal, PanelLayout.rowContentInset)
            .frame(height: PanelLayout.actionRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle(highlighted: highlighted))
        .accessibilityLabel(title)
    }
}

enum PanelFormat {
    static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.automatic))
    }

    static func model(_ value: String) -> String {
        let fast = value.hasSuffix("::fast")
        let name = fast ? String(value.dropLast(6)) : value
        return (name == "unknown" ? L10n.string("未记录模型") : name) + (fast ? " · Fast" : "")
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    static func requestTime(_ timestamp: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "HH:mm:ss" }
        else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = L10n.string("M月d日 HH:mm:ss")
        } else { formatter.dateFormat = L10n.string("yyyy年M月d日 HH:mm:ss") }
        return formatter.string(from: date)
    }

    static func reset(_ timestamp: Double?, fallback: String, known: Bool, now: Date) -> String {
        guard known else { return "" }
        guard let timestamp else { return fallback.isEmpty ? L10n.string("重置时间未记录") : fallback }
        let seconds = Int(timestamp - now.timeIntervalSince1970)
        if seconds <= 0 { return L10n.string("待刷新") }
        let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return L10n.string("\(days)天\(hours)小时后重置") }
        if hours > 0 { return L10n.string("\(hours)小时\(minutes)分后重置") }
        return L10n.string("\(max(1, minutes))分钟后重置")
    }

    static func updated(_ date: Date?) -> String {
        guard let date else { return L10n.string("额度尚未刷新") }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return L10n.string("最近刷新 \(formatter.string(from: date))")
    }
}

struct AccountPanelRow: View {
    let row: SlotRow
    let now: Date
    let active: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        Button(action: action) {
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Text(row.planTitle).font(.system(size: 13, weight: .semibold))
                    if active {
                        ZStack {
                            Circle().fill(palette.selectionGreen)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 14, height: 14)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.string("当前账号"))
                    }
                    Spacer(minLength: 4)
                    Text(row.email).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                        .foregroundStyle(palette.secondary)
                        .frame(width: PanelLayout.trailingIndicatorWidth)
                        .opacity(active ? 0 : 1)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 17) {
                    QuotaPanelMeter(title: row.fiveWindowTitle, value: row.five, resetAt: row.fiveResetAt,
                                    fallback: row.fiveWhen, now: now)
                    if !row.hasSingleFreeWindow {
                        QuotaPanelMeter(title: row.weekWindowTitle, value: row.week, resetAt: row.weekResetAt,
                                        fallback: row.weekWhen, now: now)
                    }
                }
            }
            .foregroundStyle(palette.ink)
            .padding(.horizontal, PanelLayout.rowContentInset).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle(cornerRadius: 9))
        .accessibilityAddTraits(active ? .isSelected : [])
        .help("\(row.planTitle)  \(row.email)\n\(PanelFormat.updated(row.fetchedAt.map(Date.init(timeIntervalSince1970:))))")
        .accessibilityIdentifier("account-\(row.name)")
    }
}

struct QuotaPanelMeter: View {
    let title: String
    let value: Int?
    let resetAt: Double?
    let fallback: String
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        let percent = max(0, min(100, value ?? 0))
        let stale = resetAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        let tint = stale ? palette.secondary.opacity(0.45) :
            percent <= 10 ? palette.red : percent <= 30 ? palette.amber : palette.green
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer(minLength: 3)
                Text(value == nil ? "—" : "\(percent)%").font(.system(size: 12, weight: .medium))
                    .monospacedDigit().foregroundStyle(palette.ink)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    if value != nil {
                        Capsule().fill(tint).frame(width: geometry.size.width * CGFloat(percent) / 100)
                    }
                }
            }
            .frame(height: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("\(title)剩余额度"))
            .accessibilityValue(value == nil ? L10n.string("暂无数据") : "\(percent)%")
            Text(PanelFormat.reset(resetAt, fallback: fallback, known: value != nil, now: now))
                .font(.system(size: 10)).foregroundStyle(palette.tertiary).lineLimit(1)
                .frame(height: 12, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
