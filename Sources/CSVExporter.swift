//
//  CSVExporter.swift
//  PowerCumul
//
//  把累计数据导出为 CSV。两段内容：
//  - 天级汇总（日期、当天 kWh、估算费用）
//  - 小时级明细（时间桶、Wh、估算费用）
//  导出的费用按当前货币与电价计算（快照）。
//

import AppKit
import CoreServices
import Foundation

enum CSVExporter {

    /// 生成 CSV 文本（UTF-8 + BOM，保证 Excel 正确识别中文）。
    static func makeCSV(snapshot: Snapshot, prefs: Preferences) -> String {
        var out = "\u{FEFF}"   // UTF-8 BOM
        let nl = "\r\n"         // Windows 换行，Excel/Numbers 通用
        let sep = ","

        let symbol = prefs.currency.symbol
        let price = prefs.pricePerKWh

        // —— 天级汇总 ——
        out += "\(header("date"))\(sep)\(header("kwh"))\(sep)\(header("cost"))\(nl)"
        // 倒序展示（最新在前），便于阅读。
        for d in snapshot.days.reversed() {
            let cost = d.wh / 1000 * price
            out += "\(d.bucketKey)\(sep)\(fmt(d.wh / 1000, 4))\(sep)\(fmt(cost, 4))\(nl)"
        }

        out += nl + nl

        // —— 小时级明细 ——
        out += "\(header("hour"))\(sep)\(header("wh"))\(sep)\(header("cost"))\(nl)"
        for h in snapshot.hours.reversed() {
            let cost = h.wh / 1000 * price
            out += "\(h.bucketKey)\(sep)\(fmt(h.wh, 2))\(sep)\(fmt(cost, 4))\(nl)"
        }

        out += nl + nl
        // —— 汇总行 ——
        out += "\(kv("summary.totalKwh"))\(sep)\(fmt(snapshot.totalWh / 1000, 4))\(nl)"
        out += "\(kv("summary.todayKwh"))\(sep)\(fmt(snapshot.todayWh / 1000, 4))\(nl)"
        out += "\(kv("summary.pricePerKwh"))\(sep)\(fmt(price, 4)) \(symbol)\(nl)"
        return out
    }

    /// 弹 NSSavePanel 让用户选保存位置，写盘。返回是否导出成功。
    @discardableResult
    static func export(snapshot: Snapshot, prefs: Preferences) -> Bool {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("export.title", value: "导出数据", comment: "")
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let csv = makeCSV(snapshot: snapshot, prefs: prefs)
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 工具

    private static func defaultFilename() -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "yyyy-MM-dd"
        return "PowerCumul-\(df.string(from: Date())).csv"
    }

    /// 表头本地化。
    private static func header(_ key: String) -> String {
        switch key {
        case "date": return NSLocalizedString("csv.date", value: "日期", comment: "")
        case "kwh":  return NSLocalizedString("csv.kwh", value: "电量(kWh)", comment: "")
        case "cost": return NSLocalizedString("csv.cost", value: "费用", comment: "")
        case "hour": return NSLocalizedString("csv.hour", value: "时间(时)", comment: "")
        case "wh":   return NSLocalizedString("csv.wh", value: "能量(Wh)", comment: "")
        default:     return key
        }
    }

    /// 汇总行键名本地化。
    private static func kv(_ key: String) -> String {
        switch key {
        case "summary.totalKwh":  return NSLocalizedString("csv.total", value: "累计电量(kWh)", comment: "")
        case "summary.todayKwh":  return NSLocalizedString("csv.today", value: "今日电量(kWh)", comment: "")
        case "summary.pricePerKwh": return NSLocalizedString("csv.price", value: "电价", comment: "")
        default: return key
        }
    }

    /// 固定小数位，避免 locale 对 CSV 的逗号/点干扰（CSV 用逗号分隔，故小数强制用点）。
    private static func fmt(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v)
    }
}
