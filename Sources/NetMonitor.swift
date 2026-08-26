//
//  NetMonitor.swift
//  PowerCumul
//
//  网速监控：getifaddrs 读物理网卡（en*/bridge*）收发字节计数器，
//  轮询差值换算速率。
//
//  设计要点：
//  - 零进程创建（不 netstat/route spawn，与流式采样同样的无 spawn 原则），
//    无需任何权限
//  - 只统计物理网卡，排除 lo0/utun*/awdl*（VPN 流量走 utun 会与 en0 双计）
//  - 接口计数器是 UInt32，4GB 回绕按单接口修正
//

import Foundation

final class NetMonitor {

    private(set) var upBytesPerSec: Double = 0
    private(set) var downBytesPerSec: Double = 0

    /// 上次各接口计数器快照。
    private var lastCounters: [String: (inB: UInt64, outB: UInt64)] = [:]
    private var lastAt: Date?

    /// 轮询一次：读计数器 → 与上次差值换算速率。首次调用只建基线。
    func poll() {
        let now = Date()
        let counters = Self.readCounters()
        defer {
            lastCounters = counters
            lastAt = now
        }
        guard let lastAt = lastAt else { return }
        let dt = now.timeIntervalSince(lastAt)
        guard dt > 0.5, dt < 60 else { return }

        var dIn: Double = 0
        var dOut: Double = 0
        for (name, c) in counters {
            guard let prev = lastCounters[name] else { continue }
            dIn += Double(Self.delta(cur: c.inB, prev: prev.inB))
            dOut += Double(Self.delta(cur: c.outB, prev: prev.outB))
            _ = name
        }
        downBytesPerSec = max(0, dIn / dt)
        upBytesPerSec = max(0, dOut / dt)
    }

    /// UInt32 计数器回绕修正后的差值（接口计数器 ≤ UInt32.max，Int64 运算安全）。
    private static func delta(cur: UInt64, prev: UInt64) -> Int64 {
        var d = Int64(cur) - Int64(prev)
        if d < 0 { d += Int64(UInt32.max) + 1 }
        return max(d, 0)
    }

    /// 读取所有物理网口的收发计数器。
    private static func readCounters() -> [String: (inB: UInt64, outB: UInt64)] {
        var result: [String: (UInt64, UInt64)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return result }
        defer { freeifaddrs(ifap) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let ifa = p.pointee
            // 只看链路层条目（每接口一条，含计数器）。
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: ifa.ifa_name)
            // 只统计物理网卡：en*（以太网/WiFi）、bridge*（桥接）。
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            guard let ifd = unsafeBitCast(ifa.ifa_data, to: UnsafeMutablePointer<if_data>?.self) else { continue }
            result[name] = (UInt64(ifd.pointee.ifi_ibytes), UInt64(ifd.pointee.ifi_obytes))
        }
        return result
    }

    // MARK: - 格式化

    /// 人类可读速率：B/s → KB/s → MB/s。
    static func format(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        if v < 1024 { return String(format: "%.0fB/s", v) }
        let kb = v / 1024
        if kb < 1024 { return String(format: "%.0fKB/s", kb) }
        return String(format: "%.1fMB/s", kb / 1024)
    }
}
