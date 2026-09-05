//
//  BatteryMonitor.swift
//  PowerCumul
//
//  电池信息（只读）：电量 / 充放电状态 / 健康度 / 循环次数 / 温度 / 电池功率。
//  两路数据源，均为系统只读接口，免 root：
//  - IOPSCopyPowerSourcesInfo（公开 API）：有无电池、电量百分比、充放电状态、剩余时间
//  - IOKit AppleSmartBattery 注册表：循环次数、设计/满充容量（→ 健康度）、温度、电压电流
//
//  平台降级：Mac mini / iMac 等无电池设备上 IOPS 不含内部电池电源（即使存在
//  AppleSmartBattery 注册表节点，BatteryInstalled 也是 No）→ hasBattery = false，
//  上层据此隐藏面板电池卡片与状态栏电池组件。
//
//  调试开关：环境变量 POWERCUMUL_FAKE_BATTERY=1/2 注入充电中/放电演示数据，
//  用于在无电池设备上验证笔记本 UI 路径（面板卡片、状态栏组件）。仅显式设置时生效。
//

import Foundation
import IOKit
import IOKit.ps

/// 一次电池快照。字段可为 nil（键不存在或数值异常时上层不展示该字段）。
struct BatteryInfo {
    var hasBattery = false
    var levelPercent: Int?          // 0-100
    var isCharging = false
    var isExternalConnected = false
    var isFullyCharged = false
    var cycleCount: Int?
    var healthPercent: Int?         // 满充容量 / 设计容量
    var temperatureC: Double?
    var powerW: Double?             // |电流 × 电压|，方向看充放电状态
    var timeToEmptyMinutes: Int?    // 使用电池时的剩余时间
    var timeToFullMinutes: Int?     // 充电中的预计充满时间
}

enum BatteryMonitor {

    /// 采样一次电池快照。纯读取，任意线程可调，单次开销微秒级。
    static func current() -> BatteryInfo {
        // 测试/演示注入（见文件头注释）。
        switch ProcessInfo.processInfo.environment["POWERCUMUL_FAKE_BATTERY"] {
        case "1": return fakeCharging
        case "2": return fakeDischarging
        default: break
        }

        var info = readPowerSources()
        if info.hasBattery {
            mergeSmartBatteryDetails(into: &info)
        }
        return info
    }

    /// 当前设备是否有可用电池（mini/台式机为 false）。
    static func hasBattery() -> Bool {
        current().hasBattery
    }

    // MARK: - 电源列表（公开 API：电量百分比 / 充放状态 / 剩余时间）

    private static func readPowerSources() -> BatteryInfo {
        var info = BatteryInfo()
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [AnyObject]
        for source in sources {
            let desc = (IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue()) as? [String: Any] ?? [:]
            // 只认内部电池（kIOPSTypeInternalBattery 是 C 宏，Swift 不导入，用字面量），
            // 外接 UPS 不算（mini + UPS 仍是"无电池"降级路径）。
            guard (desc[kIOPSTypeKey] as? String) == "InternalBattery" else { continue }
            info.hasBattery = true
            let level = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
            info.levelPercent = (0...100).contains(level) ? level : nil
            info.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            info.isExternalConnected = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            // -1 = 系统未给估计值；-2 = 估计值无效。
            let secs = IOPSGetTimeRemainingEstimate()
            if secs > 0 {
                let mins = Int(secs / 60)
                if info.isCharging {
                    info.timeToFullMinutes = mins
                } else {
                    info.timeToEmptyMinutes = mins
                }
            }
            break   // 内置设备只有一个内部电池电源
        }
        return info
    }

    // MARK: - AppleSmartBattery 注册表（硬件细节：循环/容量/温度/功率）

    private static func mergeSmartBatteryDetails(into info: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any] else { return }

        // 明确标注未装电池（mini 上该节点存在但 BatteryInstalled=No）→ 按无电池降级。
        if props["BatteryInstalled"] as? Bool == false {
            info.hasBattery = false
            return
        }

        info.isFullyCharged = props["FullyCharged"] as? Bool ?? false
        if let n = int(props["CycleCount"]), (0...100_000).contains(n) {
            info.cycleCount = n
        }
        if let t = int(props["Temperature"]), (-2000...12_000).contains(t) {
            info.temperatureC = Double(t) / 100   // 注册表单位：百分之一摄氏度
        }
        if let mv = int(props["Voltage"]), let ma = int(props["Amperage"]),
           mv > 0, abs(ma) < 100_000 {
            info.powerW = abs(Double(mv) * Double(ma) / 1e9)
        }

        // 健康度 = 满充容量 / 设计容量。优先 AppleRaw*（Apple Silicon 实测值），
        // 回退 MaxCapacity / DesignCapacity（老 Intel 键）。
        let maxCap = int(props["AppleRawMaxCapacity"]) ?? int(props["MaxCapacity"]) ?? 0
        let design = int(props["AppleRawDesignCapacity"]) ?? int(props["DesignCapacity"]) ?? 0
        if maxCap > 0, design > 0 {
            info.healthPercent = min(100, max(0, Int((Double(maxCap) / Double(design) * 100).rounded())))
        }

        // 系统自带的平均充/放电时间估计（分钟；不可用时是 0 或 65535 之类哨兵值），
        // 比 IOPS 的粗估更稳，取到就覆盖。
        if info.isCharging, let m = int(props["AvgTimeToFull"]), (1...3000).contains(m) {
            info.timeToFullMinutes = m
        }
        if !info.isExternalConnected, let m = int(props["AvgTimeToEmpty"]), (1...3000).contains(m) {
            info.timeToEmptyMinutes = m
        }
    }

    /// CFNumber/Int 容错取整（注册表数值类型不统一）。
    private static func int(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }

    // MARK: - 演示数据（仅 POWERCUMUL_FAKE_BATTERY 开启时）

    private static let fakeCharging: BatteryInfo = {
        var i = BatteryInfo()
        i.hasBattery = true
        i.levelPercent = 87
        i.isCharging = true
        i.isExternalConnected = true
        i.cycleCount = 156
        i.healthPercent = 92
        i.temperatureC = 31.5
        i.powerW = 23.5
        i.timeToFullMinutes = 27
        return i
    }()

    private static let fakeDischarging: BatteryInfo = {
        var i = BatteryInfo()
        i.hasBattery = true
        i.levelPercent = 64
        i.cycleCount = 156
        i.healthPercent = 92
        i.temperatureC = 29.8
        i.powerW = 8.4
        i.timeToEmptyMinutes = 187
        return i
    }()
}
