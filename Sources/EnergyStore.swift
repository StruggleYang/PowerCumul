//
//  EnergyStore.swift
//  PowerCumul
//
//  存储分两层：
//  1. 原始采样流 samples.jsonl —— 只追加，每次采样写一行（~80B），写入恒定、断电安全。
//     坏一行不影响其他行；想重算聚合随时可从原始流重建。
//  2. 聚合状态 state.json —— 小文件全量原子重写（.atomic），存累计/今日/小时桶/天桶。
//     文件本身很小（小时桶≤168、天桶≤365 个条目，但每个条目只是一个 key+数值），
//     全量重写代价低，且只在实际有变化时写。
//
//  累计能量公式：E(Wh) += P(mW) × Δt(秒) / 3600 / 1000
//

import Foundation

/// 累计能量与历史序列的持久化存储。线程安全（内部串行队列）。
final class EnergyStore {

    /// 单条小时桶：某小时的累计能量（Wh）。bucketKey 为 "yyyy-MM-dd HH"。
    struct HourBucket: Codable {
        let bucketKey: String
        var wh: Double
    }

    /// 单条天桶：某天的累计能量（Wh）。bucketKey 为 "yyyy-MM-dd"。
    struct DayBucket: Codable {
        let bucketKey: String
        var wh: Double
    }

    /// 聚合状态（小文件，全量原子重写）。
    struct AggregatedState: Codable {
        var createdAt: Date           // 首次运行锚点
        var totalWh: Double           // 自 createdAt 起累计能量
        var todayWh: Double           // 当日累计（跨自然日重置）
        var lastSampleDate: Date      // 上次采样时间
        var lastTotalMW: Double       // 上次采样瞬时功率（断电补偿/状态栏回显）
        var hours: [HourBucket]       // 按小时聚合（最多 168 条 ≈ 一周）
        var days: [DayBucket]         // 按天聚合（最多 365 条）
    }

    /// 单条原始采样（JSONL 一行）。Codable 用于 JSONEncoder 产出单行。
    struct RawSample: Codable {
        let ts: Double        // 时间戳（Date.timeIntervalSince1970）
        let mw: Double        // SoC 总功率 mW
        let cpu: Double
        let gpu: Double
        let ane: Double
        let dram: Double
        let src: String       // 解析来源 Combined/Package/Sum
    }

    private let queue = DispatchQueue(label: "com.powercumul.energystore")
    private let samplesURL: URL       // samples.jsonl（追加）
    private let stateURL: URL         // state.json（聚合）
    private(set) var state: AggregatedState

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerCumul", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        samplesURL = dir.appendingPathComponent("samples.jsonl")
        stateURL = dir.appendingPathComponent("state.json")

        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(AggregatedState.self, from: data) {
            state = decoded
        } else {
            state = AggregatedState(createdAt: Date(),
                                    totalWh: 0,
                                    todayWh: 0,
                                    lastSampleDate: Date(),
                                    lastTotalMW: 0,
                                    hours: [],
                                    days: [])
        }
    }

    // MARK: - 写入

    /// 提交一次新采样：①追加一行到 samples.jsonl ②更新聚合状态并写 state.json。
    @discardableResult
    func add(sample: PowerSample) -> Snapshot {
        queue.sync {
            let now = sample.timestamp
            let dt = now.timeIntervalSince(state.lastSampleDate)

            // 仅当时间差合理（0 < dt < 1 小时）才累加，避免睡眠唤醒后大跳变。
            var deltaWh: Double = 0
            if dt > 0 && dt < 3600 {
                deltaWh = sample.totalMW * dt / 3600.0 / 1000.0
                state.totalWh += deltaWh
                state.todayWh += deltaWh
                rollIntoHours(wh: deltaWh, at: now)
            }

            state.lastSampleDate = now
            state.lastTotalMW = sample.totalMW

            // ① 追加原始采样（独立于聚合写入，互不影响）。
            appendRaw(sample: sample)
            // ② 写聚合状态（原子重写，文件小）。
            persistState()
            return snapshot()
        }
    }

    // MARK: - 读取

    func currentSnapshot() -> Snapshot {
        queue.sync { snapshot() }
    }

    func recentHours(_ count: Int) -> [HourBucket] {
        queue.sync { Array(state.hours.suffix(count)) }
    }

    // MARK: - 内部：原始流追加

    /// 向 samples.jsonl 追加一行。失败不影响聚合（聚合已先更新）。
    private func appendRaw(sample: PowerSample) {
        let raw = RawSample(
            ts: sample.timestamp.timeIntervalSince1970,
            mw: sample.totalMW,
            cpu: sample.cpuMW,
            gpu: sample.gpuMW,
            ane: sample.aneMW,
            dram: sample.dramMW,
            src: sample.source)
        // 单行 JSON + 换行。用 FileHandle 追加，不读旧内容。
        guard let line = try? JSONEncoder().encode(raw),
              var str = String(data: line, encoding: .utf8) else { return }
        str += "\n"
        // ensureFileExists：首次创建文件；后续追加。
        if !FileManager.default.fileExists(atPath: samplesURL.path) {
            FileManager.default.createFile(atPath: samplesURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: samplesURL) {
            _ = try? handle.seekToEnd()
            if let data = str.data(using: .utf8) {
                _ = try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }
    }

    // MARK: - 内部：聚合

    private func rollIntoHours(wh: Double, at date: Date) {
        let hourKey = Self.hourKey(date)
        if let idx = state.hours.lastIndex(where: { $0.bucketKey == hourKey }) {
            state.hours[idx].wh += wh
        } else {
            state.hours.append(HourBucket(bucketKey: hourKey, wh: wh))
        }
        if state.hours.count > 168 {
            state.hours.removeFirst(state.hours.count - 168)
        }

        // 天桶 + 跨日重置 todayWh。
        let dayKey = Self.dayKey(date)
        if let idx = state.days.lastIndex(where: { $0.bucketKey == dayKey }) {
            state.days[idx].wh += wh
        } else {
            // 新的一天：todayWh 语义为"今天"，新天开始归零为本次增量。
            state.days.append(DayBucket(bucketKey: dayKey, wh: wh))
            state.todayWh = wh
        }
        if state.days.count > 365 {
            state.days.removeFirst(state.days.count - 365)
        }
    }

    /// 小文件聚合状态原子重写。
    private func persistState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(totalWh: state.totalWh,
                 todayWh: state.todayWh,
                 createdAt: state.createdAt,
                 lastSampleDate: state.lastSampleDate,
                 currentMW: state.lastTotalMW,
                 hours: state.hours,
                 days: state.days)
    }

    // MARK: - 日期格式化

    private static func hourKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd' 'HH"
        return f.string(from: d)
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// 面板展示用的只读快照（接口不变，上层无需改动）。
struct Snapshot {
    let totalWh: Double
    let todayWh: Double
    let createdAt: Date
    let lastSampleDate: Date
    let currentMW: Double
    let hours: [EnergyStore.HourBucket]
    let days: [EnergyStore.DayBucket]
}
