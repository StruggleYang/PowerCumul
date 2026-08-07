//
//  SettingsWindowController.swift
//  PowerCumul
//
//  独立设置窗口。
//  刻意用 frame-based 绝对布局（不用 ScrollView/复杂 Auto Layout），
//  保证窗口内容在任何情况下都能可见——避免之前约束塌缩导致窗口看不见的问题。
//  窗口固定尺寸 400×640，9 项设置按 4 个分组纵向排列，足够装下。
//

import AppKit
import ServiceManagement

final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let prefs: Preferences
    private weak var store: EnergyStore?
    private(set) var window: NSWindow?

    // 控件引用。
    private let intervalStepper = NSStepper()
    private let intervalField = NSTextField(labelWithString: "")
    private let currencyPopup = NSPopUpButton()
    private let priceField = NSTextField()
    private let statusModeSelector = NSSegmentedControl()
    private let languagePopup = NSPopUpButton()
    private let alertPowerButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alertPowerField = NSTextField()
    private let alertBudgetButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alertBudgetField = NSTextField()
    private let exportButton = NSButton(title: "", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // 功率校正系数（滑块 + 数值显示）
    private let correctionSlider = NSSlider()
    private let correctionField = NSTextField(labelWithString: "")

    init(prefs: Preferences, store: EnergyStore?) {
        self.prefs = prefs
        self.store = store
        super.init()
    }

    // MARK: - 显示窗口

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let contentWidth = 420
        let contentHeight = 560
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = NSLocalizedString("settings.windowTitle", value: "PowerCumul 设置", comment: "")
        w.titlebarAppearsTransparent = false
        w.titleVisibility = .visible
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 380, height: 480)

        // NSScrollView 承载分组卡片，内容多时自动滚动。
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        buildGroupedContent(in: content)
        w.contentView = scroll
        // documentView 宽度跟随滚动视图，高度由内容撑开。
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .settingsWindowClosed, object: nil)
        window = nil
    }

    // MARK: - 分组卡片布局（Auto Layout）

    /// 在 content 中构建垂直排列的分组卡片。
    private func buildGroupedContent(in content: NSView) {
        configureControls()
        applyPrefsToControls()

        let sampling = makeGroup(title: tr("group.sampling"), rows: [
            (tr("settings.interval"),  [intervalField, intervalStepper]),
            (tr("settings.currency"),  [currencyPopup]),
            (tr("settings.price"),     [priceField]),
            (tr("settings.correction"),[correctionSlider, correctionField]),
        ])
        let alerts = makeGroup(title: tr("group.alerts"), rows: [
            (tr("settings.alertPower"),  [alertPowerButton, alertPowerField]),
            (tr("settings.alertBudget"), [alertBudgetButton, alertBudgetField]),
        ])
        let display = makeGroup(title: tr("group.display"), rows: [
            (tr("settings.statusbar"), [statusModeSelector]),
            (tr("settings.language"),  [languagePopup]),
            (nil, [launchAtLoginButton]),
            (nil, [exportButton]),
        ])

        let stack = NSStackView(views: [sampling, alerts, display])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// 一个分组：标题 + NSGridView（左列标签右对齐统一宽度，右列控件垂直居中）。
    private func makeGroup(title: String, rows: [(String?, [NSView])]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.yPlacement = .center
        grid.xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        for (labelText, controls) in rows {
            // 左列：标签（无标签则用空占位视图，保持列对齐）。
            let leftView: NSView
            if let lt = labelText {
                let l = NSTextField(labelWithString: lt)
                l.font = .systemFont(ofSize: 11)
                l.alignment = .right
                l.textColor = .labelColor
                l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                leftView = l
            } else {
                leftView = NSView()
            }
            // 右列：控件横向排列，垂直居中。
            let controlRow = NSStackView(views: controls)
            controlRow.orientation = .horizontal
            controlRow.alignment = .centerY
            controlRow.spacing = 6
            grid.addRow(with: [leftView, controlRow])
        }
        // 第一列统一宽度，让所有标签右对齐到同一条线。
        grid.column(at: 0).width = 90

        let col = NSStackView(views: [titleLabel, grid])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }


    // MARK: - 控件配置（与原面板逻辑一致）

    private func configureControls() {
        intervalField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        intervalField.alignment = .center
        intervalStepper.minValue = 1; intervalStepper.maxValue = 60
        intervalStepper.increment = 1; intervalStepper.valueWraps = false
        intervalStepper.target = self; intervalStepper.action = #selector(intervalChanged)

        currencyPopup.addItems(withTitles: Currency.allCases.map { $0.displayName })
        currencyPopup.target = self; currencyPopup.action = #selector(currencyChanged)

        priceField.target = self; priceField.action = #selector(priceChanged)
        priceField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        priceField.alignment = .right; priceField.isBordered = true; priceField.drawsBackground = true

        let segFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        statusModeSelector.segmentCount = StatusItemMode.allCases.count
        statusModeSelector.target = self; statusModeSelector.action = #selector(statusModeChanged)
        statusModeSelector.controlSize = .small; statusModeSelector.segmentStyle = .texturedRounded
        for (i, mode) in StatusItemMode.allCases.enumerated() {
            statusModeSelector.setLabel(mode.shortLabel, forSegment: i)
            let w = (mode.shortLabel as NSString).size(withAttributes: [.font: segFont]).width
            statusModeSelector.setWidth(w + 16, forSegment: i)
        }

        languagePopup.addItems(withTitles: AppLanguage.allCases.map { $0.displayName })
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)

        alertPowerButton.target = self; alertPowerButton.action = #selector(alertPowerToggled)
        alertPowerField.target = self; alertPowerField.action = #selector(alertPowerThresholdChanged)
        alertPowerField.alignment = .right
        alertPowerField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        alertPowerField.isBordered = true; alertPowerField.drawsBackground = true

        alertBudgetButton.target = self; alertBudgetButton.action = #selector(alertBudgetToggled)
        alertBudgetField.target = self; alertBudgetField.action = #selector(alertBudgetThresholdChanged)
        alertBudgetField.alignment = .right
        alertBudgetField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        alertBudgetField.isBordered = true; alertBudgetField.drawsBackground = true

        exportButton.bezelStyle = .roundRect; exportButton.controlSize = .regular
        exportButton.font = .systemFont(ofSize: 11, weight: .regular)
        exportButton.title = NSLocalizedString("settings.export", value: "↓ 导出 CSV", comment: "")
        exportButton.target = self; exportButton.action = #selector(exportCSV)

        launchAtLoginButton.target = self; launchAtLoginButton.action = #selector(launchAtLoginToggled)
        launchAtLoginButton.title = NSLocalizedString("settings.launchAtLogin", value: "开机自启", comment: "")

        // 功率校正滑块：范围 1.0~1.6（覆盖常见整机/SoC 比值）。
        correctionSlider.minValue = 1.0
        correctionSlider.maxValue = 1.6
        correctionSlider.target = self
        correctionSlider.action = #selector(correctionChanged)
        correctionSlider.controlSize = .small
        correctionField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        correctionField.alignment = .center
    }

    private func applyPrefsToControls() {
        intervalStepper.intValue = Int32(prefs.sampleIntervalSec)
        intervalField.stringValue = L10n.tr("settings.seconds", "%d 秒", prefs.sampleIntervalSec)
        currencyPopup.selectItem(at: Currency.allCases.firstIndex(of: prefs.currency) ?? 0)
        priceField.doubleValue = prefs.pricePerKWh
        priceField.toolTip = prefs.currency.perKWhUnit
        statusModeSelector.selectedSegment = prefs.statusItemMode.rawValue
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: prefs.appLanguage) ?? 0)
        alertPowerButton.state = prefs.alertPowerEnabled ? .on : .off
        alertPowerField.doubleValue = prefs.alertPowerThresholdW
        alertBudgetButton.state = prefs.alertBudgetEnabled ? .on : .off
        alertBudgetField.doubleValue = prefs.alertBudgetThreshold
        launchAtLoginButton.state = SMAppService.mainApp.status != .notRegistered ? .on : .off
        correctionSlider.doubleValue = prefs.powerCorrectionFactor
        updateCorrectionField()
    }

    /// 刷新校正系数显示文本（如 "×1.20"）。
    private func updateCorrectionField() {
        correctionField.stringValue = String(format: "×%.2f", prefs.powerCorrectionFactor)
    }

    // MARK: - 事件

    @objc private func intervalChanged() {
        let v = max(1, Int(intervalStepper.intValue))
        prefs.sampleIntervalSec = v
        intervalField.stringValue = L10n.tr("settings.seconds", "%d 秒", v)
    }

    @objc private func currencyChanged() {
        let idx = currencyPopup.indexOfSelectedItem
        if Currency.allCases.indices.contains(idx) {
            prefs.currency = Currency.allCases[idx]
            priceField.toolTip = prefs.currency.perKWhUnit
        }
    }

    @objc private func priceChanged() {
        let v = priceField.doubleValue
        if v > 0 { prefs.pricePerKWh = v }
        priceField.doubleValue = prefs.pricePerKWh
    }

    @objc private func statusModeChanged() {
        if let mode = StatusItemMode(rawValue: statusModeSelector.selectedSegment) {
            prefs.statusItemMode = mode
        }
    }

    @objc private func languageChanged() {
        let idx = languagePopup.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(idx),
              AppLanguage.allCases[idx] != prefs.appLanguage else { return }
        prefs.appLanguage = AppLanguage.allCases[idx]
        NotificationCenter.default.post(name: .languageChangeRequested, object: nil)
    }

    @objc private func alertPowerToggled() {
        prefs.alertPowerEnabled = alertPowerButton.state == .on
        if prefs.alertPowerEnabled { AlertManager.requestAuthorizationShared() }
    }

    @objc private func alertPowerThresholdChanged() {
        let v = alertPowerField.doubleValue
        if v > 0 { prefs.alertPowerThresholdW = v }
        alertPowerField.doubleValue = prefs.alertPowerThresholdW
    }

    @objc private func alertBudgetToggled() {
        prefs.alertBudgetEnabled = alertBudgetButton.state == .on
        if prefs.alertBudgetEnabled { AlertManager.requestAuthorizationShared() }
    }

    @objc private func alertBudgetThresholdChanged() {
        let v = alertBudgetField.doubleValue
        if v > 0 { prefs.alertBudgetThreshold = v }
        alertBudgetField.doubleValue = prefs.alertBudgetThreshold
    }

    @objc private func correctionChanged() {
        // 滑块步进 0.05，量化到两位小数。
        let v = (correctionSlider.doubleValue * 20).rounded() / 20
        prefs.powerCorrectionFactor = v
        correctionSlider.doubleValue = v
        updateCorrectionField()
    }

    @objc private func exportCSV() {
        guard let store = store else { return }
        let ok = CSVExporter.export(snapshot: store.currentSnapshot(), prefs: prefs)
        if !ok { NSSound.beep() }
    }

    @objc private func launchAtLoginToggled() {
        let service = SMAppService.mainApp
        if launchAtLoginButton.state == .on {
            do { try service.register() }
            catch { launchAtLoginButton.state = .off; NSSound.beep() }
        } else {
            try? service.unregister()
        }
    }

    private func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
