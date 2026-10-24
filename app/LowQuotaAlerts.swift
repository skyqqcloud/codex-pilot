import Foundation
import UserNotifications

enum LowQuotaAlerts {
    static func cycles(_ row: SlotRow) -> [String: String] {
        guard row.active else { return [:] }
        var result: [String: String] = [:]
        for (index, window) in [(row.five, row.fiveResetAt), (row.week, row.weekResetAt)].enumerated() {
            guard let value = window.0, (0...10).contains(value) else { continue }
            result[String(index)] = window.1.map { String($0) } ?? "unknown"
        }
        return result
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
    }

    static func deliverIfNeeded(_ row: SlotRow, defaults: UserDefaults) async {
        let current = cycles(row)
        var sent = defaults.dictionary(forKey: "LowQuotaSent3-" + row.name) as? [String: String] ?? [:]
        guard current.contains(where: { sent[$0.key] != $0.value }) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.string("当前账号额度较低")
        content.body = L10n.string("\(row.planTitle) 剩余额度 \(MenuBarQuota(account: row).text)，可在菜单栏查看或切换账号。")
        let request = UNNotificationRequest(identifier: "pilot-low-quota-" + row.name, content: content, trigger: nil)
        do {
            try await center.add(request)
            sent.merge(current) { _, new in new }
            defaults.set(sent, forKey: "LowQuotaSent3-" + row.name)
        } catch { /* A notification failure must not affect quota refresh. */ }
    }
}
