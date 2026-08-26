//
//  Currency.swift
//  PowerCumul
//
//  货币预设：常用货币的符号、代码、本地化单位写法。
//  价格单位统一为「每 kWh」，用户在面板选货币 + 填电价数值。
//

import Foundation

/// 预设货币。符号用于显示，code 用于持久化（不随语言变化，稳定存储）。
enum Currency: String, CaseIterable {
    case cny  // 人民币
    case usd  // 美元
    case eur  // 欧元
    case gbp  // 英镑
    case jpy  // 日元
    case krw  // 韩元
    case rub  // 俄罗斯卢布
    case inr  // 印度卢比
    case twd  // 新台币
    case hkd  // 港币
    case aud  // 澳元
    case cad  // 加元

    /// 货币符号（用于费用展示，如 ¥ $ €）。
    var symbol: String {
        switch self {
        case .cny: return "¥"
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .jpy: return "¥"
        case .krw: return "₩"
        case .rub: return "₽"
        case .inr: return "₹"
        case .twd: return "NT$"
        case .hkd: return "HK$"
        case .aud: return "A$"
        case .cad: return "C$"
        }
    }

    /// 每千瓦时电价的本地化单位写法（如 "元/kWh"、"per kWh"）。
    /// 用 NSLocalizedString 跟随系统语言。
    var perKWhUnit: String {
        switch self {
        case .cny: return NSLocalizedString("unit.cny.perKWh", value: "元/kWh", comment: "人民币电价单位")
        case .usd, .aud, .cad: return NSLocalizedString("unit.usd.perKWh", value: "/kWh", comment: "美元系电价单位")
        case .eur: return NSLocalizedString("unit.eur.perKWh", value: "/kWh", comment: "欧元电价单位")
        case .gbp: return NSLocalizedString("unit.gbp.perKWh", value: "/kWh", comment: "英镑电价单位")
        case .jpy: return NSLocalizedString("unit.jpy.perKWh", value: "/kWh", comment: "日元电价单位")
        case .krw: return NSLocalizedString("unit.krw.perKWh", value: "/kWh", comment: "韩元电价单位")
        case .rub: return NSLocalizedString("unit.rub.perKWh", value: "/kWh", comment: "卢布电价单位")
        case .inr: return NSLocalizedString("unit.inr.perKWh", value: "/kWh", comment: "卢比电价单位")
        case .twd: return NSLocalizedString("unit.twd.perKWh", value: "/kWh", comment: "台币电价单位")
        case .hkd: return NSLocalizedString("unit.hkd.perKWh", value: "/kWh", comment: "港币电价单位")
        }
    }

    /// 下拉项显示文本：符号 + 代码，如 "¥ CNY"、"USD $"。
    var displayName: String {
        "\(symbol) \(rawValue.uppercased())"
    }
}

/// 状态栏显示模式。
enum StatusItemMode: Int, CaseIterable {
    case power = 0       // 仅功率
    case cost = 1        // 仅费用
    case kwh = 2         // 仅电量
    case combo = 3       // 功率 + 费用（紧凑组合）
    case iconOnly = 4    // 仅图标
    case net = 5         // 网速（↑上传 ↓下载）

    /// 用于设置区分段控件的标签（本地化）。
    var shortLabel: String {
        switch self {
        case .power:    return NSLocalizedString("mode.power", value: "功率", comment: "状态栏模式：功率")
        case .cost:     return NSLocalizedString("mode.cost", value: "费用", comment: "状态栏模式：费用")
        case .kwh:      return NSLocalizedString("mode.kwh", value: "电量", comment: "状态栏模式：电量")
        case .combo:    return NSLocalizedString("mode.combo", value: "组合", comment: "状态栏模式：组合")
        case .iconOnly: return NSLocalizedString("mode.iconOnly", value: "图标", comment: "状态栏模式：仅图标")
        case .net:      return NSLocalizedString("mode.net", value: "网速", comment: "状态栏模式：网速")
        }
    }
}

/// App 内语言选择。
/// - system: 跟随 macOS 系统语言
/// - zh-Hans / en: 强制指定，重启后全程生效
enum AppLanguage: String, CaseIterable {
    case system
    case zhHans = "zh-Hans"
    case en

    /// 下拉项显示文本（自身不随语言变化，便于识别）。
    var displayName: String {
        switch self {
        case .system: return NSLocalizedString("lang.system", value: "跟随系统", comment: "语言选项：跟随系统")
        case .zhHans: return "中文"
        case .en:     return "English"
        }
    }

    /// 写入 AppleLanguages 的值；system 时返回 nil（不覆盖，用系统默认）。
    var appleLanguagesValue: [String]? {
        switch self {
        case .system: return nil
        case .zhHans: return ["zh-Hans"]
        case .en:     return ["en"]
        }
    }
}

/// 图表显示区间。
enum ChartRange: Int, CaseIterable {
    case hours24 = 0   // 最近 24 小时（小时桶）
    case days7 = 1     // 最近 7 天（天桶）
    case days30 = 2    // 最近 30 天（天桶）

    /// 用于时段切换分段控件的标签（本地化）。
    var shortLabel: String {
        switch self {
        case .hours24: return NSLocalizedString("range.24h", value: "24小时", comment: "图表区间：24小时")
        case .days7:   return NSLocalizedString("range.7d", value: "7天", comment: "图表区间：7天")
        case .days30:  return NSLocalizedString("range.30d", value: "30天", comment: "图表区间：30天")
        }
    }
}
