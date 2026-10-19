import SwiftUI
import ServiceManagement

struct SettingsPanel: View {
    @ObservedObject var store: SwapStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("登录时启动")
                Spacer()
                Toggle("登录时启动", isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .panelControlHover(cornerRadius: 12)
                    .accessibilityIdentifier("launch-at-login")
            }.padding(.vertical, 11)
            if store.loginApprovalNeeded {
                Button("在系统设置中允许启动") { SMAppService.openSystemSettingsLoginItems() }
                    .font(.system(size: 11))
                    .buttonStyle(PanelButtonStyle(cornerRadius: 4, backgroundPadding: 3))
                    .padding(.bottom, 9)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("状态栏显示 TPS 和额度")
                    Text("上排为输出速度，下排为当前账号剩余额度").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer()
                Toggle("状态栏显示 TPS 和额度", isOn: $store.showMenuBarTPS)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .panelControlHover(cornerRadius: 12)
                    .accessibilityIdentifier("show-menu-bar-tps")
            }.padding(.vertical, 11)
            Divider()
            HStack {
                Text("外观"); Spacer()
                PanelPicker("外观", selection: $store.appearance,
                    options: AppAppearance.allCases.map { PanelPickerOption(value: $0, title: $0.title) })
                    .frame(width: 130, height: PanelLayout.controlHeight)
                    .accessibilityIdentifier("appearance")
            }.padding(.vertical, 11)
            Divider()
            sectionLabel("输出测速")
            HStack {
                Text("本机测速采集"); Spacer()
                Toggle("本机测速采集", isOn: Binding(get: { store.captureEnabled },
                    set: { enabled in Task { await store.setCaptureEnabled(enabled) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .panelControlHover(cornerRadius: 12)
            }.padding(.vertical, 11)
            Divider()
            Text("仅在本机接收 API 计时，保存模型和用量，不保存对话或工具内容。开关变更后重启 Codex 生效；历史记录无法补算。有新记录时更新，空闲时保留上次结果。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if let error = store.captureError {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.amber).padding(.top, 8)
            }
            sectionLabel("账号额度自动刷新")
            ForEach(store.slots) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.planTitle)
                        Text(row.email).font(.system(size: 11)).foregroundStyle(palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 10)
                    Toggle("\(row.planTitle)自动刷新", isOn: Binding(
                        get: { store.autoRefresh.contains(row.name) },
                        set: { _ in store.toggleAutoRefresh(row.name) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .panelControlHover(cornerRadius: 12)
                    .disabled(store.busy).accessibilityIdentifier("auto-refresh-\(row.name)")
                }.padding(.vertical, 11)
                Divider()
            }
            Text("开启的账号每 5 分钟联网刷新额度。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 10)
        }
        .font(.system(size: 13)).foregroundStyle(palette.ink)
        .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 18)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(PanelPalette(scheme: scheme).secondary)
            .padding(.top, 16).padding(.bottom, 3)
    }
}
