//
//  PanelController.swift
//  PowerCumul
//
//  状态栏图标的弹出面板（NSPopover 的 contentViewController）。
//  布局：实时功率 → 今日累计 kWh + 估算费用 → 24h 折线图 → 底部累计信息。
//  设置区：采样间隔 / 货币 / 电价 / 状态栏显示模式 / 开机自启。
//  全部文案走 NSLocalizedString（中英双语），数字按系统 locale 格式化。
//

import AppKit
import ServiceManagement

final class PanelController: NSViewController {

    // 顶部：实时功率
    private let powerLabel = NSTextField(labelWithString: "— W")
    private let detailLabel = NSTextField(labelWithString: "")

    // 中部：今日累计
    private let todayKwhLabel = NSTextField(labelWithString: "0.000 kWh")
    private let costLabel = NSTextField(labelWithString: "")

    // 图表
    private let chartView = ChartView()

    // 耗电应用 TOP 区块（区间与图表共用分段控件）
    private let topAppsHeader = NSTextField(labelWithString: "")
    private let topAppsNote = NSTextField(labelWithString: "")
    private let topAppsEmptyLabel = NSTextField(labelWithString: "")
    private var topAppRows: [TopAppRowView] = []
    private weak var processStoreRef: ProcessEnergyStore?
    private weak var chargeRef: ChargeController?
    /// 当前图表各柱对应的桶 key（与 chartView.data 平行），点击定位时按索引取桶。
    private var chartBucketKeys: [String] = []
    /// 点击图表选中的桶 key（nil = 跟随区间聚合）。
    private var selectedBucketKey: String?

    // 电池区块（仅笔记本显示；mini/台式机无电池 → 整体隐藏，布局零影响）
    private let batteryHeader = NSTextField(labelWithString: "")
    private let batteryStateLabel = NSTextField(labelWithString: "")
    private let batteryHealthLabel = NSTextField(labelWithString: "")

    // USB 开关区块（uhubctl 直连的外设通断电）。
    // 三态：无 uhubctl → 安装引导（一键 Homebrew 安装）；有但无可控口/历史 → 整块隐藏（零打扰）；
    // 用过但当前全部离线 → 一行空态提示。扫描 ≥2s 节流且仅在面板可见时发生（无后台轮询）。
    private let usbHeader = NSTextField(labelWithString: "")
    private let usbGuideLabel = NSTextField(labelWithString: "")
    private let usbInstallButton = NSButton(title: "", target: nil, action: nil)
    private let usbCopyButton = NSButton(title: "", target: nil, action: nil)
    private let usbEmptyLabel = NSTextField(labelWithString: "")
    private let usbRowsBox = NSStackView()
    private let usbGuideBox = NSStackView()
    private let usbBox = NSStackView()
    private var usbRows: [String: USBSwitchRowView] = [:]
    private var usbPinnedRows = Set<String>()
    private var usbLastScanAt = Date.distantPast
    private let usbManager = USBPowerManager.shared

    /// 引导卡片状态：idle 可安装 / installing 进行中 / brewMissing 转 brew.sh 引导 / failed 失败重试。
    private enum USBGuideState { case idle, installing, brewMissing, failed(String) }
    private var usbGuideState: USBGuideState = .idle

    // 底部
    private let totalLabel = NSTextField(labelWithString: "")
    private let uptimeLabel = NSTextField(labelWithString: "")
    private let estimateNote = NSTextField(labelWithString: "")
    private let rightClickHint = NSTextField(labelWithString: "")

    // 权限状态卡片
    private let privilegeBox = NSBox()
    private let privilegeLabel = NSTextField(labelWithString: "")
    private let grantButton = NSButton(title: "", target: nil, action: nil)

    // 图表时段切换（保留在主面板）
    private let chartRangeSelector = NSSegmentedControl()

