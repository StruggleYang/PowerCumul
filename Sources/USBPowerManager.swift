//
//  USBPowerManager.swift
//  PowerCumul
//
//  USB 外设电源开关（uhubctl 直连）。运行时 Process 调用外部 uhubctl 属纯聚合，
//  不内嵌其二进制（GPL 义务只约束分发物本身）；检测不到时由 UI 引导 `brew install uhubctl`。
//
//  硬件语义（uhubctl 术语，实测于 2.6.0）：
//  - ppps   = per-port power switching，端口独立供电 → 唯一纳入管理的 hub 类型
//  - ganged = 整组通断 → 默认排除（断一口连带断一组），设置里可实验性显示
//  - 05ac (Apple 内置) 实测假报 ppps 且写操作会经 USB3 双胞胎联动误伤相邻 hub → 直接排除
//  - 假支持校验：hub 首次出现时试关一个空闲口并回读（结束必恢复供电），
//    状态未变 → 判该 hub 不可控并持久隐藏（防 Apple 内置口这类坑进 UI）
//
//  端口持久身份 = hubVID:hubPID#portNumber；location（如 "2-1"）系统重枚举后会变，
//  每次扫描动态重绑，勿持久化。用户命名/锁定/忽略/已见端口存
//  ~/Library/Application Support/PowerCumul/usbports.json。
//
//  中文/特殊字符：Process 直传 argv 无编码问题；全程数组传参，禁止拼接 shell 字符串。
//  无后台轮询：状态仅在面板可见时由调用方按 ≥2s 节流拉取（单次 uhubctl ~100ms）。
//

import Foundation

// MARK: - 数据模型

struct USBPort {
    /// 稳定身份: "hubVID:hubPID#portNumber"，持久化 key。
    let id: String
    /// 运行时解析的 uhubctl location（如 "2-1"），勿持久化。
    let location: String
    let portNumber: Int
    /// hub 厂商:产品 ID（"05e3:0610"），向导向导展示用。
    let hubID: String
    /// hub 型号名（uhubctl 方括号内文本），向导向导展示用。
    let hubName: String
    /// 用户命名（未命名时为空，UI 显示占位名）。
    var userLabel: String
    var locked: Bool
    /// 附着设备描述（uhubctl 端口行方括号内容），无设备为 nil。
    var attachedDevice: String?
    /// true = 供电中。
    var power: Bool
}

extension USBPort {

