//
//  ChargeController.swift
//  PowerCumul
//
//  充电控制（仅笔记本）：经 sudoers 免密调用特权辅助工具 powercumul-smc 读写 SMC，
//  实现 AlDente 免费版同款的「充电上限」。机制参考开源实现 batt。
//
//  两种底层模式（helper status 探测，按 SMC 键存在性判断）：
//  - firmware（较新固件，bfD0/bfE0/bfF0）：限充与滞回由固件自己执行，写一次即持续，
//    app 只在启动/修改时幂等补写，退出、睡眠都无需干预。
//  - legacy（CH0B+CH0C / 老固件 CHTE）：SMC 只能开/关充电，滞回逻辑
//    （充到上限停、回落到上限-2 再充）由本类的 30s 维护循环执行；
//    睡眠前停充防过充（睡眠中循环不走），app 退出时放开充电防止电池充不进。
//
//  安全护栏：上限最低 20；「关闭」= 恢复默认（充满）；授权检查失败一律拒绝写入。
//

import Foundation
import AppKit

enum ChargeControlMode {
    case firmware
    case legacy
    case unsupported
}

final class ChargeController {

    /// 辅助工具固定安装路径（sudoers 白名单按此路径匹配）。
    static let helperPath = "/Library/PrivilegedHelperTools/powercumul-smc"
    /// legacy 滞回跨度：回落到「上限-2」才重新开充（与 batt 默认一致）。
    static let hysteresis = 2
    /// legacy 维护循环周期（秒）。
    static let maintainInterval: TimeInterval = 30

    private let prefs: Preferences
    private(set) var mode: ChargeControlMode = .unsupported
    private var maintainTimer: Timer?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    // MARK: - 状态

    /// 当前设备是否具备充电控制能力（有电池 + SMC 键可用）。
    var isCapable: Bool { mode != .unsupported }
    /// 限充是否生效中（存储偏好 < 100）。
    var isActive: Bool { prefs.chargeLimitPercent < 100 }
    /// 当前上限值（面板展示用）。
    var limitPercent: Int { prefs.chargeLimitPercent }

    // MARK: - 生命周期

    /// 探测能力并按存储偏好补写限充（幂等）。app 启动与授权成功后调用。
    /// 可在后台线程调用（内部跑 helper 子进程）。
    func refreshAndApply() {
        guard PrivilegeManager.chargeStatus() == .granted, BatteryMonitor.hasBattery() else {
            mode = .unsupported
            stopMaintain()
            return
        }
        guard let (ok, out) = runHelper(["status"]), ok else {
            mode = .unsupported
            return
        }
        let st = parseStatus(out)
        mode = st.mode
        guard isCapable else { return }
        if isActive {
            applyActiveLimit()
        } else {
            stopMaintain()
        }
    }

    /// 设置充电上限（20...99）。返回 nil = 成功，否则为用户可读的错误文案。
    func setLimit(_ percent: Int) -> String? {
        let pct = min(99, max(20, percent))
        guard PrivilegeManager.chargeStatus() == .granted else {
            return L10n.tr("charge.notGranted", "充电控制未授权，请先在右键菜单授权")
        }
        guard isCapable, BatteryMonitor.hasBattery() else {
            return L10n.tr("charge.unsupported", "此设备不支持充电控制")
        }
        prefs.chargeLimitPercent = pct
        applyActiveLimit()
        // 固件模式写入后回读校验，确保固件真的接受了（写入顺序/键值不对时能立刻发现）。
        if mode == .firmware, let (_, out) = runHelper(["status"]),
           let f = parseFirmwareStatus(out), !f.active || f.upper != pct {
            return L10n.tr("charge.setFailed", "设置失败：固件未接受限充值（读到 upper=%d, active=%d）",
                           f.upper, f.active ? 1 : 0)
        }
        return nil
    }

