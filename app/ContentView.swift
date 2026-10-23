import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum PanelPage { case main, stats, settings, manage }
private enum PanelConfirmation: Identifiable {
    case switchAccount(SlotRow), deleteAccount(SlotRow), addAccount, returnToPrevious
    var id: String {
        switch self {
        case .switchAccount(let row): return "switch-\(row.name)"
        case .deleteAccount(let row): return "delete-\(row.name)"
        case .addAccount: return "add"
        case .returnToPrevious: return "return"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: SwapStore
    @State private var page: PanelPage = .main
    @State private var confirmation: PanelConfirmation?
    @Environment(\.colorScheme) private var scheme

    private var palette: PanelPalette { PanelPalette(scheme: scheme) }
    private var maximumHeight: CGFloat { min(760, max(430, (NSScreen.main?.visibleFrame.height ?? 900) - 70)) }
    private var accountHeight: CGFloat {
        let notices: CGFloat = (store.needsSave ? 64 : 0) + (store.errorMessage != nil ? 54 : 0) + (store.status.isEmpty ? 0 : 24)
        return max(PanelLayout.accountRowHeight, maximumHeight - 330 - notices)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if page == .main {
                    mainPanel
                } else if page == .stats {
                    ThroughputDetailPanel(store: store)
                        .fixedSize(horizontal: false, vertical: true)
                        .onExitCommand { page = .main }
                } else {
                    BoundedPanelScrollView(maximumHeight: maximumHeight - 50) {
                        VStack(spacing: 0) {
                            if let error = store.errorMessage { message(error, error: true) }
                            if page == .settings { SettingsPanel(store: store) }
                            else { managementPanel }
                        }
                        .onExitCommand { page = .main }
                    }
                }
            }
            .disabled(confirmation != nil)
            if let confirmation { confirmationPanel(confirmation) }
        }
        .frame(width: PanelLayout.width)
        .background(palette.paper)
        .foregroundStyle(palette.ink)
        .onAppear {
            page = .main
            Task { await store.refreshForPanel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refreshForPanel() }
        }
        .onExitCommand {
            if confirmation != nil { confirmation = nil }
            else if page != .main { page = .main }
            else { NSApp.keyWindow?.close() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if page == .main {
                Image(systemName: "terminal").font(.system(size: 13)).foregroundStyle(palette.secondary)
            } else {
                Button { page = .main; store.errorMessage = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12)).frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight)
                }.buttonStyle(PanelButtonStyle(cornerRadius: 6))
                    .accessibilityLabel(L10n.string("返回")).accessibilityIdentifier("panel-back")
            }
            Text(page == .main ? "Codex Pilot" : page == .settings ? L10n.string("设置") : page == .stats ? L10n.string("输出测速") : L10n.string("管理账号"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if page == .main {
                Button { page = .settings } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                        .foregroundStyle(palette.secondary).frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight)
                }.buttonStyle(PanelButtonStyle(cornerRadius: 6))
                    .accessibilityLabel(L10n.string("设置")).help(L10n.string("设置")).accessibilityIdentifier("panel-settings")
            }
        }
        .padding(.horizontal, PanelLayout.contentInset).padding(.top, 10).padding(.bottom, 6)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            if store.pendingSaveAfterAdd != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.string("在 Codex 完成登录后，保存新账号。不要点 Log out。")).font(.system(size: 11))
                    Button(L10n.string("返回原账号")) { confirmation = .returnToPrevious }
                        .font(.system(size: 11))
                        .buttonStyle(PanelButtonStyle(cornerRadius: 4, backgroundPadding: 3)).disabled(store.busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(palette.amber).padding(10)
                .background(palette.inset, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 5)
            } else if let warning = store.warning {
                message(warning, error: false)
            }
            ThroughputPanel(store: store) { page = .stats }
            PanelRule()
            HStack(spacing: 7) {
                Text(L10n.string("账号")).font(.system(size: 12, weight: .medium))
                Text("\(store.slots.count)").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer()
                Button { Task { await store.refreshAllFetched() } } label: {
                    if !store.refreshingNames.isEmpty { ProgressView().controlSize(.mini).frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight) }
                }
                .buttonStyle(PanelButtonStyle(cornerRadius: 6)).foregroundStyle(palette.secondary)
                .disabled(store.busy || store.needsSave || store.slots.isEmpty)
                .help(L10n.string("联网刷新所有账号额度")).accessibilityIdentifier("refresh-quotas")
            }.padding(.horizontal, PanelLayout.contentInset).padding(.top, 7).padding(.bottom, 3)
            if store.slots.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.string("还没有保存的账号")).font(.system(size: 13, weight: .medium))
                    Text(store.hasLiveAuth ? L10n.string("点「保存登录」记录当前账号。") : L10n.string("先在 Codex 中登录，再保存登录。"))
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    if !store.hasLiveAuth {
                        Button(L10n.string("打开 Codex 登录")) { Task { await store.openCodex() } }
                            .buttonStyle(PanelButtonStyle(cornerRadius: 4, backgroundPadding: 3)).font(.system(size: 11))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PanelLayout.contentInset).padding(.vertical, 18)
            } else {
                BoundedPanelScrollView(maximumHeight: accountHeight) {
                    VStack(spacing: 2) {
                        ForEach(store.slots) { row in
                            TimelineView(.everyMinute) { context in
                                AccountPanelRow(row: row, now: context.date, active: row.active && !store.needsSave) {
                                    guard !row.active else { return }
                                    confirmation = .switchAccount(row)
                                }
                            }
                            .disabled(store.busy || store.needsSave)
                            .contextMenu {
                                Button(L10n.string("刷新这个账号额度")) { Task { await store.refreshSlot(row.name) } }
                                    .disabled(store.busy || store.needsSave)
                                Button(store.autoRefresh.contains(row.name) ? L10n.string("关闭自动刷新") : L10n.string("开启自动刷新")) {
                                    store.toggleAutoRefresh(row.name)
                                }.disabled(store.busy)
                            }
                        }
                    }.padding(.horizontal, PanelLayout.rowOuterInset)
                }
            }
            HStack {
                Text(PanelFormat.updated(store.lastFetchedAt))
                Spacer(minLength: 4)
                if enabledAutoCount > 0 {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                    Text(enabledAutoCount == 1 ? L10n.string("\(enabledAutoTitle) 自动刷新") : L10n.string("\(enabledAutoCount) 个自动刷新"))
                }
            }
            .font(.system(size: 10)).foregroundStyle(palette.tertiary)
            .padding(.horizontal, PanelLayout.contentInset).padding(.top, 5).padding(.bottom, 8)
            if let error = store.errorMessage { message(error, error: true) }
            PanelRule()
            VStack(spacing: 0) {
                PanelAction(title: L10n.string("保存登录"), symbol: "bookmark", shortcut: "⌘ S", highlighted: store.needsSave) {
                    Task { await store.saveCurrent() }
                }
                .disabled(store.busy || !store.hasLiveAuth)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("save-login")
                PanelAction(title: L10n.string("添加账号…"), symbol: "plus") { confirmation = .addAccount }
                    .disabled(store.busy || store.needsSave || !store.hasLiveAuth)
                    .accessibilityIdentifier("add-account")
                PanelAction(title: L10n.string("管理账号"), symbol: "person.2", disclosure: true) { page = .manage }
                    .disabled(store.busy).accessibilityIdentifier("manage-accounts")
            }.padding(.horizontal, PanelLayout.rowOuterInset).padding(.vertical, 3)
            if !store.status.isEmpty {
                HStack(spacing: 6) {
                    if store.busy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark").font(.system(size: 10)) }
                    Text(store.status).font(.system(size: 11)).lineLimit(2)
                    Spacer()
                }
                .foregroundStyle(store.busy ? palette.secondary : palette.green)
                .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 8)
            }
            PanelRule()
            PanelAction(title: L10n.string("退出 Codex Pilot"), symbol: "power", shortcut: "⌘ Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityIdentifier("quit-pilot")
            .padding(.horizontal, PanelLayout.rowOuterInset).padding(.vertical, 3)
        }
    }

    private var enabledAutoCount: Int { store.slots.filter { store.autoRefresh.contains($0.name) }.count }
    private var enabledAutoTitle: String { store.slots.first { store.autoRefresh.contains($0.name) }?.planTitle ?? "" }

    private var managementPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.slots) { row in
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.planTitle)
                            if row.name == store.current { Text(L10n.string("当前")).font(.system(size: 11)).foregroundStyle(palette.green) }
                        }
                        Text(row.email).font(.system(size: 11)).foregroundStyle(palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 7)
                    Button { Task { await store.move(row.name, direction: -1) } } label: {
                        Image(systemName: "chevron.up").frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight)
                    }.disabled(store.busy || !store.canMoveUp(row.name)).help(L10n.string("上移"))
                    Button { Task { await store.move(row.name, direction: 1) } } label: {
                        Image(systemName: "chevron.down").frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight)
                    }.disabled(store.busy || !store.canMoveDown(row.name)).help(L10n.string("下移"))
                    Button { confirmation = .deleteAccount(row) } label: {
                        Image(systemName: "trash").frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight).foregroundStyle(palette.red)
                    }.disabled(store.busy || row.name == store.current).help(L10n.string("删除账号"))
                }
                .font(.system(size: 12)).buttonStyle(PanelButtonStyle(cornerRadius: 5)).padding(.vertical, 12)
                .onDrag { NSItemProvider(object: row.name as NSString) }
                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                    guard !store.busy, let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let name = object as? String else { return }
                        Task { @MainActor in await store.move(name, before: row.name) }
                    }
                    return true
                }
                Divider()
            }
            Text(L10n.string("拖动账号或使用箭头调整顺序。当前账号需要先切换后才能删除。"))
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 11)
        }.padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 18)
    }

    private func message(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: error ? "exclamationmark.circle" : "person.crop.circle")
                .font(.system(size: 12))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if error {
                Button { store.errorMessage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).frame(width: 20, height: 20)
                }
                .buttonStyle(PanelButtonStyle(cornerRadius: 5)).accessibilityLabel(L10n.string("关闭提示"))
            }
        }
        .foregroundStyle(palette.amber).padding(9)
        .background(palette.inset, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, PanelLayout.contentInset).padding(.vertical, 5)
    }

    private func confirmationPanel(_ item: PanelConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 15)
            Image(systemName: confirmationSymbol(item)).font(.system(size: 20)).foregroundStyle(palette.secondary)
                .frame(width: 42, height: 42).background(palette.inset, in: RoundedRectangle(cornerRadius: 11))
                .padding(.bottom, 16)
            Text(confirmationTitle(item)).font(.system(size: 17, weight: .medium)).padding(.bottom, 8)
            Text(confirmationMessage(item)).font(.system(size: 12)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                .padding(.bottom, 21)
            HStack(spacing: 8) {
                Spacer()
                Button { confirmation = nil } label: {
                    Text(L10n.string("取消")).padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(PanelButtonStyle(kind: .neutral))
                .keyboardShortcut(.cancelAction)
                Button {
                    confirmation = nil
                    Task {
                        switch item {
                        case .switchAccount(let row): await store.switchTo(row)
                        case .deleteAccount(let row): await store.delete(row)
                        case .addAccount: await store.addNew()
                        case .returnToPrevious: await store.returnToPreviousAccount()
                        }
                    }
                } label: {
                    Text(confirmationAction(item)).foregroundStyle(palette.actionText)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(PanelButtonStyle(kind: .primary))
                .accessibilityIdentifier("confirm-account-action")
            }
            .font(.system(size: 12))
            Spacer(minLength: 15)
        }
        .padding(25).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.paper)
        .accessibilityElement(children: .contain)
    }

    private func confirmationSymbol(_ item: PanelConfirmation) -> String {
        switch item {
        case .deleteAccount: return "trash"
        case .addAccount: return "person.badge.plus"
        default: return "arrow.left.arrow.right"
        }
    }
    private func confirmationTitle(_ item: PanelConfirmation) -> String {
        switch item {
        case .switchAccount(let row): return L10n.string("切换到 \(row.planTitle)？")
        case .deleteAccount(let row): return L10n.string("删除 \(row.planTitle)？")
        case .addAccount: return L10n.string("登录一个新账号")
        case .returnToPrevious: return L10n.string("返回原账号？")
        }
    }
    private func confirmationMessage(_ item: PanelConfirmation) -> String {
        switch item {
        case .switchAccount(let row): return L10n.string("\(row.email)\n\n会退出并重新打开 Codex，正在进行的任务会中断。")
        case .deleteAccount(let row): return L10n.string("\(row.email)\n\n移除保存的登录。下次使用这个账号时，需要重新登录。")
        case .addAccount: return L10n.string("先保存当前登录，再退出 Codex 并打开登录界面。\n\n登录完成后，回到状态栏保存登录。不要点 Log out。")
        case .returnToPrevious: return L10n.string("会退出 Codex 并恢复之前的账号。已完成的新登录会先保存。")
        }
    }
    private func confirmationAction(_ item: PanelConfirmation) -> String {
        switch item {
        case .switchAccount: return L10n.string("退出并切换")
        case .deleteAccount: return L10n.string("删除账号")
        case .addAccount: return L10n.string("打开登录")
        case .returnToPrevious: return L10n.string("返回原账号")
        }
    }
}
