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

    // 底部
    private let totalLabel = NSTextField(labelWithString: "")
    private let uptimeLabel = NSTextField(labelWithString: "")
    private let estimateNote = NSTextField(labelWithString: "")

    // 权限状态卡片
    private let privilegeBox = NSBox()
    private let privilegeLabel = NSTextField(labelWithString: "")
    private let grantButton = NSButton(title: "", target: nil, action: nil)

    // 图表时段切换（保留在主面板）
    private let chartRangeSelector = NSSegmentedControl()

    // 设置入口：打开按钮 + 能力摘要小字（横向紧凑一行）
    private let openSettingsButton = NSButton(title: "", target: nil, action: nil)
    private let capabilitiesLabel = NSTextField(labelWithString: "")
    private let settingsEntryRow = NSStackView()

    private let prefs: Preferences
    private weak var storeRef: EnergyStore?

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        buildUI(in: container)
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 设置项已迁至独立设置窗口，主面板无需初始化设置控件。
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

        let cost = snapshot.todayWh / 1000 * prefs.pricePerKWh
        costLabel.stringValue = L10n.tr("cost.label", "约 %@ %@/kWh",
                                        L10n.cost(cost, currency: prefs.currency),
                                        L10n.decimal(prefs.pricePerKWh, fractionDigits: 2))

        let df = DateFormatter()
        df.locale = Locale.current
        df.dateStyle = .medium
        df.timeStyle = .short
        totalLabel.stringValue = L10n.tr("footer.total", "累计 %@ kWh（自 %@）",
                                         L10n.decimal(snapshot.totalWh / 1000, fractionDigits: 3),
                                         df.string(from: snapshot.createdAt))

        uptimeLabel.stringValue = formatDuration(Date().timeIntervalSince(snapshot.createdAt))
        estimateNote.stringValue = tr("footer.socEstimate")

        // 图表数据按当前区间切换：24h 用小时桶（值=Wh≈该小时平均W），
        // 7天/30天 用天桶（值=kWh，按桶大小放大到可比刻度）。
        switch prefs.chartRange {
        case .hours24:
            let recent = snapshot.hours.suffix(24)
            chartView.data = recent.map { bucket in
                let hour = String(bucket.bucketKey.suffix(2))
                return (label: "\(hour)", value: bucket.wh)   // Wh ≈ 平均W
            }
            chartView.unitLabel = tr("power.unit")
        case .days7, .days30:
            let count = prefs.chartRange == .days7 ? 7 : 30
            let recent = snapshot.days.suffix(count)
            let df = DateFormatter()
            df.locale = Locale.current
            df.dateFormat = "MM-dd"
            chartView.data = recent.map { bucket in
                let date = parseDayKey(bucket.bucketKey) ?? Date()
                return (label: df.string(from: date), value: bucket.wh / 1000)  // kWh
            }
            chartView.unitLabel = tr("kWh.unit")
        }

        let status = PrivilegeManager.currentStatus()
        privilegeBox.isHidden = status != .missing
        if status == .missing {
            privilegeLabel.stringValue = tr("privilege.warning")
        }
    }

    // MARK: - UI 构建

    private func buildUI(in container: NSView) {
        let title = NSTextField(labelWithString: tr("app.title"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        powerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        powerLabel.alignment = .center
        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        todayKwhLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        todayKwhLabel.alignment = .center
        costLabel.font = NSFont.systemFont(ofSize: 10)
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

        buildPrivilegeBox()
        buildSettingsEntry()
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

        // 图表 + 时段切换组合成一个区块。
        let chartHeader = NSTextField(labelWithString: tr("chart.title"))
        chartHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        chartHeader.textColor = .secondaryLabelColor
        let chartHeaderRow = NSStackView(views: [chartHeader, chartRangeSelector])
        chartHeaderRow.orientation = .horizontal
        chartHeaderRow.alignment = .centerY
        chartHeaderRow.distribution = .equalCentering
        let chartBox = vbox([chartHeaderRow, chartView])
        let footerBox = vbox([totalLabel, uptimeLabel, estimateNote])
        let settingsBox = settingsEntryRow   // 横向紧凑入口

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        let fullWidthViews: [NSView] = [title, summaryBox, chartBox, footerBox, privilegeBox, settingsBox]
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
            chartBox.heightAnchor.constraint(equalToConstant: 100),
        ])
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

    /// 主面板底部「打开设置」入口：按钮 + 右侧能力摘要小字，横向紧凑一行。
    private func buildSettingsEntry() {
        openSettingsButton.title = tr("settings.open")
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .small
        openSettingsButton.font = .systemFont(ofSize: 11, weight: .medium)
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettings)

        capabilitiesLabel.font = .systemFont(ofSize: 9)
        capabilitiesLabel.textColor = .tertiaryLabelColor
        capabilitiesLabel.alignment = .left
        capabilitiesLabel.lineBreakMode = .byTruncatingTail
        capabilitiesLabel.stringValue = tr("settings.capabilities")
        capabilitiesLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 横向：按钮 + 说明文字，单行，不占多余纵向空间。
        settingsEntryRow.orientation = .horizontal
        settingsEntryRow.alignment = .centerY
        settingsEntryRow.spacing = 8
        settingsEntryRow.distribution = .fill
        settingsEntryRow.addArrangedSubview(openSettingsButton)
        settingsEntryRow.addArrangedSubview(capabilitiesLabel)
        settingsEntryRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// 打开独立设置窗口（由 AppDelegate 提供窗口实例）。
    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    // MARK: - 图表时段

    @objc private func chartRangeChanged() {
        if let r = ChartRange(rawValue: chartRangeSelector.selectedSegment) {
            prefs.chartRange = r
            refreshIfShown()
        }
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
