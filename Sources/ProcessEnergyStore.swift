//
//  ProcessEnergyStore.swift
//  PowerCumul
//
//  按进程能耗的桶聚合存储（耗电应用 TOP 列表的数据源）。
//
//  数据来自 powermetrics --show-process-energy 的 Energy Impact（加权代理分，
//  含 CPU/GPU/IO/网络，无官方物理单位）。只用其相对占比做归因：
//      appWh = (app 分数 / 该桶全部分数总和) × 该桶实测 Wh
//  占比与排名不受单位影响；Wh 为归因估算值而非电表精度。
//
//  桶结构与 EnergyStore 对齐：小时桶 "yyyy-MM-dd HH"（保留 168 个 ≈ 一周）、
//  天桶 "yyyy-MM-dd"（保留 365 个）。
//
//  持久化：process_energy.jsonl append-only，仅在整桶完成（跨小时/跨天）时
//  追加一行（每桶只存 TOP 20 + 全量分数和，~700B/行，年增约 300KB，无需轮转）。
//  当前进行中的桶驻内存；退出时 flush 补写，重启时若仍是同一桶则续算。
//  绝不放进 state.json（那文件每 5s 全量重写，会写放大）。
//

import Foundation

final class ProcessEnergyStore {

    /// 单个桶：按进程累计的 Energy Impact 分数。
    /// total 为全部分数总和（含未进 TOP 的长尾），是占比的归一化分母。
    struct Bucket: Codable {
        var apps: [String: Double]
        var total: Double
    }

    /// JSONL 一行：k=桶key，g=粒度(0 小时/1 天)。同 key 后行覆盖前行（flush 后续算场景）。
    private struct BucketRecord: Codable {
        let k: String
        let g: Int
        let apps: [String: Double]
        let total: Double
    }

    /// 面板展示用的聚合结果。
    struct TopApp {
        let name: String
        let share: Double        // 0...1，占区间归一化分母的比例
        let attributedWh: Double // share × 区间实测总 Wh
    }

    private let queue = DispatchQueue(label: "com.powercumul.processenergystore")
    private let fileURL: URL

    private var hourBuckets: [String: Bucket] = [:]   // 已完成小时桶
    private var dayBuckets: [String: Bucket] = [:]    // 已完成天桶
    private var currentHourKey: String?
    private var currentHour = Bucket(apps: [:], total: 0)
    private var currentDayKey: String?
    private var currentDay = Bucket(apps: [:], total: 0)

