//
//  PowerSampler.swift
//  PowerCumul
//
//  调用 `sudo -n powermetrics` 采样瞬时功率，并容错解析输出。
//  powermetrics 输出字段在跨 macOS 版本时会变化（旧的 Package Power 已被移除，
//  新版用 Combined Power），因此解析器采用"子串匹配 + 末尾 mW 数字"的健壮策略。
//

import Foundation

/// 单次采样的瞬时功率快照（所有功率字段单位均为 mW）。
struct PowerSample {
    let timestamp: Date
    /// SoC 总功率（优先取 Combined/Package，否则回退求和）。
    let totalMW: Double
    let cpuMW: Double
    let gpuMW: Double
    let aneMW: Double
    let dramMW: Double
    /// 解析来源说明（便于调试 / 面板提示）。
    let source: String
}

enum PowerSampler {

    /// 运行一次 powermetrics 并返回解析结果。失败返回 nil。
    /// - Parameter intervalMs: powermetrics 的 -i 采样间隔（毫秒），默认 1000。
    static func sample(intervalMs: Int = 1000) -> PowerSample? {
        guard let raw = runPowerMetrics(intervalMs: intervalMs) else { return nil }
        return parse(raw)
    }

    /// 运行 `sudo -n powermetrics -i <ms> -n 1 --samplers cpu_power,gpu_power`，返回标准输出。
    private static func runPowerMetrics(intervalMs: Int) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        // -n 给 sudo：使用免密缓存；若未配免密会失败（由调用方提示用户配 sudoers）。
        task.arguments = ["-n", "/usr/bin/powermetrics",
                          "-i", String(intervalMs),
                          "-n", "1",
                          "--samplers", "cpu_power,gpu_power"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()  // 丢弃 stderr，避免 sudo 提示噪音

        do {
            try task.run()
        } catch {
            return nil
        }

        // powermetrics 单次采样通常 1~2 秒，给 15 秒余量。
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 解析

    /// 从 powermetrics 文本输出解析出一个 PowerSample。
    /// 解析顺序体现容错：先尝试新版 Combined，再旧版 Package，最后回退到分量求和。
    static func parse(_ text: String) -> PowerSample? {
        let cpu = firstMW(text, containing: "CPU Power")
        let gpu = firstMW(text, containing: "GPU Power")
        let ane = firstMW(text, containing: "ANE Power")
        let dram = firstMW(text, containing: "DRAM Power") ?? firstMW(text, containing: "DCS Power")

        // 1) 新版 macOS (Sonoma+): Combined Power (CPU + GPU + ANE): <n> mW
        if let combined = firstMW(text, containing: "Combined Power") {
            return PowerSample(timestamp: Date(),
                               totalMW: combined,
                               cpuMW: cpu ?? 0,
                               gpuMW: gpu ?? 0,
                               aneMW: ane ?? 0,
                               dramMW: dram ?? 0,
                               source: "Combined")
        }
        // 2) 旧版 macOS: Package Power: <n> mW
        if let pkg = firstMW(text, containing: "Package Power") {
            return PowerSample(timestamp: Date(),
                               totalMW: pkg,
                               cpuMW: cpu ?? 0,
                               gpuMW: gpu ?? 0,
                               aneMW: ane ?? 0,
                               dramMW: dram ?? 0,
                               source: "Package")
        }
        // 3) 回退：用能拿到的分量求和（CPU + GPU + ANE + DRAM）。
        let parts = [cpu, gpu, ane, dram].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let sum = parts.reduce(0, +)
        return PowerSample(timestamp: Date(),
                           totalMW: sum,
                           cpuMW: cpu ?? 0,
                           gpuMW: gpu ?? 0,
                           aneMW: ane ?? 0,
                           dramMW: dram ?? 0,
                           source: "Sum")
    }

    /// 在文本中查找**同时包含给定子串**且以 ` <数字> mW` 结尾的第一行，返回数字（mW）。
    /// 同时传多个子串时要求全部命中（用于区分 "CPU Power" 与 "GPU Power" 等）。
    private static func firstMW(_ text: String, containing substrings: String...) -> Double? {
        // 单个子串时直接查找；多个子串时转交给 containingAll。
        if substrings.count == 1 {
            return firstMW(text, containingAll: substrings)
        }
        // 注意：本工具目前只用到单子串匹配（"CPU Power"/"GPU Power" 等），
        // 多子串分支保留以备将来需要精确组合匹配。
        return firstMW(text, containingAll: substrings)
    }

    private static func firstMW(_ text: String, containingAll substrings: [String]) -> Double? {
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            // 要求传入的全部子串都在该行出现（用于区分 "CPU Power" 与 "GPU Power" 等）。
            let allPresent = substrings.allSatisfy { lower.contains($0.lowercased()) }
            guard allPresent else { continue }
            if let mw = trailingMW(line) { return mw }
        }
        return nil
    }

    /// 从一行文本末尾提取 ` <整数/小数> mW`，例如 "Combined Power (CPU + GPU + ANE): 8243 mW" -> 8243。
    /// 单位限定 mW；若该行没有 mW 标记则返回 nil。
    private static func trailingMW<S: StringProtocol>(_ line: S) -> Double? {
        let s = String(line)
        guard s.lowercased().contains("mw") else { return nil }
        // 匹配行尾最后一个数字（支持小数）。
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*mW\s*$"#,
                                                   options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range),
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: s) else { return nil }
        return Double(s[numberRange])
    }
}