    /// 附着设备是否为存储/键鼠类（断电防误触名单，规格 §2）。
    var hasSensitiveDevice: Bool {
        attachedDevice?.range(of: "storage|disk|ssd|keyboard|mouse|trackpad",
                              options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 显示名：用户命名优先，未命名回退设备名/占位端口号。
    var displayName: String {
        userLabel.isEmpty
            ? (attachedDevice ?? L10n.tr("usbPower.unnamed", "端口 %d", portNumber))
            : userLabel
    }
}

// MARK: - 管理器

final class USBPowerManager {

    static let shared = USBPowerManager()

    /// uhubctl 输出解析（单元口径）：hub 行 / 端口行前缀。
    private static let hubLinePrefix = "Current status for hub "
    private static let portLinePrefix = "Port "

    /// 假支持/内置 hub 黑名单：05ac (Apple) 假报 ppps 且 USB3 联动误伤，见文件头。
    private static let excludedHubVendor = "05ac"

    /// 进程超时兜底（uhubctl 正常 ~100ms，设备异常时不至于卡死调用线程）。
    private static let processTimeout: TimeInterval = 5

    // 串行队列：uhubctl 子进程调用与持久化状态全部在此排队，避免并发重入。
    private let queue = DispatchQueue(label: "powercumul.usbpower", qos: .utility)

    // MARK: uhubctl 可用性

    private var resolvedPath: String?
    private var pathProbed = false

    /// PATH 探测：常见安装位置 + $PATH 逐目录查（Finder 启动的 app PATH 残缺，
    /// 候选列表兜底 Homebrew 两个前缀）。
    static func probeUhubctlPath() -> String? {
        var candidates = ["/opt/homebrew/bin/uhubctl", "/usr/local/bin/uhubctl", "/usr/bin/uhubctl"]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            candidates += pathEnv.split(separator: ":").map { $0 + "/uhubctl" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// uhubctl 是否可用（懒探测一次并缓存）。
    var isUhubctlAvailable: Bool {
        queue.sync { uhubctlPath() != nil }
    }

    /// Homebrew 可执行文件位置（Apple Silicon / Intel 两个前缀）。
    static func detectBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // MARK: 引导安装（uhubctl 未装时的一键安装）

    enum UhubctlInstallResult {
        case installed
        case brewMissing
        case failed(String)
    }

    /// 经 Homebrew 后台安装 uhubctl。装的是官方 bottle（uhubctl 公式无依赖），
    /// 跳过 brew 自更新（HOMEBREW_NO_AUTO_UPDATE，否则老机器首次可能拖几分钟）。
    /// 完成后重探路径并回调（调用方负责回主线程刷 UI）。
    func installUhubctl(completion: @escaping (UhubctlInstallResult) -> Void) {
        guard let brew = Self.detectBrew() else {
            completion(.brewMissing)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = ["install", "--quiet", "uhubctl"]
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                completion(.failed(error.localizedDescription))
                return
            }
            // 看门狗：正常装 bottle 秒级~几十秒，5 分钟兜底防 brew 卡死。
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            self?.invalidateUhubctlProbe()
            let out = String(data: data, encoding: .utf8) ?? ""
            guard p.terminationStatus == 0, self?.isUhubctlAvailable == true else {
                let tail = out.split(separator: "\n").suffix(3).joined(separator: "\n")
                completion(.failed(tail.isEmpty ? "brew exited \(p.terminationStatus)" : tail))
                return
            }
            completion(.installed)
        }
    }

    /// 解析 uhubctl 绝对路径（queue 内调用）。线程安全靠 queue 串行。
    private func uhubctlPath() -> String? {
        if pathProbed { return resolvedPath }
        resolvedPath = Self.probeUhubctlPath()
        pathProbed = true
        return resolvedPath
    }

    /// 探测缓存失效（uhubctl 刚装好/升级后可重新发现）。
    func invalidateUhubctlProbe() {
        queue.async { [weak self] in
            self?.pathProbed = false
            self?.resolvedPath = nil
        }
    }

    // MARK: 持久化（usbports.json）

    private struct PersistedPort: Codable {
        let id: String
        var label: String = ""
        var locked: Bool = false
    }

    /// 结构沿用 Application Support 存储惯例；ports 外的键均为增量扩展。
    private struct Store: Codable {
        var ports: [PersistedPort] = []
        /// 用户忽略的端口 id（不再显示）。
        var ignored: [String] = []
        /// 已向导过/已跳过命名的端口 id（避免重复弹向导）。
        var seen: [String] = []
        /// 假支持校验不通过的 hub（vid:pid），持久隐藏。
        var badHubs: [String] = []
        /// 假支持校验通过的 hub（vid:pid），避免每次启动重复试探。
        var verifiedHubs: [String] = []
    }

    private var store = Store() {
        didSet { saveStore() }
    }

    private var storeURL: URL {
        EnergyStore.dataDirectory.appendingPathComponent("usbports.json")
    }

    private func saveStore() {
        let url = storeURL
        let snapshot = store
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadStore() {
        guard let data = try? Data(contentsOf: storeURL),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = s
    }

    // MARK: - 扫描

    /// 枚举可控端口。同步（uhubctl 一次 ~100ms；含首见 hub 假支持校验时更久），
    /// 内部串行排队。返回按 hub → 端口号排序的已过滤列表。
    func scan() -> [USBPort] {
        queue.sync { _scan() }
    }

    /// 面板/菜单用：缓存新鲜（maxAge 内）直接返回，否则同步重扫。
    func scanCached(maxAge: TimeInterval) -> [USBPort] {
        queue.sync {
            if Date().timeIntervalSince(lastScanDate) < maxAge { return lastScan }
            return _scan()
        }
    }

    /// 菜单/面板共享的最近一次扫描结果（queue 内更新）。
    private var lastScan: [USBPort] = []
    private var lastScanDate = Date.distantPast

    /// 单个 uhubctl 全量扫描 + 过滤 + 合并持久化数据（queue 内调用）。
    private func _scan() -> [USBPort] {
        guard let uhubctl = uhubctlPath() else { return [] }
        let (ok, out, _) = runProcess(uhubctl, [], timeout: Self.processTimeout)
        guard ok else { lastScan = []; lastScanDate = Date(); return [] }

        let hubs = Self.parseHubs(out)
        var result: [USBPort] = []
        var newBad: [String] = []
        var newVerified: [String] = []

        for hub in hubs {
            let vendor = String(hub.vidPid.prefix(4))
            // 内置 Apple hub 直接排除（规格硬规则，先于假支持校验）。
            if vendor == Self.excludedHubVendor { continue }
            // ganged 默认排除；设置里开了实验性开关才纳入。
            if hub.smart == "ganged" && !prefs.showGangedUSB { continue }
            // 假支持校验不通过的历史 hub 隐藏。
            if store.badHubs.contains(hub.vidPid) { continue }
            // 首见 hub：试关一个空闲口回读（结束恢复供电），不可控则标记隐藏。
            if !store.verifiedHubs.contains(hub.vidPid) {
                if probeHubControllable(hub) {
                    newVerified.append(hub.vidPid)
                } else {
                    newBad.append(hub.vidPid)
                    continue
                }
            }

            for p in hub.ports {
                let id = "\(hub.vidPid)#\(p.number)"
                if store.ignored.contains(id) { continue }
                let persisted = store.ports.first { $0.id == id }
                result.append(USBPort(
                    id: id,
                    location: hub.location,
                    portNumber: p.number,
                    hubID: hub.vidPid,
                    hubName: hub.name,
                    userLabel: persisted?.label ?? "",
                    locked: persisted?.locked ?? false,
                    attachedDevice: p.attachedDevice,
                    power: p.power))
            }
        }
        if !newBad.isEmpty { store.badHubs.append(contentsOf: newBad) }
        if !newVerified.isEmpty { store.verifiedHubs.append(contentsOf: newVerified) }
        result.sort { ($0.hubID, $0.portNumber) < ($1.hubID, $1.portNumber) }
        lastScan = result
        lastScanDate = Date()
        return result
    }

    // MARK: - 假支持校验

    /// 试关一个空闲口并回读；结束无条件恢复供电。状态未变 → 不可控。
    /// 只选无附着设备的口试（有设备的口断电=拔线，不能拿来试探）；
    /// 全部端口被占用时放弃试探、按可控处理（保守：宁可显示不可控的，也不错杀可控的）。
    private func probeHubControllable(_ hub: ScannedHub) -> Bool {
        guard let target = hub.ports.first(where: { $0.attachedDevice == nil }) else { return true }
        guard let uhubctl = uhubctlPath() else { return true }
        let args = ["-l", hub.location, "-p", String(target.number)]
        // 关 → 回读（"New status" 行含 " off" 才算真的断掉了）。
        let (okOff, outOff, _) = runProcess(uhubctl, args + ["-a", "off"], timeout: Self.processTimeout)
        guard okOff else { return false }   // 写被拒 → 假支持
        let nowOff = Self.newStatusPowerOff(outOff, port: target.number)
        // 无论校验结果如何，恢复供电。
        _ = runProcess(uhubctl, args + ["-a", "on"], timeout: Self.processTimeout)
        return nowOff
    }

    /// 从写操作的输出解析回读状态：最后一个 "New status" 块的目标端口行含 " off"。
    /// 端口行带两格前导缩进，比前缀前先 trim。
    static func newStatusPowerOff(_ out: String, port: Int) -> Bool {
        let marker = "New status for hub "
        guard let range = out.range(of: marker, options: .backwards) else { return false }
        let tail = String(out[range.lowerBound...])
        let prefix = "\(portLinePrefix)\(port):"
        let line = tail.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) } ?? ""
        return line.contains(" off")
    }

    // MARK: - 操作

    struct USBPowerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 通断电。失败 throws（hub 掉线/显示器休眠等），调用方决定 UI 呈现（行内离线态，不弹窗）。
    func setPower(_ port: USBPort, on: Bool) throws {
        try queue.sync {
            guard let uhubctl = uhubctlPath() else {
                throw USBPowerError(message: "uhubctl not found")
            }
            let args = ["-l", port.location, "-p", String(port.portNumber),
                        "-a", on ? "on" : "off"]
            let (ok, _, err) = runProcess(uhubctl, args, timeout: Self.processTimeout)
            guard ok else {
                throw USBPowerError(message: err.isEmpty ? "uhubctl 写入失败" : err)
            }
        }
    }

    /// 翻转。显式读当前态（不用缓存，避免陈旧状态反向操作）。
    func toggle(_ port: USBPort) throws {
        let current = try readPower(port)
        try setPower(port, on: !current)
    }

    /// 读单个端口当前供电态。
    func readPower(_ port: USBPort) throws -> Bool {
        try queue.sync {
            guard let uhubctl = uhubctlPath() else {
                throw USBPowerError(message: "uhubctl not found")
            }
            let args = ["-l", port.location, "-p", String(port.portNumber)]
            let (ok, out, err) = runProcess(uhubctl, args, timeout: Self.processTimeout)
            guard ok else {
                throw USBPowerError(message: err.isEmpty ? "uhubctl read failed" : err)
            }
            guard let power = Self.parsePortPower(out, port: port.portNumber) else {
                throw USBPowerError(message: "unparseable uhubctl output")
            }
            return power
        }
    }

    /// 闪烁定位（-a flash，uhubctl 自带节奏；结束后自动恢复供电）。
    func flash(_ port: USBPort) {
        queue.async { [weak self] in
            guard let self, let uhubctl = self.uhubctlPath() else { return }
            _ = self.runProcess(uhubctl,
                                ["-l", port.location, "-p", String(port.portNumber), "-a", "flash"],
                                timeout: 15)   // flash 默认 2s 延迟，放宽超时
        }
    }

    // MARK: - 命名 / 锁定 / 忽略 / 已见

    func setLabel(_ port: USBPort, label: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.upsert(id: port.id) { $0.label = label }
        }
    }

    func setLocked(_ port: USBPort, locked: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.upsert(id: port.id) { $0.locked = locked }
        }
    }