    private static let maxHourBuckets = 168
    private static let maxDayBuckets = 365
    private static let topNPerBucket = 20

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerCumul", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("process_energy.jsonl")
        load()
    }

    // MARK: - 写入

    /// 提交一个采样块的进程能耗行。桶 key 变化时把上一桶裁剪落盘。
    func add(rows: [ProcessEnergyRow], at date: Date) {
        guard !rows.isEmpty else { return }
        queue.sync {
            let hk = Self.hourKey(date)
            if hk != currentHourKey {
                if let key = currentHourKey, currentHour.total > 0 {
                    closeHourBucket(key: key, bucket: currentHour)
                }
                currentHourKey = hk
                currentHour = Bucket(apps: [:], total: 0)
            }
            let dk = Self.dayKey(date)
            if dk != currentDayKey {
                if let key = currentDayKey, currentDay.total > 0 {
                    closeDayBucket(key: key, bucket: currentDay)
                }
                currentDayKey = dk
                currentDay = Bucket(apps: [:], total: 0)
            }
            for r in rows {
                currentHour.apps[r.name, default: 0] += r.score
                currentHour.total += r.score
                currentDay.apps[r.name, default: 0] += r.score
                currentDay.total += r.score
            }
        }
    }

    /// 退出前补写进行中的桶（同一桶重启后续算，同 key 后行覆盖前行）。
    func flush() {
        queue.sync {
            if let key = currentHourKey, currentHour.total > 0 {
                closeHourBucket(key: key, bucket: currentHour)
            }
            if let key = currentDayKey, currentDay.total > 0 {
                closeDayBucket(key: key, bucket: currentDay)
            }
        }
    }

    // MARK: - 查询

    /// 最近 count 个小时桶（含进行中的当前桶）的 TOP 应用聚合。
    /// - Parameter totalWh: 同区间的实测总能量（EnergyStore 小时桶求和），用于归因换算。
    func topApps(lastHours count: Int, totalWh: Double, top: Int = 5) -> [TopApp] {
        var keys = Array(hourBuckets.keys.sorted().suffix(count))
        if let cur = currentHourKey, currentHour.total > 0, !keys.contains(cur) {
            keys.append(cur)   // key 字典序即时间序，当前桶必然排最后
        }
        let window = keys.compactMap { key -> Bucket? in
            // 当前桶优先取内存活数据（flush 后仍可能继续累计）。
            (key == currentHourKey) ? currentHour : hourBuckets[key]
        }
        return merge(window: window, totalWh: totalWh, top: top)
    }

    /// 最近 count 个天桶（含进行中的当天桶）的 TOP 应用聚合。
    func topApps(lastDays count: Int, totalWh: Double, top: Int = 5) -> [TopApp] {
        var keys = Array(dayBuckets.keys.sorted().suffix(count))
        if let cur = currentDayKey, currentDay.total > 0, !keys.contains(cur) {
            keys.append(cur)
        }
        let window = keys.compactMap { key -> Bucket? in
            (key == currentDayKey) ? currentDay : dayBuckets[key]
        }
        return merge(window: window, totalWh: totalWh, top: top)
    }

    /// 跨桶按进程名求和，再按分数排序取 TOP；长尾并入"其他"由调用方决定是否展示。
    private func merge(window: [Bucket], totalWh: Double, top: Int) -> [TopApp] {
        var merged: [String: Double] = [:]
        var denominator = 0.0
        for b in window {
            for (name, score) in b.apps {
                merged[name, default: 0] += score
            }
            denominator += b.total
        }
        guard denominator > 0 else { return [] }
        return merged
            .sorted { $0.value > $1.value }
            .prefix(top)
            .map { TopApp(name: $0.key,
                          share: $0.value / denominator,
                          attributedWh: $0.value / denominator * totalWh) }
    }

    /// 剩余长尾占比（TOP 之外），供"其他"行展示。
    func otherShare(of tops: [TopApp]) -> Double {
        let shown = tops.reduce(0) { $0 + $1.share }
        return max(0, min(1, 1 - shown))
    }

    // MARK: - 内部：落盘与加载

    private func closeHourBucket(key: String, bucket: Bucket) {
        let prunedBucket = pruned(bucket)
        hourBuckets[key] = prunedBucket
        if hourBuckets.count > Self.maxHourBuckets {
            let drop = hourBuckets.keys.sorted().prefix(hourBuckets.count - Self.maxHourBuckets)
            for k in drop { hourBuckets.removeValue(forKey: k) }
        }
        appendRecord(BucketRecord(k: key, g: 0, apps: prunedBucket.apps, total: bucket.total))
    }

    private func closeDayBucket(key: String, bucket: Bucket) {
        let prunedBucket = pruned(bucket)
        dayBuckets[key] = prunedBucket
        if dayBuckets.count > Self.maxDayBuckets {
            let drop = dayBuckets.keys.sorted().prefix(dayBuckets.count - Self.maxDayBuckets)
            for k in drop { dayBuckets.removeValue(forKey: k) }
        }
        appendRecord(BucketRecord(k: key, g: 1, apps: prunedBucket.apps, total: bucket.total))
    }

    /// 每桶只保留 TOP N 进程（total 保留全量和，归一化不受裁剪影响）。
    private func pruned(_ b: Bucket) -> Bucket {
        let top = b.apps.sorted { $0.value > $1.value }.prefix(Self.topNPerBucket)
        return Bucket(apps: Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) }),
                      total: b.total)
    }

    private func appendRecord(_ record: BucketRecord) {
        guard let data = try? JSONEncoder().encode(record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                _ = try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }
    }

    /// 读全文件重建桶字典。同 key 后行覆盖前行；若末行 key 仍是"当前"小时/天，
    /// 还原为进行中的桶（与 flush() 配对，重启续算不丢不重）。
    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let now = Date()
        let curHour = Self.hourKey(now)
        let curDay = Self.dayKey(now)
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let rec = try? JSONDecoder().decode(BucketRecord.self, from: data) else { continue }
            let bucket = Bucket(apps: rec.apps, total: rec.total)
            switch rec.g {
            case 0:
                if rec.k == curHour {
                    currentHourKey = rec.k
                    currentHour = bucket
                } else {
                    hourBuckets[rec.k] = bucket
                }
            default:
                if rec.k == curDay {
                    currentDayKey = rec.k
                    currentDay = bucket
                } else {
                    dayBuckets[rec.k] = bucket
                }
            }
        }
    }

    // MARK: - 日期格式化（与 EnergyStore 的桶 key 格式严格一致）

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd' 'HH"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func hourKey(_ d: Date) -> String { hourFormatter.string(from: d) }
    static func dayKey(_ d: Date) -> String { dayFormatter.string(from: d) }
}
