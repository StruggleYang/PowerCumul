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

    /// 数据目录（备份/恢复/ Finder 展示用）。
    static var dataDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerCumul", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        samplesURL = Self.dataDirectory.appendingPathComponent("samples.jsonl")
        stateURL = Self.dataDirectory.appendingPathComponent("state.json")

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

    /// 备份/恢复需要的数据文件清单。
    var dataFileURLs: [URL] { [samplesURL, stateURL] }

    // MARK: - 写入

    /// 缺口上限：dt 超过此值视为睡眠/中断，能量记 0（睡眠时 SoC 本就近 0，
    /// 按唤醒后功率全记反而高估）。90s 覆盖最长采样间隔(60s)及看门狗重启。
    private static let gapLimit: TimeInterval = 90

    /// 流式采样节流：原始流与聚合落盘都按时间节流（聚合内存中仍是逐样本累加的）。
    private var lastRawAppend = Date.distantPast
    private var lastPersistAt = Date.distantPast

    /// 提交一次新采样：内存聚合逐样本累加；落盘按时间节流。
    @discardableResult
    func add(sample: PowerSample) -> Snapshot {
        queue.sync {
            let now = sample.timestamp
            let dt = now.timeIntervalSince(state.lastSampleDate)

            var deltaWh: Double = 0
            if dt > 0 && dt <= Self.gapLimit {
                deltaWh = sample.totalMW * dt / 3600.0 / 1000.0
                state.totalWh += deltaWh
                state.todayWh += deltaWh
                rollIntoHours(wh: deltaWh, at: now)
            }
            // dt > gapLimit（睡眠/长时间中断）：能量记 0，仅推进时间戳。

            state.lastSampleDate = now
            state.lastTotalMW = sample.totalMW

            // 落盘节流：1Hz 流式下若逐样本写盘，state.json 每天被全量重写 8.6 万次。
            // 聚合在内存中始终精确，落盘每 5s 一次；原始流同样每 5s 存一个点。
            if now.timeIntervalSince(lastRawAppend) >= 5 {
                appendRaw(sample: sample)
                lastRawAppend = now
            }
            if now.timeIntervalSince(lastPersistAt) >= 5 {
                persistState()
                lastPersistAt = now
            }
            trimRawSamplesIfNeeded(at: now)
            return snapshot()
        }
    }

    /// 重新累计：清零累计电量/今日电量并把"自"锚点重置为现在。
    /// 图表历史（小时桶/天桶）保留，趋势不受影响；原始流不动。
    func resetCumulative() {
        queue.sync {
            state.totalWh = 0
            state.todayWh = 0
            state.createdAt = Date()
            persistState()
        }
    }

    // MARK: - 原始流滚动清理

    /// 原始样本保留天数：聚合已进小时桶/天桶，原始流只服务精细回看，留 7 天足够。
    /// 文件此前无清理逻辑（实测一年可涨到数十 MB），跨天时整体重写一次。
    private static let rawRetentionDays: Double = 7
    private var lastRawTrimDayKey = ""

    /// 跨天时把超过保留期的行裁掉（原子重写）。解析不出 ts 的行原样保留（宁多勿丢）。
    private func trimRawSamplesIfNeeded(at now: Date) {
        let dayK = Self.dayKey(now)
        guard dayK != lastRawTrimDayKey else { return }
        lastRawTrimDayKey = dayK
        guard let text = try? String(contentsOf: samplesURL, encoding: .utf8) else { return }
        let cutoff = now.timeIntervalSince1970 - Self.rawRetentionDays * 86400
        var kept: [Substring] = []
        var dropped = 0
        for line in text.split(separator: "\n") {
            if let ts = rawTimestamp(line), ts < cutoff {
                dropped += 1
            } else {
                kept.append(line)
            }
        }
        guard dropped > 0 else { return }
        guard !kept.isEmpty else {
            FileManager.default.createFile(atPath: samplesURL.path, contents: nil)
            return
        }
        var out = kept.joined(separator: "\n")
        out += "\n"
        if let data = out.data(using: .utf8) {
            try? data.write(to: samplesURL, options: .atomic)
        }
    }

    /// 从一行 JSONL 里抠 "ts": <number>（JSONEncoder 无空格输出）。
    private func rawTimestamp(_ line: Substring) -> Double? {
        guard let keyRange = line.range(of: "\"ts\":") else { return nil }
        let num = line[keyRange.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(num)
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
