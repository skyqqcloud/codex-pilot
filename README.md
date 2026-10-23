# Codex Pilot

[English](README.en.md) · [下载最新版本](https://github.com/skyqqcloud/codex-pilot/releases/latest) · [统计口径](docs/throughput.md)

一个原生 macOS 菜单栏工具，帮助你查看 Codex 的 API 输出速度、管理多个账号并关注剩余额度。

使用 SwiftUI / AppKit 构建，没有独立主窗口或 Dock 图标。**这是社区项目，与 OpenAI 无隶属关系。** 当前版本为 **2.8.4**。

## 能做什么

- **双行菜单栏**：上排显示所选模型最近一次 TPS，下排显示当前激活账号的剩余额度。多个周期取已知值中较低的一个；缺少数据时显示 `—`，不会把未知值当成 0%。
- **查看请求详情**：同时展示最近一次和最近 5 次平均速度；每个模型保留最近 100 条已采集记录，按发起消息分组，后续调用默认折叠。可查看本次用量、耗时、Fast 标记和关联的本地输出。
- **管理多个登录**：保存登录、添加账号、调整顺序和切换账号。切换前先请求 Codex 正常退出，成功后才替换登录并重新打开。
- **查看套餐与额度**：随刷新同步服务端套餐标识和真实额度周期，包括 Free 的单周期额度。支持按账号开启自动刷新。
- **减少后台重复工作**：文件变化触发更新、合并刷新、增量读取历史并复用子进程；后台与交互任务使用不同 QoS，不绑定特定 CPU 核心。

<table>
  <tr><th>账号与输出速度</th><th>请求分组与详情</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/main-light.png" width="340" alt="Codex Pilot 主面板，使用虚构账号展示额度和 TPS"></td>
    <td valign="top"><img src="docs/images/request-detail-light.png" width="340" alt="Codex Pilot 请求详情，使用合成测速样本展示分组和用量"></td>
  </tr>
</table>

截图来自原生离屏测试，账号、消息与测速样本均为演示数据，不是实际性能承诺。

## 安装与首次使用

### 系统要求

- Apple Silicon Mac、macOS 14 或更高版本。
- 已安装并登录 Codex 桌面客户端。
- 可执行的 Python 3.9+。应用优先查找 Homebrew / Command Line Tools 等常见安装位置；运行时仅使用 Python 标准库。

从 [Releases](https://github.com/skyqqcloud/codex-pilot/releases/latest) 下载 `Codex-Pilot-macOS-arm64.dmg`，把 **Codex Pilot** 拖入“应用程序”后打开。目前提供本地 ad-hoc 签名包，尚未做 Apple Developer ID 签名和公证；首次打开可能需要在系统“隐私与安全性”中允许打开。

1. 点击菜单栏入口，选择“保存登录”，记录当前 Codex 账号。
2. 如需添加另一个账号，选择“添加账号”，按界面提示完成 Codex 登录后再保存。
3. 在设置中启用“状态栏显示 TPS 和额度”，即可使用双行显示；关闭后显示双向箭头图标。
4. 如需测速，启用“本机测速采集”并**重启 Codex**，然后等待新的 API 调用完成。历史记录缺少完整计时，不能补算。

切换账号会关闭并重新打开 Codex，请先结束需要保留的工作。该应用按 bundle ID `com.openai.codex` 识别客户端，因此安装目录仍叫 `ChatGPT.app` 时也能识别。

## TPS 是怎么算的

```text
单次 TPS =（API 总输出 token − 推理 token）÷ 对应非推理输出阶段耗时
```

计时使用 Codex 官方 OpenTelemetry 事件与本地明确类型的输出日志。指标排除首个输出前的等待、两次 API 调用之间的空闲和本地工具执行；输出阶段内的后续推理、缓冲和客户端延迟仍可能计入。

这表示**客户端观测到的非推理输出阶段速率**，不等于模型内部 GPU 的纯生成速度。分子仍可能包含工具参数和 API 格式 token，不等于可见字符数。短输出集中到达时比值可能很高，不设人为上限；缺少可靠计时则显示 `—`。

最近 5 次平均先取筛选模型下最近 5 条已采集完成记录，再对其中可测速记录取算术平均；缺失值不当作 0，也不用第 6 条补位。完整定义、失败及重叠请求的处理见 [统计口径与数据边界](docs/throughput.md)。

## 数据与兼容性

- 账号凭据和额度缓存位于 `~/.codex-swap/`；当前 Codex 登录文件位于 `$CODEX_HOME/auth.json`，默认 home 为 `~/.codex`。保存的登录文件保留完整凭据，并以文件权限保护，**不是钥匙串加密存储**。
- 测速接收器仅监听 `127.0.0.1:45417`，使用随机令牌校验。启用时备份 Codex 配置，再添加带标记的 `[otel]` 配置；已有自定义遥测配置时拒绝覆盖。
- 不代理模型 API，不发起额外测速调用，不上传对话给项目维护者。额度刷新和登录续期会联系相应的 OpenAI 接口。
- 本地遥测缓存保留模型、用量、计时、模式、会话标识及有限消息摘要。完整消息与工具内容在需要展示时读取本地 Codex 记录。不要公开上传这些缓存或原始日志。
- 额度接口、套餐字段和本地日志格式依赖上游客户端，可能随版本变化。无法确认的数据保留为未知，不根据额度或速度猜测套餐与 Fast 状态。

数据问题与漏洞报告方式见 [安全说明](SECURITY.md)。

## 从源码构建

需要 macOS、Swift 编译器和 macOS SDK，可使用 Xcode 或 Command Line Tools；不需要额外 Python 包。

```bash
git clone https://github.com/skyqqcloud/codex-pilot.git
cd codex-pilot
bash scripts/check.sh
bash scripts/build-dmg.sh
```

产物为 `dist/Codex Pilot.app` 和 `dist/Codex Pilot.dmg`。构建脚本支持用 `CODEX_PILOT_SDK` 指定 SDK 路径；没有指定时，优先使用本机已有的 macOS 26 SDK，否则使用 `xcrun --show-sdk-path`。若 Command Line Tools 缺少对应 SDK 的 SwiftUI 宏插件，请选择完整 Xcode 工具链或兼容的 SDK。

```bash
bash scripts/check-scroll-layout.sh  # 原生离屏界面、分组、账号切换与 QoS 检查
bash scripts/check.sh --live         # 额外只读检查本机记录；不要在 CI 中使用
```

`Package.swift` 仅定义遥测模块和 XCTest，不是完整 App 的构建入口。完整 App 请使用上面的打包脚本。测试与截图使用合成数据，默认检查不会调用真实模型或修改实际登录。

## 代码导览

| 目录 | 职责 |
| --- | --- |
| `app/` | SwiftUI / AppKit 界面、状态管理、菜单栏和子进程调度 |
| `app/Telemetry/` | 日志解析、样本校验和 TPS 统计 |
| `backend/` | Python 账号管理、本机遥测接收、请求与历史关联 |
| `tests/` | 合成数据回归、计时验证和原生界面检查 |
| `docs/` | 统计定义、历史审计报告和演示截图 |
| `ThirdParty/` | 上游许可证与修改声明 |

历史审计报告：[TPS 准确性](docs/tps-accuracy-audit-20261011.md)、[常驻能耗](docs/energy-audit-20261016.md)、[历史读取优化](docs/energy-audit-20261018.md)、[套餐映射](docs/plan-names-20261019.md)。这些报告记录指定版本与环境的结果，不承诺长期节电比例，也不把离屏检查当成系统菜单栏的现场验收。原始个人数据与本机回退备份不随仓库发布。

欢迎提交 Issue 或 Pull Request。开发与回归要求见 [贡献指南](CONTRIBUTING.md)。

## 许可证与致谢

项目采用 [Apache License 2.0](LICENSE)。部分遥测解析代码源自 [OPL Fleet Agent](https://github.com/gaofeng21cn/opl-fleet-agent)，已保留源文件署名、[上游许可证](ThirdParty/OPLFleetAgent/LICENSE) 和 [修改声明](ThirdParty/OPLFleetAgent/NOTICE)。详见 [NOTICE](NOTICE)。
