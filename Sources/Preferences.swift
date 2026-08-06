//
//  Preferences.swift
//  PowerCumul
//
//  用户偏好（采样间隔、电价、货币、显示模式），用 UserDefaults 持久化。
//  货币用 ISO 代码存储（cny/usd...），符号在运行时按代码解析，保证存储稳定。
//

import Foundation

final class Preferences {

    private enum Key {
        static let interval = "sampleIntervalSec"
        static let price = "pricePerKWh"
        static let currency = "currencyCode"
        static let statusItemMode = "statusItemMode"
        static let appLanguage = "appLanguage"
        static let alertPowerOn = "alertPowerEnabled"
        static let alertPowerThreshold = "alertPowerThresholdW"
        static let alertBudgetOn = "alertBudgetEnabled"
        static let alertBudgetThreshold = "alertBudgetThreshold"
        static let chartRange = "chartRange"
        static let correctionFactor = "powerCorrectionFactor"
    }

    private let defaults = UserDefaults.standard

    /// 采样间隔（秒），默认 5。
    var sampleIntervalSec: Int {
        get {
            let v = defaults.integer(forKey: Key.interval)
            return v > 0 ? v : 5
        }
        set {
            let clamped = max(1, min(60, newValue))
            defaults.set(clamped, forKey: Key.interval)
            defaults.synchronize()
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }

    /// 每千瓦时电价（纯数值，不含货币），默认 0.6。
    var pricePerKWh: Double {
        get {
            let v = defaults.double(forKey: Key.price)
            return v > 0 ? v : 0.6
        }
        set {
            defaults.set(max(0, newValue), forKey: Key.price)
            defaults.synchronize()
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }

    /// 货币（ISO 代码存储，运行时解析为 Currency），默认人民币。
    var currency: Currency {
        get {
            let code = defaults.string(forKey: Key.currency) ?? Currency.cny.rawValue
            return Currency(rawValue: code) ?? .cny
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.currency)
            defaults.synchronize()
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }

    /// 状态栏显示模式。
    var statusItemMode: StatusItemMode {
        get {
            let v = defaults.integer(forKey: Key.statusItemMode)
            return StatusItemMode(rawValue: v) ?? .power
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.statusItemMode)
            defaults.synchronize()
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }

    /// App 内语言选择。注意：改语言不会触发 prefsChanged（需重启 App 才生效，
    /// 由调用方处理重启，避免半中半英的中间态）。
    var appLanguage: AppLanguage {
        get {
            let v = defaults.string(forKey: Key.appLanguage) ?? AppLanguage.system.rawValue
            return AppLanguage(rawValue: v) ?? .system
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appLanguage)
            defaults.synchronize()
        }
    }

    // MARK: - 告警

    /// 是否启用功率超阈值告警，默认关。
    var alertPowerEnabled: Bool {
        get { defaults.bool(forKey: Key.alertPowerOn) }
        set {
            defaults.set(newValue, forKey: Key.alertPowerOn)
            defaults.synchronize()
        }
    }

    /// 功率告警阈值（瓦），默认 30W。
    var alertPowerThresholdW: Double {
        get {
            let v = defaults.double(forKey: Key.alertPowerThreshold)
            return v > 0 ? v : 30
        }
        set {
            defaults.set(max(0, newValue), forKey: Key.alertPowerThreshold)
            defaults.synchronize()
        }
    }

    /// 是否启用日费用超预算告警，默认关。
    var alertBudgetEnabled: Bool {
        get { defaults.bool(forKey: Key.alertBudgetOn) }
        set {
            defaults.set(newValue, forKey: Key.alertBudgetOn)
            defaults.synchronize()
        }
    }

    /// 日预算（货币单位），默认 1.0。
    var alertBudgetThreshold: Double {
        get {
            let v = defaults.double(forKey: Key.alertBudgetThreshold)
            return v > 0 ? v : 1.0
        }
        set {
            defaults.set(max(0, newValue), forKey: Key.alertBudgetThreshold)
            defaults.synchronize()
        }
    }

    // MARK: - 图表区间

    /// 图表显示区间，默认最近 24 小时。
    var chartRange: ChartRange {
        get {
            let v = defaults.integer(forKey: Key.chartRange)
            return ChartRange(rawValue: v) ?? .hours24
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.chartRange)
            defaults.synchronize()
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }

    // MARK: - 功率校正

    /// 功率校正系数。默认 1.2（Apple Silicon 中高负载下 墙功耗/SoC 功耗 的典型比值）。
    /// 含电源转换损耗(~5-7%) + 板载/外设开销；负载越高越准，空闲会偏低（因整机有固定地板功耗）。
    /// 用户可用智能插座精确标定：墙功耗 ÷ SoC 功耗 = 系数。
    var powerCorrectionFactor: Double {
        get {
            let v = defaults.double(forKey: Key.correctionFactor)
            // 0 表示从未设置过，用默认 1.2。
            return v > 0 ? v : 1.2
        }
        set {
            // 限定 1.0~2.0 合理范围。
            let clamped = max(1.0, min(2.0, newValue))
            defaults.set(clamped, forKey: Key.correctionFactor)
            defaults.synchronize()
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let prefsChanged = Notification.Name("PowerCumulPrefsChanged")
    /// 用户在面板内一键授权成功后发出，AppDelegate 收到后立即开始采样。
    static let privilegeGranted = Notification.Name("PowerCumulPrivilegeGranted")
    /// 设置区折叠/展开状态变化，AppDelegate 据此调整 popover 高度。
    static let settingsCollapseChanged = Notification.Name("PowerCumulSettingsCollapseChanged")
    /// 主面板请求打开设置窗口。
    static let openSettingsRequested = Notification.Name("PowerCumulOpenSettingsRequested")
    /// 设置窗口请求切换语言（需重启 App）。
    static let languageChangeRequested = Notification.Name("PowerCumulLanguageChangeRequested")
    /// 设置窗口已关闭（AppDelegate 据此切回 accessory 策略）。
    static let settingsWindowClosed = Notification.Name("PowerCumulSettingsWindowClosed")
}
