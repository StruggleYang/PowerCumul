//
//  AlertManager.swift
//  PowerCumul
//
//  功率超阈值 / 日费用超预算告警。
//  - 用 UNUserNotificationCenter 发系统通知
//  - 防抖：同一告警在"条件持续满足"时不重复弹；恢复后状态归位，下次再次触发才通知
//

import Foundation
import UserNotifications

final class AlertManager {

    private let prefs: Preferences
    private let store: EnergyStore

    /// 功率告警防抖：当前是否处于"已告警"状态（避免持续超标时反复弹）。
    private var powerAlertActive = false
    /// 费用告警防抖：同上。
    private var budgetAlertActive = false

    init(prefs: Preferences, store: EnergyStore) {
        self.prefs = prefs
        self.store = store
    }

    /// 请求通知授权（首次调用弹系统授权框）。静默失败不影响其他功能。
    func requestAuthorizationIfNeeded() {
        AlertManager.requestAuthorizationShared()
    }

    /// 类方法版：面板开启告警时可直接调用，无需持有 AlertManager 实例。
    static func requestAuthorizationShared() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// 进程持续高耗电通知（ProcessAlertManager 触发）。
    static func notifyProcessHighConsumption(name: String, attributedW: Double, minutes: Int) {
        let body = String(format: NSLocalizedString(
            "alert.process.body", value: "%@ 已持续 %d 分钟高耗电，归因功率约 %.1f W", comment: ""),
                          name, minutes, attributedW)
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("alert.process.title", value: "进程持续高耗电", comment: "")
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// 每次采样后调用，按当前功率 + 今日累计费用判断是否告警。
    /// - Parameters:
    ///   - watt: 当前瞬时功率（W）
    ///   - sample: 本次采样（用于明细文案）
    func evaluate(currentW watt: Double, sample: PowerSample?) {
        evaluatePower(watt: watt, sample: sample)
        evaluateBudget()
    }

    // MARK: - 功率告警

    private func evaluatePower(watt: Double, sample: PowerSample?) {
        guard prefs.alertPowerEnabled else {
            powerAlertActive = false
            return
        }
        let threshold = prefs.alertPowerThresholdW
        if watt > threshold {
            // 仅在"从正常→超标"的上升沿触发一次。
            if !powerAlertActive {
                powerAlertActive = true
                let body = String(format: NSLocalizedString(
                    "alert.power.body", value: "当前功率 %.0f W，超过阈值 %.0f W", comment: ""),
                                  watt, threshold)
                post(title: NSLocalizedString("alert.power.title", value: "功率过高", comment: ""),
                     body: body)
            }
        } else if watt < threshold * 0.9 {
            // 跌回阈值 90% 以下才解除，避免在阈值附近抖动反复触发。
            powerAlertActive = false
        }
    }

    // MARK: - 预算告警

    private func evaluateBudget() {
        guard prefs.alertBudgetEnabled else {
            budgetAlertActive = false
            return
        }
        let todayKWh = store.currentSnapshot().todayWh / 1000
        let todayCost = todayKWh * prefs.pricePerKWh
        let threshold = prefs.alertBudgetThreshold

        if todayCost > threshold {
            if !budgetAlertActive {
                budgetAlertActive = true
                let body = String(format: NSLocalizedString(
                    "alert.budget.body", value: "今日电费已 %@ %.2f，超过预算 %.2f", comment: ""),
                                  prefs.currency.symbol, todayCost, threshold)
                post(title: NSLocalizedString("alert.budget.title", value: "超出日预算", comment: ""),
                     body: body)
            }
        } else if todayCost < threshold * 0.95 {
            // 低于预算 95% 才解除，避免抖动。
            budgetAlertActive = false
        }
    }

    // MARK: - 通知投递

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 用日期触发，1 秒后投递（即时感，又确保在主线程外安全）。
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