    /// 关闭限充（恢复默认充满）。
    func clearLimit() {
        prefs.chargeLimitPercent = 100
        stopMaintain()
        guard isCapable, PrivilegeManager.chargeStatus() == .granted else { return }
        _ = runHelper(["clear"])
    }

    /// app 退出前的安全收尾：legacy 模式下放开充电——app 不在时没人维持滞回，
    /// 若停充状态退出，插着电电池也充不进，会一直放到没电。
    func prepareForTermination() {
        stopMaintain()
        guard mode == .legacy, isActive,
              PrivilegeManager.chargeStatus() == .granted else { return }
        _ = runHelper(["charging", "on"])
    }

    // MARK: - 内部

    /// 按 stored 偏好落一次限充（固件幂等补写 / legacy 立即维护 + 起循环）。
    private func applyActiveLimit() {
        guard isActive, isCapable else { return }
        switch mode {
        case .firmware:
            _ = runHelper(["limit", "\(prefs.chargeLimitPercent)"])
            stopMaintain()
        case .legacy:
            maintain()
            startMaintain()
        case .unsupported:
            break
        }
    }

    /// legacy 滞回一拍：电量≥上限且在充 → 停充；电量≤上限-2 且停充中 → 开充。
    private func maintain() {
        let info = BatteryMonitor.current()
        guard info.hasBattery, let level = info.levelPercent else { return }
        let upper = prefs.chargeLimitPercent
        let lower = upper - ChargeController.hysteresis
        guard let (ok, out) = runHelper(["status"]), ok,
              let charging = parseStatus(out).charging else { return }
        if level >= upper, charging == 1 {
            _ = runHelper(["charging", "off"])
        } else if level <= lower, charging == 0 {
            _ = runHelper(["charging", "on"])
        }
    }

    private func startMaintain() {
        guard maintainTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: ChargeController.maintainInterval,
                                     repeats: true) { [weak self] _ in
            self?.maintain()
        }
        t.tolerance = 5
        maintainTimer = t
        // 睡眠中定时器不走，贴着上限睡会过充——睡前置停充（与 batt 一致）；
        // 唤醒后立即维护一拍，恢复充/停状态。
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.mode == .legacy, self.isActive,
                  PrivilegeManager.chargeStatus() == .granted else { return }
            _ = self.runHelper(["charging", "off"])
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.mode == .legacy, self.isActive else { return }
            self.maintain()
        }
    }

    private func stopMaintain() {
        maintainTimer?.invalidate()
        maintainTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        if let o = sleepObserver { center.removeObserver(o); sleepObserver = nil }
        if let o = wakeObserver { center.removeObserver(o); wakeObserver = nil }
    }

    // MARK: - helper 调用与解析

    /// 跑一次辅助工具。app 本身非 root，经 `sudo -n` 走免密规则。
    private func runHelper(_ args: [String]) -> (ok: Bool, out: String)? {
        let p = Process()
        p.launchPath = "/usr/bin/sudo"
        p.arguments = ["-n", ChargeController.helperPath] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out)
    }

    /// 解析 status 输出：mode=... charging=... [active=... upper=... lower=...]
    private func parseStatus(_ out: String) -> (mode: ChargeControlMode, charging: Int?) {
        var mode = ChargeControlMode.unsupported
        var charging: Int?
        for line in out.split(separator: "\n") {
            for pair in line.split(separator: " ") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "mode":
                    mode = kv[1] == "firmware" ? .firmware : (kv[1] == "legacy" ? .legacy : .unsupported)
                case "charging":
                    charging = Int(kv[1])
                default:
                    break
                }
            }
        }
        return (mode, charging)
    }

    /// 解析固件限充状态字段（active/upper/lower）。
    private func parseFirmwareStatus(_ out: String) -> (active: Bool, upper: Int)? {
        var active = false
        var upper = -1
        for pair in out.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "active": active = kv[1] == "1"
            case "upper": upper = Int(kv[1]) ?? -1
            default: break
            }
        }
        return upper >= 0 ? (active, upper) : nil
    }
}
