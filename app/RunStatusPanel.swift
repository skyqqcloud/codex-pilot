import SwiftUI

struct RunStatusPanel: View {
    @ObservedObject var store: SwapStore
    @Environment(\.colorScheme) private var scheme
    @State private var confirmRestart = false
    private var palette: PanelPalette { PanelPalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow(L10n.string("Codex 登录"), value: store.hasLiveAuth ? L10n.string("已登录") : L10n.string("尚未登录"),
                      detail: store.hasLiveAuth ? store.liveEmail : L10n.string("先打开 Codex 并登录，再保存当前账号。"), okay: store.hasLiveAuth)
            if !store.hasLiveAuth {
                Button(L10n.string("打开 Codex")) { Task { await store.openCodex() } }.buttonStyle(.bordered)
                    .padding(.bottom, 12)
            } else if store.currentRow == nil || store.needsSave {
                Button(L10n.string("保存登录")) { Task { await store.saveCurrent() } }
                    .buttonStyle(.bordered).disabled(store.busy).padding(.bottom, 12)
            }
            Divider()
            statusRow(L10n.string("测速配置"), value: store.captureEnabled ? L10n.string("已开启") : L10n.string("未开启"),
                      detail: L10n.string("配置变更后需要重新打开 Codex，已有的历史调用无法补算。"), okay: store.captureEnabled)
            if !store.captureEnabled {
                Button(L10n.string("开启本机测速")) { Task { await store.setCaptureEnabled(true) } }
                    .buttonStyle(.bordered).disabled(store.busy).padding(.bottom, 12)
            }
            Divider()
            statusRow(L10n.string("采集进程"), value: store.captureProcessRunning ? L10n.string("进程运行中") : L10n.string("未确认运行"),
                      detail: store.captureError ?? L10n.string("进程运行仅表示接收器已启动，收到调用记录后才能验证配置生效。"),
                      okay: store.captureProcessRunning && store.captureError == nil)
            Divider()
            statusRow(L10n.string("采集记录"), value: store.captureNeedsVerification ? L10n.string("等待新调用验证") : store.lastCapturedAt == nil ? L10n.string("暂无记录") : L10n.string("已有采集记录"),
                      detail: store.lastCapturedAt.map(dateText) ?? L10n.string("重启 Codex 后完成一次新的 API 调用，即可验证采集。"),
                      okay: store.lastCapturedAt != nil && !store.captureNeedsVerification)
            if store.captureEnabled && store.captureNeedsVerification {
                Button(L10n.string("重新打开 Codex…")) { confirmRestart = true }
                    .buttonStyle(.bordered).disabled(store.busy).padding(.bottom, 12)
            }
            Divider()
            statusRow(L10n.string("账号额度"), value: store.quotaError != nil ? L10n.string("刷新未完成") : store.lastFetchedAt == nil ? L10n.string("尚未刷新") : L10n.string("已有额度记录"),
                      detail: store.quotaError ?? store.lastFetchedAt.map(dateText) ?? L10n.string("保存账号后可手动刷新，或在设置中开启自动刷新。"),
                      okay: store.lastFetchedAt != nil && store.quotaError == nil)
            Button(L10n.string("刷新账号额度")) { Task { await store.refreshAllFetched() } }
                .buttonStyle(.bordered).disabled(store.busy || store.needsSave || store.slots.isEmpty)
                .padding(.bottom, 12)
            Divider()
            Button {
                Task { await store.refreshLocalState(); await store.refreshThroughput() }
            } label: {
                Label(L10n.string("重新检查状态"), systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered).disabled(store.busy).padding(.top, 14)
            if !store.status.isEmpty {
                Text(store.status).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 10)
            }
        }.font(.system(size: 12)).foregroundStyle(palette.ink)
            .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 18)
            .alert(L10n.string("重新打开 Codex？"), isPresented: $confirmRestart) {
                Button(L10n.string("取消"), role: .cancel) {}
                Button(L10n.string("重新打开")) { Task { await store.restartCodexForCapture() } }
            } message: {
                Text(L10n.string("请先结束当前工作。此操作会正常退出并重新打开 Codex，不切换账号。"))
            }
            .accessibilityIdentifier("run-status")
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale))
    }
    private func statusRow(_ title: String, value: String, detail: String, okay: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: okay ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(okay ? palette.green : palette.amber).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(value).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 13)
    }
}
