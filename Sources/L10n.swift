//
//  L10n.swift
//  PowerCumul
//
//  本地化便捷封装 + locale 感知的数字格式化。
//  - L10n.tr(_:_:args:) 对齐 key 取串并支持 %@/%d 格式参数
//  - L10n.numberFormatter 随系统 locale 格式化小数（如 1,5 vs 1.5）
//

import Foundation

enum L10n {

    /// 在 App 启动最早期调用：根据用户偏好覆盖 AppleLanguages，
    /// 使后续所有 NSLocalizedString / Bundle.main.localizations 走指定语言。
    /// - Important: 必须在任何 UI 创建之前调用（在 main.swift 的最顶端）。
    static func applyLanguage(from prefs: Preferences) {
        let lang = prefs.appLanguage
        if let values = lang.appleLanguagesValue {
            // 覆盖进程语言偏好，NSLocalizedString 会据此从对应 lproj 取串。
            UserDefaults.standard.set(values, forKey: "AppleLanguages")
            // 同步刷新数字/日期格式化器的 locale。
            let preferenceLocale: Locale = values.count == 1
                ? Locale(identifier: values[0])
                : Locale.current
            L10n.numberFormatter.locale = preferenceLocale
            L10n.dateFormatterLocale = preferenceLocale
        } else {
            // 跟随系统：移除我们之前可能写入的覆盖，恢复系统语言。
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            L10n.numberFormatter.locale = Locale.current
            L10n.dateFormatterLocale = Locale.current
        }
        UserDefaults.standard.synchronize()
    }

    /// 取本地化字符串（带格式参数）。
    /// - Parameters:
    ///   - key: Localizable.strings 中的 key
    ///   - fallback: key 缺失时的兜底值
    ///   - args: 用于 %@/%d 占位符的参数
    static func tr(_ key: String, _ fallback: String, _ args: CVarArg...) -> String {
        let template = NSLocalizedString(key, value: fallback, comment: "")
        // 无参数时直接返回，避免 String(format:) 处理 % 之类的边缘情况。
        guard !args.isEmpty else { return template }
        return String(format: template, arguments: args)
    }

    /// 当前生效的 locale（applyLanguage 时设置；默认系统 locale）。
    /// 供日期/数字格式化器统一引用。
    static var dateFormatterLocale: Locale = Locale.current

    /// 随当前 locale 格式化的通用数字格式化器。
    /// 用 var 以便 applyLanguage 切换语言时更新 locale。
    static var numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale.current
        return f
    }()

    /// 格式化一个小数，保留指定小数位，使用当前 locale 的分隔符。
    static func decimal(_ value: Double, fractionDigits: Int) -> String {
        let f = numberFormatter
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 格式化费用：符号 + 金额（2 位小数，locale 分隔符）。
    static func cost(_ amount: Double, currency: Currency) -> String {
        "\(currency.symbol)\(decimal(amount, fractionDigits: 2))"
    }
}
