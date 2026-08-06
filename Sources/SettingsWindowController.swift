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

        let contentWidth = 400
        let contentHeight = 640
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = NSLocalizedString("settings.windowTitle", value: "PowerCumul 设置", comment: "")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: CGFloat(contentWidth), height: CGFloat(contentHeight))
        w.maxSize = NSSize(width: CGFloat(contentWidth), height: CGFloat(contentHeight))

        // frame-based 内容视图：直接绝对坐标排列，不依赖 Auto Layout。
        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        layoutContent(in: content)
        w.contentView = content

        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .settingsWindowClosed, object: nil)
        window = nil
    }

    // MARK: - frame-based 布局

    /// 用绝对坐标把所有控件排列进 content 视图。
    /// 坐标系：NSView 左下角为原点，y 向上。从顶部往下排。
    private func layoutContent(in content: NSView) {
        configureControls()
        applyPrefsToControls()

        let width = content.bounds.width
        var y = content.bounds.height   // 从顶部开始，y 递减向下

        // 四个分组的配置：标题 + 行。
        // 从上到下顺序：采样与货币 → 告警 → 显示与语言 → 数据。
        y -= groupTitle(content, tr("group.sampling"), y: y, width: width) + 8
        y -= addRow(content, label: tr("settings.interval"), controls: [intervalField, intervalStepper], y: y, width: width)
        y -= addRow(content, label: tr("settings.currency"), controls: [currencyPopup], y: y, width: width)
        y -= addRow(content, label: tr("settings.price"), controls: [priceField], y: y, width: width) + 18

        y -= groupTitle(content, tr("group.alerts"), y: y, width: width) + 8
        y -= addRow(content, label: tr("settings.alertPower"), controls: [alertPowerButton, alertPowerField], y: y, width: width)
        y -= addRow(content, label: tr("settings.alertBudget"), controls: [alertBudgetButton, alertBudgetField], y: y, width: width) + 18

        y -= groupTitle(content, tr("group.display"), y: y, width: width) + 8
        y -= addRow(content, label: tr("settings.statusbar"), controls: [statusModeSelector], y: y, width: width)
        y -= addRow(content, label: tr("settings.language"), controls: [languagePopup], y: y, width: width)
        y -= addRow(content, label: nil, controls: [launchAtLoginButton], y: y, width: width) + 18

        y -= groupTitle(content, tr("group.data"), y: y, width: width) + 8
        _ = addRow(content, label: nil, controls: [exportButton], y: y, width: width)
    }

    /// 添加一个分组标题，返回占用高度。
    private func groupTitle(_ parent: NSView, _ text: String, y: CGFloat, width: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .controlAccentColor
        let h: CGFloat = 20
        label.frame = NSRect(x: 20, y: y - h, width: width - 40, height: h)
        parent.addSubview(label)
        return h
    }

    /// 添加一行：左侧标签（可空）+ 右侧控件，返回行高（28）。
    private func addRow(_ parent: NSView, label: String?, controls: [NSView], y: CGFloat, width: CGFloat) -> CGFloat {
        let rowH: CGFloat = 28
        let labelWidth: CGFloat = 80
        let padding: CGFloat = 20
        let baseY = y - rowH

        if let labelText = label {
            let l = NSTextField(labelWithString: labelText)
            l.font = .systemFont(ofSize: 11)
            l.alignment = .right
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: padding, y: baseY + 6, width: labelWidth, height: 16)
            parent.addSubview(l)
        }

        // 控件从右往左或从左往右排列在标签右侧区域。
        let controlsX = padding + labelWidth + 12
        let controlsWidth = width - controlsX - padding
        // 简单地横向依次摆放；每个控件给固定宽度。
        var cx = controlsX
        for c in controls {
            let cw = controlWidth(c, available: controlsWidth - (cx - controlsX))
            c.frame = NSRect(x: cx, y: baseY + 2, width: cw, height: 24)
            c.autoresizingMask = [.minXMargin]   // 右侧固定，跟随窗口宽度调整左边距
            parent.addSubview(c)
            cx += cw + 8
        }
        return rowH
    }

    /// 给控件一个合理宽度。
    private func controlWidth(_ c: NSView, available: CGFloat) -> CGFloat {
        if c is NSStepper { return 18 }
        if c is NSPopUpButton { return min(120, available) }
        if c is NSSegmentedControl { return available }
        if c is NSButton { return min(160, available) }
        return min(80, available)   // NSTextField 输入框
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

        exportButton.bezelStyle = .rounded; exportButton.controlSize = .small
        exportButton.font = .systemFont(ofSize: 11, weight: .medium)
        exportButton.title = NSLocalizedString("settings.export", value: "导出 CSV", comment: "")
        exportButton.target = self; exportButton.action = #selector(exportCSV)

        launchAtLoginButton.target = self; launchAtLoginButton.action = #selector(launchAtLoginToggled)
        launchAtLoginButton.title = NSLocalizedString("settings.launchAtLogin", value: "开机自启", comment: "")
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