    private let prefs: Preferences
    private weak var storeRef: EnergyStore?

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
        let stack = buildUI(in: container)
        // 面板高度按内容自适应：量出 stack 实际高度（宽 308 = 340 − 左右边距 16×2），
        // 容器高 = 内容高 + 上下边距 14×2。不再手填固定高度——固定值与内容不符时
        // NSStackView 会被钉死的上下边距逼着拉伸/压缩间距（表现为 CPU/GPU/ANE 行被挤到顶部等错位）。
        let contentHeight = stack.fittingSize.height
        container.frame.size.height = contentHeight + 28
        preferredContentSize = NSSize(width: 340, height: contentHeight + 28)
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 设置项已迁至独立设置窗口，主面板无需初始化设置控件。
        // USB 开关不依赖功率采样授权，冷打开面板就先刷一次。
        refreshUSBPorts()
    }

    // MARK: - 刷新

    func refresh(snapshot: Snapshot, sample: PowerSample?) {
        guard isViewLoaded else { return }

        let currentW = sample?.totalMW ?? snapshot.currentMW
        powerLabel.stringValue = "\(L10n.decimal(currentW / 1000, fractionDigits: 1)) \(tr("power.unit"))"

        if let s = sample {
            detailLabel.stringValue = "\(tr("power.cpu")) \(L10n.decimal(s.cpuMW / 1000, fractionDigits: 1)) · "
                + "\(tr("power.gpu")) \(L10n.decimal(s.gpuMW / 1000, fractionDigits: 1)) · "
                + "\(tr("power.ane")) \(L10n.decimal(s.aneMW / 1000, fractionDigits: 1)) \(tr("power.unit"))"
        } else {
            detailLabel.stringValue = ""
        }

        todayKwhLabel.stringValue = "\(L10n.decimal(snapshot.todayWh / 1000, fractionDigits: 3)) \(tr("kWh.unit"))"

        // 费用展示累计电费（自首次运行起）：今日费用在空闲量级下只有几分钱，
        // 2 位小数下恒为 0.00，没有信息量。累计 + 3 位小数能看出增长。
        let cost = snapshot.totalWh / 1000 * prefs.pricePerKWh
        costLabel.stringValue = L10n.tr("cost.label", "累计 %@ %@/kWh",
                                        L10n.cumulativeCost(cost, currency: prefs.currency),
                                        L10n.decimal(prefs.pricePerKWh, fractionDigits: 2))

        let df = DateFormatter()
        df.locale = Locale.current
        df.dateStyle = .medium
        df.timeStyle = .short
        totalLabel.stringValue = L10n.tr("footer.total", "累计 %@ kWh（自 %@）",
                                         L10n.decimal(snapshot.totalWh / 1000, fractionDigits: 3),
                                         df.string(from: snapshot.createdAt))

        uptimeLabel.stringValue = formatDuration(Date().timeIntervalSince(snapshot.createdAt))
        // 标注动态化：系数>1 显示"已校正 ×N.NN"，否则提示"SoC 估算值（非整机墙功耗）"。
        if prefs.powerCorrectionFactor > 1.001 {
            estimateNote.stringValue = L10n.tr("footer.calibrated", "已校正墙功耗 ×%.2f",
                                               prefs.powerCorrectionFactor)
        } else {
            estimateNote.stringValue = tr("footer.socEstimate")
        }

        // 图表数据按当前区间切换：24h 用小时桶（值=Wh≈该小时平均W），
        // 7天/30天 用天桶（值=kWh，按桶大小放大到可比刻度）。
        // 同时记录各柱的桶 key，供图表点击定位 TOP 列表。
        switch prefs.chartRange {
        case .hours24:
            let recent = snapshot.hours.suffix(24)
            chartBucketKeys = recent.map { $0.bucketKey }
            chartView.data = recent.map { bucket in
                let hour = String(bucket.bucketKey.suffix(2))
                return (label: "\(hour)", value: bucket.wh)   // Wh ≈ 平均W
            }
            chartView.unitLabel = tr("power.unit")
        case .days7, .days30:
            let count = prefs.chartRange == .days7 ? 7 : 30
            let recent = snapshot.days.suffix(count)
            chartBucketKeys = recent.map { $0.bucketKey }
            let df = DateFormatter()
            df.locale = Locale.current
            df.dateFormat = "MM-dd"
            // 天桶存的就是 Wh，直接用（之前误除以 1000 导致值近乎为 0、图表看不见）。
            chartView.data = recent.map { bucket in
                let date = parseDayKey(bucket.bucketKey) ?? Date()
                return (label: df.string(from: date), value: bucket.wh)
            }
            chartView.unitLabel = tr("power.unit")
        }
        // 选中索引随数据窗口滑动作位置映射：索引越界即视为取消选中。
        if let idx = chartView.selectedIndex, idx >= chartBucketKeys.count {
            chartView.clearSelection()
            selectedBucketKey = nil
        } else {
            selectedBucketKey = chartView.selectedIndex.flatMap { chartBucketKeys[$0] }
        }

        let status = PrivilegeManager.currentStatus()
        privilegeBox.isHidden = status != .missing
        if status == .missing {
            privilegeLabel.stringValue = tr("privilege.warning")
        }

        refreshTopApps(snapshot: snapshot)
        refreshBattery()
        refreshUSBPorts()
    }

    // MARK: - 电池

    /// 刷新电池区块。每次面板刷新都重新读一次（IOKit 纯读，开销微秒级），
    /// 这样即使功率采样未授权（面板仍可打开）电池信息也是活的。
    private func refreshBattery() {
        let info = BatteryMonitor.current()
        batteryHeader.isHidden = !info.hasBattery
        batteryStateLabel.isHidden = !info.hasBattery
        batteryHealthLabel.isHidden = !info.hasBattery
        guard info.hasBattery else { return }

        let level = info.levelPercent.map { "\($0)%" } ?? "—"
        var state = "\(info.isExternalConnected ? "🔌" : "🔋") \(level)"
        if info.isCharging {
            state += " · \(tr("battery.state.charging"))"
            if let m = info.timeToFullMinutes {
                state += " · " + L10n.tr("battery.timeToFull", "%@后充满", formatMinutes(m))
            }
        } else if info.isExternalConnected {
            // 插电未充电：可能已充满，也可能被限充卡在上限。
            let limitPct = chargeRef?.isActive == true ? chargeRef?.limitPercent : nil
            if info.isFullyCharged || info.levelPercent == 100 {
                state += " · " + tr("battery.state.full")
            } else if let limitPct, (info.levelPercent ?? 0) >= limitPct - 1 {
                state += " · " + tr("battery.state.atLimit")
            } else {
                state += " · " + tr("battery.state.plugged")
            }
        } else {
            state += " · \(tr("battery.state.discharging"))"
            if let m = info.timeToEmptyMinutes {
                state += " · " + L10n.tr("battery.timeToEmpty", "剩余 %@", formatMinutes(m))
            }
        }
        batteryStateLabel.stringValue = state

        // 健康行：各字段缺啥省啥，全缺则整行隐藏（很罕见）。
        var facts: [String] = []
        if let h = info.healthPercent {
            facts.append(L10n.tr("battery.health", "健康度 %d%%", h))
        }
        if let c = info.cycleCount {
            facts.append(L10n.tr("battery.cycles", "循环 %d 次", c))
        }
        if let charge = chargeRef, charge.isActive, charge.isCapable {
            facts.append(String(format: tr("battery.limitBadge"), charge.limitPercent))
        }
        if let t = info.temperatureC {
            facts.append(String(format: tr("battery.temp"), t))
        }
        if let w = info.powerW, w > 0.05 {
            let ws = L10n.decimal(w, fractionDigits: 1) + " W"
            facts.append(info.isCharging
                ? L10n.tr("battery.power.charging", "充电 %@", ws)
                : L10n.tr("battery.power.discharging", "放电 %@", ws))
        }
        batteryHealthLabel.stringValue = facts.joined(separator: " · ")
        batteryHealthLabel.isHidden = facts.isEmpty
    }

    /// 分钟数 → 本地化时长（"3小时05分" / "45分"）。
    private func formatMinutes(_ mins: Int) -> String {
        let h = mins / 60
        let m = mins % 60
        return h > 0
            ? L10n.tr("battery.duration.h", "%d小时%02d分", h, m)
            : L10n.tr("battery.duration.m", "%d分", m)
    }

    // MARK: - USB 开关

    /// 刷新 USB 区块。≥2s 节流（单次 uhubctl ~100ms，规格约束别打爆）；
    /// 扫描在后台队列跑，结果回主线程。无后台轮询：仅由面板刷新循环/打开驱动。
    private func refreshUSBPorts() {
        guard isViewLoaded else { return }
        if !usbManager.isUhubctlAvailable {
            applyUSB(ports: nil, hasUhubctl: false)
            return
        }
        guard Date().timeIntervalSince(usbLastScanAt) >= 2 else { return }
        usbLastScanAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ports = self?.usbManager.scan() ?? []
            DispatchQueue.main.async { [weak self] in
                self?.applyUSB(ports: ports, hasUhubctl: true)
            }
        }
    }

    /// 应用扫描结果到行控件（主线程）。行按 id 增删复用，顺序对齐扫描结果。
    private func applyUSB(ports: [USBPort]?, hasUhubctl: Bool) {
        guard isViewLoaded else { return }
        if !hasUhubctl {
            // 引导态：无 uhubctl，一键安装 / brew.sh 兜底 / 失败重试三态切换。
            usbBox.isHidden = false
            usbHeader.isHidden = false
            usbGuideBox.isHidden = false
            usbRowsBox.isHidden = true
            usbEmptyLabel.isHidden = true
            switch usbGuideState {
            case .idle:
                usbGuideLabel.stringValue = L10n.tr("usbPower.needUhubctl",
                    "未检测到 uhubctl，安装后可控制 USB 外设电源")
                usbInstallButton.title = L10n.tr("usbPower.install", "通过 Homebrew 自动安装")
                usbInstallButton.isEnabled = true
                usbCopyButton.title = L10n.tr("usbPower.copyBrew", "复制 brew 安装命令")
                usbCopyButton.isEnabled = true
            case .installing:
                usbGuideLabel.stringValue = L10n.tr("usbPower.installing",
                    "正在安装 uhubctl…（首次约几十秒）")
                usbInstallButton.isEnabled = false
                usbCopyButton.isEnabled = false
            case .brewMissing:
                usbGuideLabel.stringValue = L10n.tr("usbPower.brewMissing",
                    "未检测到 Homebrew，请先安装 Homebrew（brew.sh）")
                usbInstallButton.title = L10n.tr("usbPower.brewSite", "打开 brew.sh")
                usbInstallButton.isEnabled = true
                usbCopyButton.title = L10n.tr("usbPower.copyHomebrew", "复制 Homebrew 安装命令")
                usbCopyButton.isEnabled = true
            case .failed(let msg):
                usbGuideLabel.stringValue = L10n.tr("usbPower.installFail", "安装失败：%@", msg)
                usbInstallButton.title = L10n.tr("usbPower.install", "通过 Homebrew 自动安装")
                usbInstallButton.isEnabled = true
                usbCopyButton.title = L10n.tr("usbPower.copyBrew", "复制 brew 安装命令")
                usbCopyButton.isEnabled = true
            }
            updatePreferredContentSize()
            return
        }
        usbGuideBox.isHidden = true
        let list = ports ?? []
        if list.isEmpty && !usbManager.hasHistory() {
            // 没有可控口也从没用过 → 整块隐藏，零打扰。
            usbBox.isHidden = true
            updatePreferredContentSize()
            return
        }
        usbBox.isHidden = false
        usbHeader.isHidden = false
        usbRowsBox.isHidden = list.isEmpty
        // 有历史但全下线（显示器休眠等）→ 一行空态提示。
        usbEmptyLabel.isHidden = !list.isEmpty

        var ordered: [NSView] = []
        for port in list {
            let row = usbRows[port.id] ?? makeUSBRow()
            row.configure(port: port)
            usbRows[port.id] = row
            ordered.append(row)
        }
        for id in usbRows.keys where !list.contains(where: { $0.id == id }) {
            usbRows.removeValue(forKey: id)
            usbPinnedRows.remove(id)
        }
        usbRowsBox.setViews(ordered, in: .leading)
        for row in ordered {
            guard let id = (row as? USBSwitchRowView)?.currentPort?.id,
                  !usbPinnedRows.contains(id) else { continue }
            usbPinnedRows.insert(id)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: usbRowsBox.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: usbRowsBox.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 26),
            ])
        }
        updatePreferredContentSize()
    }

    /// 面板高度内容自适应（与 loadView 同口径：内容高 + 28）。
    private func updatePreferredContentSize() {
        guard let stack = view.subviews.first as? NSStackView else { return }
        preferredContentSize = NSSize(width: 340, height: stack.fittingSize.height + 28)
    }

    private func makeUSBRow() -> USBSwitchRowView {
        let row = USBSwitchRowView()
        row.onSwitch = { [weak self, weak row] on in
            guard let row else { return }
            self?.handleUSBSwitch(row, on: on)
        }
        row.onFlash = { [weak row] in
            if let port = row?.currentPort { USBPowerManager.shared.flash(port) }
        }
        row.onRename = { [weak self, weak row] in
            guard let row else { return }
            self?.renameUSB(row)
        }
        row.onToggleLock = { [weak self, weak row] in
            guard let self, let row, let port = row.currentPort else { return }
            self.usbManager.setLocked(port, locked: !port.locked)
            self.usbLastScanAt = .distantPast
            self.refreshUSBPorts()
        }
        row.onIgnore = { [weak self, weak row] in
            guard let self, let row, let port = row.currentPort else { return }
            self.usbManager.setIgnored(port, ignored: true)
            self.usbLastScanAt = .distantPast
            self.refreshUSBPorts()
        }
        return row
    }

    /// 开关翻转（方向以控件新态为准，setPower 显式指定，不依赖可能陈旧的缓存）。
    private func handleUSBSwitch(_ row: USBSwitchRowView, on: Bool) {
        guard let port = row.currentPort else { return }
        // 断电防误触：连接存储/键鼠类设备时确认（断电=拔线，可能丢数据/失联）。
        if !on, port.hasSensitiveDevice {
            let a = NSAlert()
            a.messageText = L10n.tr("usbPower.storageWarningTitle", "确认断电")
            a.informativeText = L10n.tr("usbPower.storageWarning",
                "「%@」连接着存储/键鼠类设备，断电相当于直接拔线，可能丢失数据。确定断电吗？", port.displayName)
            a.alertStyle = .warning
            a.addButton(withTitle: L10n.tr("usbPower.storageConfirm", "仍要断电"))
            a.addButton(withTitle: L10n.tr("usbPower.cancel", "取消"))
            guard a.runModal() == .alertFirstButtonReturn else {
                row.configure(port: port)   // 还原开关位置
                return
            }
        }
        row.setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.usbManager.setPower(port, on: on)
            } catch {
                // hub 掉线/显示器休眠：行内呈现，不弹窗打断。
                DispatchQueue.main.async { row.showOffline() }
            }
            // 成败都重扫一次，把行拉回真实态。
            let ports = self.usbManager.scan()
            DispatchQueue.main.async {
                self.usbLastScanAt = Date()
                self.applyUSB(ports: ports, hasUhubctl: true)
            }
        }
    }

    private func renameUSB(_ row: USBSwitchRowView) {
        guard let port = row.currentPort else { return }
        let a = NSAlert()
        a.messageText = L10n.tr("usbPower.rename", "重命名")
        a.informativeText = L10n.tr("usbPower.renameHint", "为这个端口起个名字：")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = port.userLabel
        input.placeholderString = L10n.tr("usbPower.unnamed", "端口 %d", port.portNumber)
        a.accessoryView = input
        a.window.initialFirstResponder = input
        a.addButton(withTitle: L10n.tr("usbPower.ok", "好"))
        a.addButton(withTitle: L10n.tr("usbPower.cancel", "取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        usbManager.setLabel(port, label: input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        usbLastScanAt = .distantPast
        refreshUSBPorts()
    }

    /// 一键安装 uhubctl（按钮点击即授权，无二次确认）；brew 缺失态按钮转为打开 brew.sh。
    @objc private func usbInstallClicked() {
        if case .brewMissing = usbGuideState {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        usbGuideState = .installing
        applyUSB(ports: nil, hasUhubctl: false)   // 立即切到「安装中」态
        USBPowerManager.shared.installUhubctl { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .installed:
                    // 装好即用：刷新引导判定 → 自动切到开关列表。
                    self.usbGuideState = .idle
                    self.usbLastScanAt = .distantPast
                    self.refreshUSBPorts()
                case .brewMissing:
                    self.usbGuideState = .brewMissing
                    self.applyUSB(ports: nil, hasUhubctl: false)
                case .failed(let msg):
                    self.usbGuideState = .failed(msg)
                    self.applyUSB(ports: nil, hasUhubctl: false)
                }
            }
        }
    }

    /// 引导兜底：复制命令到剪贴板（brew 缺失态复制 Homebrew 自身安装命令）。
    @objc private func copyBrewCommand() {
        let cmd: String
        if case .brewMissing = usbGuideState {
            cmd = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        } else {
            cmd = L10n.tr("usbPower.brewCmd", "brew install uhubctl")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        usbCopyButton.title = L10n.tr("usbPower.copied", "已复制 ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            // 复制期间可能已从菜单装好 uhubctl：可用则回正常刷新，否则恢复引导态标题。
            if self.usbManager.isUhubctlAvailable {
                self.refreshUSBPorts()
            } else {
                self.applyUSB(ports: nil, hasUhubctl: false)
            }
        }
    }

    // MARK: - 耗电应用 TOP

    /// 按当前图表区间聚合进程能耗：TOP 10 应用 + "其他"长尾行。
    /// 点击图表选中某柱时，切换为该小时/当天的单桶 TOP，标题追加桶标签。
    /// 归因口径：app 能耗分占比 × 区间实测总 Wh（Energy Impact 为加权代理分，Wh 是估算值）。
    private func refreshTopApps(snapshot: Snapshot) {
        guard let ps = processStoreRef else { return }

        let tops: [ProcessEnergyStore.TopApp]
        let totalWh: Double
        if let key = selectedBucketKey {
            switch prefs.chartRange {
            case .hours24:
                totalWh = snapshot.hours.first { $0.bucketKey == key }?.wh ?? 0
                tops = ps.topApps(hourKey: key, totalWh: totalWh)
            case .days7, .days30:
                totalWh = snapshot.days.first { $0.bucketKey == key }?.wh ?? 0
                tops = ps.topApps(dayKey: key, totalWh: totalWh)
            }
            let idx = chartBucketKeys.firstIndex(of: key)
            let bucketLabel = idx.flatMap { chartView.data.indices.contains($0) ? chartView.data[$0].label : nil } ?? key
            topAppsHeader.stringValue = L10n.tr("topapps.titleSelected", "耗电应用 TOP · %@", bucketLabel)
        } else {
            switch prefs.chartRange {
            case .hours24:
                let recent = snapshot.hours.suffix(24)
                totalWh = recent.reduce(0) { $0 + $1.wh }
                tops = ps.topApps(lastHours: 24, totalWh: totalWh)
            case .days7, .days30:
                let count = prefs.chartRange == .days7 ? 7 : 30
                let recent = snapshot.days.suffix(count)
                totalWh = recent.reduce(0) { $0 + $1.wh }
                tops = ps.topApps(lastDays: count, totalWh: totalWh)
            }
            topAppsHeader.stringValue = tr("topapps.title")
        }
        let other = ps.otherShare(of: tops)

        // 前 10 行是应用，最后一行是"其他"（长尾占比太小则隐藏）。
        for (i, row) in topAppRows.enumerated() {
            if i < tops.count {
                row.isHidden = false
                row.configure(rank: i + 1, name: tops[i].name,
                               share: tops[i].share, wh: tops[i].attributedWh)
            } else if i == topAppRows.count - 1, other > 0.005, !tops.isEmpty {
                row.isHidden = false
                row.configure(rank: nil, name: tr("topapps.other"),
                              share: other, wh: other * totalWh)
            } else {
                row.isHidden = true
            }
        }
        topAppsEmptyLabel.isHidden = !tops.isEmpty
    }

    // MARK: - UI 构建

    private func buildUI(in container: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: tr("app.title"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        powerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        powerLabel.alignment = .center
        powerLabel.textColor = .controlAccentColor   // 突出：强调色
        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        todayKwhLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        todayKwhLabel.alignment = .center
        todayKwhLabel.textColor = .controlAccentColor  // 突出：强调色
        costLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        costLabel.textColor = .secondaryLabelColor
        costLabel.alignment = .center

        totalLabel.font = NSFont.systemFont(ofSize: 10)
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.alignment = .center
        uptimeLabel.font = NSFont.systemFont(ofSize: 10)
        uptimeLabel.textColor = .secondaryLabelColor
        uptimeLabel.alignment = .center
        estimateNote.font = NSFont.systemFont(ofSize: 9)
        estimateNote.textColor = .tertiaryLabelColor
        estimateNote.alignment = .center
        rightClickHint.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        rightClickHint.textColor = .secondaryLabelColor
        rightClickHint.alignment = .center
        rightClickHint.stringValue = NSLocalizedString("panel.rightClickHint",
            value: "💡 右键状态栏图标打开设置", comment: "")

        buildPrivilegeBox()
        configureChartRangeSelector()   // 图表时段分段控件

        // 实时功率 + 今日电量合并成紧凑一块（中间只留小间距），
        // 避免被 NSStackView 的垂直拉伸撑出大空隙。
        let powerBox = vbox([powerLabel, detailLabel])
        let todayBox = vbox([todayKwhLabel, costLabel])
        let summaryBox = NSStackView(views: [powerBox, todayBox])
        summaryBox.orientation = .vertical
        summaryBox.alignment = .centerX
        summaryBox.spacing = 10   // 实时功率与今日电量之间的间距，紧凑
        summaryBox.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        // 电池区块：与功率/今日累计同样居中；无电池设备上三行全部隐藏。
        batteryHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        batteryHeader.textColor = .secondaryLabelColor
        batteryHeader.stringValue = tr("battery.title")
        batteryStateLabel.font = NSFont.systemFont(ofSize: 11)
        batteryHealthLabel.font = NSFont.systemFont(ofSize: 10)
        batteryHealthLabel.textColor = .secondaryLabelColor
        for label in [batteryHeader, batteryStateLabel, batteryHealthLabel] {
            label.alignment = .center
        }
        let batteryBox = NSStackView(views: [batteryHeader, batteryStateLabel, batteryHealthLabel])
        batteryBox.orientation = .vertical
        batteryBox.alignment = .centerX
        batteryBox.spacing = 3
        // 构建时立即定好初始可见性：无电池设备（mini）上首帧就是隐藏态，
        // 不等第一次采样刷新（冷打开面板时采样可能几秒后才到）。
        refreshBattery()

        // USB 开关区块：uhubctl 直连的外设通断电。默认整体隐藏，
        // 由 refreshUSBPorts 按三态切换（无 uhubctl → 引导 / 无口无历史 → 隐藏 / 有口 → 行列表）。
        usbHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        usbHeader.textColor = .secondaryLabelColor
        usbHeader.stringValue = L10n.tr("usbPower.title", "USB 开关")
        usbHeader.alignment = .center

        usbGuideLabel.font = NSFont.systemFont(ofSize: 10)
        usbGuideLabel.textColor = .secondaryLabelColor
        usbGuideLabel.alignment = .center
        usbGuideLabel.stringValue = L10n.tr("usbPower.needUhubctl",
            "未检测到 uhubctl，安装后可控制 USB 外设电源")

        usbInstallButton.bezelStyle = .rounded
        usbInstallButton.controlSize = .small
        usbInstallButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        usbInstallButton.target = self
        usbInstallButton.action = #selector(usbInstallClicked)
        usbInstallButton.title = L10n.tr("usbPower.install", "通过 Homebrew 自动安装")

        usbCopyButton.bezelStyle = .rounded
        usbCopyButton.controlSize = .small
        usbCopyButton.font = NSFont.systemFont(ofSize: 10)
        usbCopyButton.target = self
        usbCopyButton.action = #selector(copyBrewCommand)
        usbCopyButton.title = L10n.tr("usbPower.copyBrew", "复制 brew 安装命令")

        usbGuideBox.orientation = .vertical
        usbGuideBox.alignment = .centerX
        usbGuideBox.spacing = 4
        usbGuideBox.setViews([usbGuideLabel, usbInstallButton, usbCopyButton], in: .leading)

        usbRowsBox.orientation = .vertical
        usbRowsBox.alignment = .leading
        usbRowsBox.spacing = 3

        usbEmptyLabel.font = NSFont.systemFont(ofSize: 10)
        usbEmptyLabel.textColor = .tertiaryLabelColor
        usbEmptyLabel.alignment = .center
        usbEmptyLabel.stringValue = L10n.tr("usbPower.empty",
            "USB hub 暂不可达（显示器休眠或已断开）")

        usbBox.orientation = .vertical
        usbBox.alignment = .centerX
        usbBox.spacing = 3
        usbBox.setViews([usbHeader, usbGuideBox, usbRowsBox, usbEmptyLabel], in: .leading)
        usbBox.isHidden = true

        // 图表 + 时段切换组合成一个区块。时段切换行与图表之间留出足够间距。
        let chartHeader = NSTextField(labelWithString: tr("chart.title"))
        chartHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        chartHeader.textColor = .secondaryLabelColor
        let chartHeaderRow = NSStackView(views: [chartHeader, chartRangeSelector])
        chartHeaderRow.orientation = .horizontal
        chartHeaderRow.alignment = .centerY
        chartHeaderRow.distribution = .equalCentering
        let chartBox = NSStackView(views: [chartHeaderRow, chartView])
        chartBox.orientation = .vertical
        chartBox.alignment = .centerX
        chartBox.spacing = 10   // 时段切换与图表之间的间距（vbox 默认 2 太挤）
        chartView.onSelectionChange = { [weak self] index in
            self?.handleChartSelection(index)
        }

        // 耗电应用 TOP 区块：标题行 + 6 个条形行（5 应用 + 其他）+ 空态文案。
        topAppsHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        topAppsHeader.textColor = .secondaryLabelColor
        topAppsHeader.stringValue = tr("topapps.title")
        topAppsNote.font = NSFont.systemFont(ofSize: 9)
        topAppsNote.textColor = .tertiaryLabelColor
        topAppsNote.stringValue = tr("topapps.note")
        let topAppsHeaderRow = NSView()
        topAppsHeader.translatesAutoresizingMaskIntoConstraints = false
        topAppsNote.translatesAutoresizingMaskIntoConstraints = false
        topAppsHeaderRow.addSubview(topAppsHeader)
        topAppsHeaderRow.addSubview(topAppsNote)
        NSLayoutConstraint.activate([
            topAppsHeader.leadingAnchor.constraint(equalTo: topAppsHeaderRow.leadingAnchor),
            topAppsHeader.topAnchor.constraint(equalTo: topAppsHeaderRow.topAnchor),
            topAppsHeader.bottomAnchor.constraint(equalTo: topAppsHeaderRow.bottomAnchor),
            topAppsNote.trailingAnchor.constraint(equalTo: topAppsHeaderRow.trailingAnchor),
            topAppsNote.centerYAnchor.constraint(equalTo: topAppsHeaderRow.centerYAnchor),
            topAppsNote.leadingAnchor.constraint(greaterThanOrEqualTo: topAppsHeader.trailingAnchor, constant: 8),
        ])

        topAppsEmptyLabel.font = NSFont.systemFont(ofSize: 10)
        topAppsEmptyLabel.textColor = .tertiaryLabelColor
        topAppsEmptyLabel.stringValue = tr("topapps.empty")

        for _ in 0..<11 {
            let row = TopAppRowView(frame: .zero)
            row.isHidden = true
            topAppRows.append(row)
        }
        let topAppsBox = NSStackView(views: [topAppsHeaderRow] + topAppRows + [topAppsEmptyLabel])
        topAppsBox.orientation = .vertical
        topAppsBox.alignment = .leading
        topAppsBox.spacing = 2
        for row in topAppRows {
            row.heightAnchor.constraint(equalToConstant: 22).isActive = true
            row.leadingAnchor.constraint(equalTo: topAppsBox.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: topAppsBox.trailingAnchor).isActive = true
        }

        let footerBox = vbox([totalLabel, uptimeLabel, estimateNote, rightClickHint])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        let fullWidthViews: [NSView] = [title, summaryBox, batteryBox, usbBox, chartBox, topAppsBox, footerBox, privilegeBox]
        for v in fullWidthViews {
            stack.addArrangedSubview(v)
            stack.setCustomSpacing(8, after: v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalToConstant: 308),   // 定宽让 fittingSize 高度可解
            chartBox.heightAnchor.constraint(equalToConstant: 100),
        ])
        return stack
    }

    // MARK: - 权限卡片

    private func buildPrivilegeBox() {
        privilegeBox.boxType = .custom
        privilegeBox.borderColor = .systemOrange
        privilegeBox.cornerRadius = 6
        privilegeBox.borderWidth = 1
        privilegeBox.contentViewMargins = NSSize(width: 10, height: 8)
        privilegeBox.translatesAutoresizingMaskIntoConstraints = false
        privilegeBox.isHidden = true

        privilegeLabel.font = NSFont.systemFont(ofSize: 10)
        privilegeLabel.textColor = .systemOrange
        privilegeLabel.isSelectable = true

        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        grantButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        grantButton.target = self
        grantButton.action = #selector(grantPrivilege)

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        col.addArrangedSubview(privilegeLabel)
        col.addArrangedSubview(grantButton)
        col.translatesAutoresizingMaskIntoConstraints = false
        privilegeBox.contentView = col
    }

    @objc private func grantPrivilege() {
        grantButton.isEnabled = false
        grantButton.title = tr("privilege.processing")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = PrivilegeManager.requestPrivilege()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.grantButton.isEnabled = true
                self.grantButton.title = self.tr("privilege.button")
                if let error = error {
                    self.privilegeLabel.stringValue = L10n.tr("privilege.failed", "❌ 授权失败：%@", error)
                } else {
                    self.privilegeBox.isHidden = true
                    NotificationCenter.default.post(name: .privilegeGranted, object: nil)
                }
            }
        }
    }

    // MARK: - 设置入口（按钮 + 能力摘要）

    // MARK: - 图表时段

    @objc private func chartRangeChanged() {
        if let r = ChartRange(rawValue: chartRangeSelector.selectedSegment) {
            prefs.chartRange = r
            // 区间变了，点击选中的桶不再有意义，连同列表一起回到区间聚合。
            chartView.clearSelection()
            selectedBucketKey = nil
            refreshIfShown()
        }
    }

    /// 图表点击选中/取消：把选中索引映射为桶 key 后刷新 TOP 列表。
    private func handleChartSelection(_ index: Int?) {
        selectedBucketKey = index.flatMap { $0 < chartBucketKeys.count ? chartBucketKeys[$0] : nil }
        refreshIfShown()
    }

    /// 配置图表时段分段控件（动态宽度，避免英文挤压）。
    private func configureChartRangeSelector() {
        let segFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        chartRangeSelector.segmentCount = ChartRange.allCases.count
        chartRangeSelector.target = self
        chartRangeSelector.action = #selector(chartRangeChanged)
        chartRangeSelector.controlSize = .small
        chartRangeSelector.segmentStyle = .texturedRounded
        for (i, r) in ChartRange.allCases.enumerated() {
            chartRangeSelector.setLabel(r.shortLabel, forSegment: i)
            let w = (r.shortLabel as NSString).size(withAttributes: [.font: segFont]).width
            chartRangeSelector.setWidth(w + 16, forSegment: i)
        }
        chartRangeSelector.selectedSegment = prefs.chartRange.rawValue
    }

    /// 注入 store 引用。
    func attachStore(_ store: EnergyStore) {
        storeRef = store
    }

    /// 注入进程能耗 store 引用（耗电应用 TOP 列表数据源）。
    func attachProcessStore(_ store: ProcessEnergyStore) {
        processStoreRef = store
    }

    /// 注入充电控制器引用（面板展示限充状态）。
    func attachChargeController(_ controller: ChargeController) {
        chargeRef = controller
    }

    /// 若面板打开，刷新一次（图表时段切换后）。
    func refreshIfShown() {
        guard isViewLoaded, let store = storeRef else { return }
        refresh(snapshot: store.currentSnapshot(), sample: nil)
    }


    // MARK: - 小工具

    /// 取本地化字符串（单参，无格式参数）。
    /// fallback 直接复用 key，让 .strings 文件提供文本；带参数的场景用 L10n.tr。
    private func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func settingsLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 10)
        f.alignment = .right
        f.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return f
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 6
        // 标签定宽，让输入控件对齐。
        if let first = views.first as? NSTextField, views.count > 1 {
            first.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        return s
    }

    private func vbox(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .centerX
        s.spacing = 2
        return s
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return L10n.tr("footer.uptime.days", "运行 %d天%02d小时", d, h) }
        if h > 0 { return L10n.tr("footer.uptime.hours", "运行 %d小时%02d分", h, m) }
        return L10n.tr("footer.uptime.mins", "运行 %d分", m)
    }

    /// 解析天桶 key "yyyy-MM-dd" 为 Date（用于图表 X 轴标签格式化）。
    private func parseDayKey(_ key: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: key)
    }
}

