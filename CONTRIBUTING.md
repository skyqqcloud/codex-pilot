# 贡献指南

感谢你改进 Codex Pilot。讨论问题可以使用中文或英文；较大的行为调整请先通过 Issue 描述场景与预期结果。

## 本地开发

使用 macOS、Swift 编译器、macOS SDK 和 Python 3.9+。优先运行离线回归，再构建完整 App：

```bash
bash scripts/check.sh
bash scripts/build-dmg.sh
bash scripts/check-scroll-layout.sh  # 涉及原生界面、账号展示、分组或调度时
CODEX_PILOT_TEST_LANGUAGE=en bash scripts/check-scroll-layout.sh  # 英文布局与动态文案
```

这些检查使用合成文件和模拟 HTTP 响应。原生界面检查需要可用的 macOS WindowServer。只有明确需要本机数据审查时，才手动运行 `bash scripts/check.sh --live`，不要把其输出公开上传。

## 修改边界

- TPS 修改必须说明分子、分母、输出边界、失败与重叠请求处理，以及缺失记录如何影响最近五次平均。
- 性能优化需比较同一批输入的数值与计时结果。不要通过跳过记录、估算时间或改变平均窗口来降低耗时。
- 账号操作需保留退出失败时不改登录、凭据文件权限、同账号缓存边界及失败时的恢复行为。
- 界面检查请区分合成离屏验证、真实系统菜单栏验证与真实账号验证。
- 保留 `ThirdParty/` 与派生源文件中的署名和许可证声明。

## Pull Request

说明解决的具体问题、修改后的行为和实际执行的验证。使用小范围提交，避免混入本机配置、构建目录、日志、备份或凭据。截图请使用合成账号和示例消息。未执行的验证应明确标记。

提交贡献表示你同意该贡献按本仓库的 Apache-2.0 许可证发布。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。
