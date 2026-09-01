//
//  PowerSampler.swift
//  PowerCumul
//
//  调用 `sudo -n powermetrics` 采样瞬时功率，并容错解析输出。
//  powermetrics 输出字段在跨 macOS 版本时会变化（旧的 Package Power 已被移除，
//  新版用 Combined Power），因此解析器采用"子串匹配 + 末尾 mW 数字"的健壮策略。
//

import Foundation

/// 单个进程的能耗行：来自 "--show-process-energy" 的 Energy Impact 列。
/// Apple 的加权代理分（含 CPU/GPU/IO/网络），无官方物理单位，
/// 只用其相对占比做归因（app 分数 / 全部分数 × 桶实测 Wh）。
struct ProcessEnergyRow {
    let name: String
    let score: Double
}

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
    /// 本采样块内各进程的 Energy Impact（tasks 表为空时为空数组，不影响功率主流程）。
    let processEnergy: [ProcessEnergyRow]

    /// 返回一个所有功率字段都乘以校正系数的新采样。
    /// 用于把 SoC 功耗估算成整机墙功耗（用户可用智能插座标定系数）。
    /// processEnergy 是相对占比，不参与校正。
    func applying(correctionFactor: Double) -> PowerSample {
        PowerSample(timestamp: timestamp,
                    totalMW: totalMW * correctionFactor,
                    cpuMW: cpuMW * correctionFactor,
                    gpuMW: gpuMW * correctionFactor,
                    aneMW: aneMW * correctionFactor,
                    dramMW: dramMW * correctionFactor,
                    source: source,
                    processEnergy: processEnergy)
    }
}

enum PowerSampler {

    /// 运行一次 powermetrics 并返回解析结果。失败返回 nil。
    /// - Parameter intervalMs: powermetrics 的 -i 采样间隔（毫秒），默认 1000。
    static func sample(intervalMs: Int = 1000) -> PowerSample? {
        guard let raw = runPowerMetrics(intervalMs: intervalMs) else { return nil }
        return parse(raw)
    }

    /// 运行 `sudo -n powermetrics -i <ms> -n 1 --samplers cpu_power,gpu_power,tasks
    /// --show-process-energy`，返回标准输出。tasks + show-process-energy 提供
    /// "Running tasks" 表（末列 Energy Impact）；功率段输出与不加时一致。
    private static func runPowerMetrics(intervalMs: Int) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        // -n 给 sudo：使用免密缓存；若未配免密会失败（由调用方提示用户配 sudoers）。
        task.arguments = ["-n", "/usr/bin/powermetrics",
                          "-i", String(intervalMs),
                          "-n", "1",
                          "--samplers", "cpu_power,gpu_power,tasks",
                          "--show-process-energy"]

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
    /// 进程能耗表独立解析，失败不影响功率主流程。
    static func parse(_ text: String) -> PowerSample? {
        let cpu = firstMW(text, containing: "CPU Power")
        let gpu = firstMW(text, containing: "GPU Power")
        let ane = firstMW(text, containing: "ANE Power")
        let dram = firstMW(text, containing: "DRAM Power") ?? firstMW(text, containing: "DCS Power")
        let processEnergy = parseProcessEnergy(text)

        // 1) 新版 macOS (Sonoma+): Combined Power (CPU + GPU + ANE): <n> mW
        //    注意 Combined 不含 DRAM，空闲时 CPU/GPU/ANE 都趋近 0 而内存仍在耗电，
        //    把 DRAM Power 计入总量，空闲段才不至于整段记 0。
        if let combined = firstMW(text, containing: "Combined Power") {
            return PowerSample(timestamp: Date(),
                               totalMW: combined + (dram ?? 0),
                               cpuMW: cpu ?? 0,
                               gpuMW: gpu ?? 0,
                               aneMW: ane ?? 0,
                               dramMW: dram ?? 0,
                               source: "Combined",
                               processEnergy: processEnergy)
        }
        // 2) 旧版 macOS: Package Power: <n> mW
        if let pkg = firstMW(text, containing: "Package power") {
            return PowerSample(timestamp: Date(),
                               totalMW: pkg,
                               cpuMW: cpu ?? 0,
                               gpuMW: gpu ?? 0,
                               aneMW: ane ?? 0,
                               dramMW: dram ?? 0,
                               source: "Package",
                               processEnergy: processEnergy)
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
                           source: "Sum",
                           processEnergy: processEnergy)
    }

    // MARK: - 进程能耗解析

    /// 不参与统计的伪进程：测量工具自身开销、表尾聚合行（ALL_TASKS 为整机汇总，
    /// 分数不等于各行之和，留在归一化分母里会把占比压低约一半）、已退出任务。
    private static let excludedProcessNames: Set<String> = ["powermetrics", "sudo", "DEAD_TASKS", "ALL_TASKS"]

    /// 解析 "*** Running tasks ***" 表（--show-process-energy 输出，末列为 Energy Impact）。
    /// 实测行格式（macOS 26 / 25G83）：
    /// `Name(可含空格/括号)  ID  CPUms/s  User%  D1  D2  W1  W2  EnergyImpact`
    /// 名称列之后全部是数字列 → 从右往左剥离数字 token，剩余前缀即进程名。
    /// 部分老版本输出独立的 "**** Process Energy report ****" 表，列结构相同，
    /// 因此按「表头含 Energy Impact + 空行结束」识别，不依赖段落标题。
    private static func parseProcessEnergy(_ text: String) -> [ProcessEnergyRow] {
        var rows: [ProcessEnergyRow] = []
        var headerIndex = -1
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        // 先定位表头行（含 Energy Impact 列名的行），跳过其之前的所有内容。
        for (i, raw) in lines.enumerated() {
            if raw.contains("Energy Impact") {
                headerIndex = i
                break
            }
        }
        guard headerIndex >= 0 else { return rows }

        for raw in lines[(headerIndex + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { break }   // 空行 = 表结束
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3 else { continue }
            // 从右剥离数字列；停在首个非数字 token 上，其下标即名称的最后一个词。
            var idx = tokens.count - 1
            while idx >= 0, Double(tokens[idx]) != nil { idx -= 1 }
            guard idx >= 0, idx + 2 < tokens.count else { continue }   // 需要名称 + 至少 2 个数字列
            let name = tokens[0...idx].joined(separator: " ")
            guard let score = Double(tokens.last!), !excludedProcessNames.contains(name) else { continue }
            rows.append(ProcessEnergyRow(name: name, score: score))
        }
        return rows
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