// MARK: - 耗电应用条形行

/// 单行应用条：背景按占比填充强调色（条形即背景），行内左侧"序号+名称"、
/// 右侧"占比 · 归因 Wh"。项目无 TableView 先例且行数固定，纯手绘最简。
final class TopAppRowView: NSView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = NSFont.systemFont(ofSize: 10)
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// rank 为 nil 时表示聚合行（"其他"），名称置灰。
    func configure(rank: Int?, name: String, share: Double, wh: Double) {
        nameLabel.stringValue = rank.map { "\($0)  \(name)" } ?? "·  \(name)"
        nameLabel.textColor = rank == nil ? .secondaryLabelColor : .labelColor
        let pct = Int((share * 100).rounded())
        valueLabel.stringValue = "\(pct)% · \(L10n.decimal(wh, fractionDigits: 1)) Wh"
        fraction = share
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 整行浅色底 + 按占比宽度的深色填充，双层圆角条。
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        guard fraction > 0.001 else { return }
        let width = max(bounds.width * min(1, fraction), 8)
        let bar = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSColor.controlAccentColor.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
    }
}

// MARK: - USB 开关行

/// 单行 USB 端口开关：[名称] [供电/断电/锁定态] [NSSwitch] [🔒]。
/// 右键行内菜单：闪烁定位 / 重命名 / 锁定 / 忽略。锁定时开关禁用
/// （保护机制，UI 不代用户解锁——解锁须走显式的「解除锁定」菜单项）。
final class USBSwitchRowView: NSView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let powerSwitch = NSSwitch()
    private let lockLabel = NSTextField(labelWithString: "🔒")
    private var port: USBPort?

    var currentPort: USBPort? { port }

    var onSwitch: ((Bool) -> Void)?
    var onFlash: (() -> Void)?
    var onRename: (() -> Void)?
    var onToggleLock: (() -> Void)?
    var onIgnore: (() -> Void)?

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateLabel.font = NSFont.systemFont(ofSize: 10)
        stateLabel.textColor = .secondaryLabelColor

        powerSwitch.controlSize = .small
        powerSwitch.target = self
        powerSwitch.action = #selector(switchFlipped)

        lockLabel.font = NSFont.systemFont(ofSize: 10)
        lockLabel.isHidden = true

        for v in [nameLabel, stateLabel, powerSwitch, lockLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: powerSwitch.leadingAnchor, constant: -8),
            powerSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            powerSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockLabel.leadingAnchor.constraint(greaterThanOrEqualTo: powerSwitch.trailingAnchor, constant: 2),
            lockLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            lockLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按端口状态刷新行。程序化设 NSSwitch.state 不触发 action，无回环风险。
    func configure(port: USBPort) {
        self.port = port
        nameLabel.stringValue = port.userLabel.isEmpty
            ? L10n.tr("usbPower.unnamed", "端口 %d", port.portNumber)
            : port.userLabel
        if port.locked {
            stateLabel.stringValue = L10n.tr("usbPower.state.locked", "🔒已锁定")
            stateLabel.textColor = .tertiaryLabelColor
            powerSwitch.isEnabled = false
        } else {
            stateLabel.stringValue = port.power
                ? L10n.tr("usbPower.state.on", "✅供电")
                : L10n.tr("usbPower.state.off", "⛔断电")
            stateLabel.textColor = .secondaryLabelColor
            powerSwitch.isEnabled = true
        }
        powerSwitch.state = port.power ? .on : .off
        lockLabel.isHidden = !port.locked
        menu = buildMenu()
    }

    /// 操作中/离线态：开关禁用防连点，状态行内呈现（规格：不弹错误打断）。
    func setBusy(_ busy: Bool) {
        powerSwitch.isEnabled = !busy && !(port?.locked ?? false)
    }

    func showOffline() {
        guard let port else { return }
        stateLabel.stringValue = L10n.tr("usbPower.state.offline", "离线")
        stateLabel.textColor = .tertiaryLabelColor
        powerSwitch.state = port.power ? .on : .off
        powerSwitch.isEnabled = false
    }

    @objc private func switchFlipped() {
        guard let port else { return }
        guard !port.locked else {
            powerSwitch.state = port.power ? .on : .off   // 双保险：锁定态拨不动
            return
        }
        onSwitch?(powerSwitch.state == .on)
    }

    /// 右键行内菜单（每次 configure 重建，锁定项标题随态切换）。
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        for (title, sel) in [
            (L10n.tr("usbPower.flash", "闪烁定位"), #selector(doFlash)),
            (L10n.tr("usbPower.rename", "重命名"), #selector(doRename)),
            ((port?.locked ?? false)
                ? L10n.tr("usbPower.unlock", "解除锁定")
                : L10n.tr("usbPower.lock", "锁定保护"), #selector(doToggleLock)),
            (L10n.tr("usbPower.ignore", "忽略此口"), #selector(doIgnore)),
        ] {
            let item = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
        }
        return m
    }

    @objc private func doFlash() { onFlash?() }
    @objc private func doRename() { onRename?() }
    @objc private func doToggleLock() { onToggleLock?() }
    @objc private func doIgnore() { onIgnore?() }

    override func draw(_ dirtyRect: NSRect) {
        // 与耗电应用行一致的浅色圆角底。
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

