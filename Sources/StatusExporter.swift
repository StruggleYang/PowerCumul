//
//  StatusExporter.swift
//  PowerCumul
//
//  把当前快照每分钟原子写出到 status.json（Application Support/PowerCumul/）。
//  面向 Mac mini 常开/服务器场景：homelab 脚本、Grafana、自动化可直接读文件，
//  不引入任何网络服务，保持项目零依赖哲学。
//
//  文件是机器读的（字段名稳定、驼峰命名），人读的面板数据不经过这里。
//

import Foundation

final class StatusExporter {

    /// status.json 的内容结构。字段只增不改名；下线字段先保留几个版本再删。
    struct Payload: Codable {
        let updatedAt: Date
        let version: String
        let currentW: Double
        let cpuW: Double
        let gpuW: Double
        let aneW: Double
        let dramW: Double
        let todayKwh: Double
        let totalKwh: Double
        let estimatedCost: Double
        let currency: String
        let pricePerKWh: Double
        let uptimeSeconds: Double
        /// 最近 24 小时的耗电应用 TOP（share ∈ 0...1，wh 为归因估算）。
        let topConsumers: [Consumer]
        let correctionFactor: Double

        struct Consumer: Codable {
            let name: String
            let share: Double
            let wh: Double
        }
    }

    private let prefs: Preferences
    private weak var store: EnergyStore?
    private weak var processStore: ProcessEnergyStore?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.powercumul.statusexporter")

    private var outputURL: URL {
        EnergyStore.dataDirectory.appendingPathComponent("status.json")
    }

    init(prefs: Preferences, store: EnergyStore, processStore: ProcessEnergyStore) {
        self.prefs = prefs
        self.store = store
        self.processStore = processStore
    }

    func start() {
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 5   // 省电：允许系统合并唤醒
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即写一次。sample 为 nil 时用 store 里的最近功率。
    func poll(sample: PowerSample? = nil) {
        guard let store, let processStore else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let snap = store.currentSnapshot()
            let w = (sample?.totalMW ?? snap.currentMW) / 1000
            let tops = processStore.topApps(lastHours: 24,
                                            totalWh: snap.hours.suffix(24).reduce(0) { $0 + $1.wh })
            let payload = Payload(
                updatedAt: Date(),
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                currentW: w,
                cpuW: (sample?.cpuMW ?? 0) / 1000,
                gpuW: (sample?.gpuMW ?? 0) / 1000,
                aneW: (sample?.aneMW ?? 0) / 1000,
                dramW: (sample?.dramMW ?? 0) / 1000,
                todayKwh: snap.todayWh / 1000,
                totalKwh: snap.totalWh / 1000,
                estimatedCost: snap.totalWh / 1000 * self.prefs.pricePerKWh,
                currency: self.prefs.currency.rawValue,
                pricePerKWh: self.prefs.pricePerKWh,
                uptimeSeconds: Date().timeIntervalSince(snap.createdAt),
                topConsumers: tops.map {
                    .init(name: $0.name, share: $0.share, wh: $0.attributedWh)
                },
                correctionFactor: self.prefs.powerCorrectionFactor)
            // updatedAt 用 ISO8601 字符串（默认的 Apple 参考日期纪元对外部脚本不可读）。
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(payload) else { return }
            try? data.write(to: self.outputURL, options: .atomic)
        }
    }
}
