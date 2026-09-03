//
//  ProcessAlertManager.swift
//  PowerCumul
//
//  进程级持续高耗电告警：
//  整机功率超过用户阈值 且 某个进程持续占据能耗分半数以上达 5 分钟 → 通知一次。
//  - 只在"系统确实在费电"时才有意义（以功率阈值做闸门），避免空闲噪声误报
//  - 同进程 30 分钟冷却；主进程切换会重置计时
//  - 归因功率 = 能耗分占比 × 当前整机功率（与面板 TOP 列表同口径）
//

import Foundation

final class ProcessAlertManager {

    private let prefs: Preferences
    /// 当前连续领先的进程名（nil = 无候选）。
    private var leader: String?
    private var leaderSince = Date.distantPast
    private var lastNotified: [String: Date] = [:]

    /// 持续时长门槛：连续 5 分钟。
    private static let sustainInterval: TimeInterval = 5 * 60
    /// 占比门槛：能耗分占全部进程的 50%。
    private static let leaderShare: Double = 0.5
    /// 同进程通知冷却：30 分钟。
    private static let notifyCooldown: TimeInterval = 30 * 60

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    /// 每个采样块调用一次（内部串行回调队列，非主线程）。
    func evaluate(rows: [ProcessEnergyRow], systemW: Double) {
        guard prefs.processAlertEnabled, !rows.isEmpty else {
            leader = nil
            return
        }
        let total = rows.reduce(0) { $0 + $1.score }
        guard total > 0, let top = rows.max(by: { $0.score < $1.score }) else {
            leader = nil
            return
        }
        let share = top.score / total
        let now = Date()

        let systemBusy = systemW >= prefs.alertPowerThresholdW
        if systemBusy && share >= Self.leaderShare {
            if top.name == leader {
                let sustained = now.timeIntervalSince(leaderSince) >= Self.sustainInterval
                let cooled = now.timeIntervalSince(lastNotified[top.name] ?? .distantPast) >= Self.notifyCooldown
                if sustained && cooled {
                    lastNotified[top.name] = now
                    AlertManager.notifyProcessHighConsumption(
                        name: top.name,
                        attributedW: share * systemW,
                        minutes: Int(Self.sustainInterval / 60))
                }
            } else {
                leader = top.name
                leaderSince = now
            }
        } else {
            // 系统不忙或无主导进程：清空候选，下次重新计时。
            leader = nil
        }
    }
}