    func setIgnored(_ port: USBPort, ignored: Bool) {
        setIgnored(id: port.id, ignored: ignored)
    }

    /// USB 设置对话框按 id 恢复忽略口（手里只有 id，没有完整 USBPort）。
    func setIgnored(id: String, ignored: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if ignored {
                if !self.store.ignored.contains(id) { self.store.ignored.append(id) }
            } else {
                self.store.ignored.removeAll { $0 == id }
            }
        }
    }

    /// 向导处理过（含跳过）的端口标记为已见，不再重复触发。
    func markSeen(_ port: USBPort) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.store.seen.contains(port.id) { self.store.seen.append(port.id) }
        }
    }

    func hasBeenSeen(_ id: String) -> Bool {
        queue.sync { store.seen.contains(id) || store.ignored.contains(id) }
    }

    /// 已忽略端口（USB 设置对话框展示）。
    func ignoredPorts() -> [(id: String, label: String)] {
        queue.sync {
            store.ignored.map { id in
                (id, store.ports.first { $0.id == id }?.label ?? "")
            }
        }
    }

    /// 是否用过本功能（向导过/命名过）——决定面板空态时显示提示还是整块隐藏。
    func hasHistory() -> Bool {
        queue.sync { !store.seen.isEmpty || !store.ports.isEmpty }
    }

    private func upsert(id: String, _ mutate: (inout PersistedPort) -> Void) {
        if let idx = store.ports.firstIndex(where: { $0.id == id }) {
            mutate(&store.ports[idx])
        } else {
            var p = PersistedPort(id: id)
            mutate(&p)
            store.ports.append(p)
        }
    }

    // MARK: - uhubctl 输出解析

    /// 扫描输出的 hub 中间表示（含未过滤的 smart 类型，供 ganged 判断与探测）。
    struct ScannedHub {
        let location: String
        let vidPid: String
        let name: String
        /// "ppps" / "ganged" / 其他
        let smart: String
        var ports: [ScannedPort] = []
    }

    struct ScannedPort {
        let number: Int
        let power: Bool
        let attachedDevice: String?
    }

    /// 解析 `uhubctl` 无参数输出。行格式（实测 2.6.0）：
    ///   Current status for hub 2-1 [05e3:0610 GenesysLogic USB2.1 Hub, USB 2.10, 4 ports, ppps]
    ///     Port 1: 0100 power
    ///     Port 2: 0503 power highspeed enable connect [0c45:636f Sonix ... Camera 2K]
    /// 断电态端口行: "Port 3: 0000 off"。供电判定: 含 "power"；含 " off" 为断电；
    /// 两者皆无（USB3 链路态等中间输出）按供电处理（保守，避免误报断电）。
    static func parseHubs(_ out: String) -> [ScannedHub] {
        var hubs: [ScannedHub] = []
        for rawLine in out.split(separator: "\n").map(String.init) {
            if rawLine.hasPrefix(hubLinePrefix) {
                if let h = parseHubLine(rawLine) { hubs.append(h) }
            } else if rawLine.contains("Port ") {
                // 端口行属于最近一个 hub（USB3 双胞胎时同一位置行会有两条 Port 行，各归各 hub）。
                guard var hub = hubs.popLast() else { continue }
                if let p = parsePortLine(rawLine) { hub.ports.append(p) }
                hubs.append(hub)
            }
        }
        return hubs
    }

    private static func parseHubLine(_ line: String) -> ScannedHub? {
        guard let bracket = line.range(of: "["),
              let close = line.range(of: "]", options: .backwards),
              let locRange = line.range(of: #"hub (\S+)"#, options: .regularExpression) else { return nil }
        let location = String(line[locRange].dropFirst(4))   // 去掉 "hub "
        let inner = String(line[bracket.upperBound..<close.lowerBound])
        let segs: [String] = inner.split(separator: ",").map {
            String($0).trimmingCharacters(in: CharacterSet.whitespaces)
        }
        guard let first = segs.first else { return nil }
        let vidPid = String(first.split(separator: " ").first.map(String.init) ?? "")
        guard vidPid.count == 9, vidPid.contains(":") else { return nil }   // "05e3:0610"
        let name = String(first.dropFirst(vidPid.count + 1))
        let smart: String = segs.first(where: { $0 == "ppps" || $0 == "ganged" || $0 == "none" }) ?? "unknown"
        return ScannedHub(location: location, vidPid: vidPid.lowercased(),
                          name: name, smart: smart)
    }

    private static func parsePortLine(_ line: String) -> ScannedPort? {
        guard let m = line.range(of: #"Port (\d+): "#, options: .regularExpression) else { return nil }
        let numStr = line[m].dropFirst(5).dropLast(2)   // "Port N: " → N
        guard let number = Int(numStr) else { return nil }
        var body = String(line[m.upperBound...])
        var attached: String? = nil
        if let bOpen = body.firstIndex(of: "["), let bClose = body.firstIndex(of: "]"), bOpen < bClose {
            let dev = String(body[body.index(after: bOpen)..<bClose])
            // 设备描述 = 去掉 "vid:pid " 前缀后的文本。
            let toks = dev.split(separator: " ", maxSplits: 1)
            attached = toks.count == 2 ? String(toks[1]) : dev
            body = String(body[..<bOpen])
        }
        let power: Bool
        if body.range(of: " off") != nil { power = false }
        else if body.contains("power") { power = true }
        else { power = true }
        return ScannedPort(number: number, power: power, attachedDevice: attached)
    }

    /// 单端口查询输出 → 供电态（找不到该端口行返回 nil）。行首缩进先 trim。
    static func parsePortPower(_ out: String, port: Int) -> Bool? {
        let prefix = "\(portLinePrefix)\(port):"
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            if line.range(of: " off") != nil { return false }
            return true   // "power" 或 USB3 链路态（保守按供电处理，见 parsePortLine 注释）
        }
        return nil
    }

    // MARK: - 进程执行

    /// 同步跑子进程，带超时看门狗（超时 kill，防设备异常卡死串行队列）。
    /// 先排空管道再收退出码——顺序反了在大输出时会因管道写满死锁。
    private func runProcess(_ path: String, _ args: [String],
                            timeout: TimeInterval) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args   // 数组直传 argv：设备名含中文/空格均无编码问题
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (false, "", error.localizedDescription) }

        // 看门狗：超时终止。uhubctl 正常百毫秒级，只在设备异常时兜底。
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // 读到 EOF 即进程退出/被杀，readDataToEndOfFile 本身就是同步点。
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return (p.terminationStatus == 0,
                String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? "")
    }

    // MARK: - 依赖

    /// ganged 实验性开关（设置里勾选）。
    private let prefs = Preferences()

    private init() {
        loadStore()
    }
}
