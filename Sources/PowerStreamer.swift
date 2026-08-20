//
//  PowerStreamer.swift
//  PowerCumul
//
//  连续流式采样器：powermetrics 常驻进程（不带 -n），逐块解析输出。
//
//  相比旧的「每 5s spawn 一次 -n 1」方案：
//  - 100% 时间覆盖：每个采样块就是该窗口内的平均功率，能量积分无外推误差
//  - 无进程创建开销（旧方案每天 17280 次 spawn + sudo 握手，约占 0.1 核）
//
//  工程要点：
//  - stderr 必须持续排空，否则管道缓冲写满会阻塞 powermetrics
//  - 看门狗：进程退出后延迟重启；sudo 权限缺失时不重启（等授权后由外部再 start）
//  - 输出按 "*** Sampled system activity" 分块，攒齐一块解析一次
//

import Foundation

final class PowerStreamer {

    /// 每解析出一个采样块回调一次（在内部串行队列，非主线程）。
    var onSample: ((PowerSample) -> Void)?

    private let queue = DispatchQueue(label: "com.powercumul.powerstreamer")
    private var process: Process?
    private var lineBuffer: [String] = []
    private var restartWork: DispatchWorkItem?
    private(set) var intervalMs: Int

    init(intervalMs: Int = 5000) {
        self.intervalMs = intervalMs
    }

    // MARK: - 生命周期

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.process == nil else { return }   // 已在运行
            self.spawn()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.restartWork?.cancel()
            self.restartWork = nil
            if let p = self.process, p.isRunning {
                p.terminate()
            }
            self.process = nil
            self.lineBuffer = []
        }
    }

    /// 修改采样间隔并重启流（间隔设置变化时调用）。
    func restart(intervalMs: Int) {
        self.intervalMs = intervalMs
        stop()
        // 等旧进程退出后再拉起新进程，避免两个流并发写状态。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    // MARK: - 进程管理

    private func spawn() {
        let p = Process()
        p.launchPath = "/usr/bin/sudo"
        p.arguments = ["-n", "/usr/bin/powermetrics",
                       "-i", String(intervalMs),
                       "--samplers", "cpu_power,gpu_power"]
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        // 持续排空 stderr（丢弃内容），防止缓冲写满阻塞子进程。
        stderr.fileHandleForReading.readabilityHandler = { _ in }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF：进程退出。
                handle.readabilityHandler = nil
                self?.queue.async { self?.handleEOF() }
                return
            }
            if let text = String(data: chunk, encoding: .utf8) {
                self?.queue.async { self?.ingest(text) }
            }
        }
        do {
            try p.run()
            process = p
            lineBuffer = []
        } catch {
            scheduleRestart()
        }
    }

    private func handleEOF() {
        process = nil
        scheduleRestart()
    }

    /// 看门狗：延迟重启；权限缺失时放弃（授权成功后外部会重新 start）。
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard PrivilegeManager.currentStatus() == .granted else { return }
            self?.queue.async { self?.spawn() }
        }
        restartWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - 输出解析

    /// 按 "*** Sampled system activity" 头分行分块：见到新块头时解析上一块。
    private func ingest(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("Sampled system activity") {
                flushBuffer()
            }
            lineBuffer.append(String(line))
        }
    }

    private func flushBuffer() {
        guard !lineBuffer.isEmpty else { return }
        let block = lineBuffer.joined(separator: "\n")
        lineBuffer = []
        if let sample = PowerSampler.parse(block) {
            onSample?(sample)
        }
    }
}
