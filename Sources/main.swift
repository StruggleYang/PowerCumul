//
//  main.swift
//  PowerCumul
//
//  菜单栏 App 入口。用纯 AppKit（非 SwiftUI 生命周期）：
//  - 建 NSStatusItem（图标 + 实时功率文本）
//  - 点开弹 NSPopover 面板（PanelController）
//  - 定时跑 PowerSampler 采样，写入 EnergyStore，刷新状态栏与面板
//
//  使用 main.swift（而非 @main）是为了显式调用 setActivationPolicy(.accessory)，
//  与 Info.plist 的 LSUIElement 双保险隐藏 Dock 图标。
//

import AppKit
import ServiceManagement

// MARK: - 入口

// 语言覆盖必须在 NSApplication 初始化之前完成，
// 否则首个 UI（状态栏图标/面板）会用旧语言创建。
let bootstrapPrefs = Preferences()
L10n.applyLanguage(from: bootstrapPrefs)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏 App，无 Dock 图标
app.run()

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panelController: PanelController!

    private let prefs = Preferences()
    private let store = EnergyStore()
    private lazy var alertManager = AlertManager(prefs: prefs, store: store)
    private var timer: DispatchSourceTimer?
    private var lastSample: PowerSample?
    private var missedFirstSample = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildPopover()
        startSampling()
        observePrefs()
    }

    // MARK: - 状态栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill",
                                   accessibilityDescription: "PowerCumul")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 接收右键事件，用于弹出设置菜单。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // 悬停提示：左键看面板、右键设置。
            button.toolTip = NSLocalizedString("statusbar.tooltip",
                value: "左键：查看面板\n右键：设置", comment: "")
        }
        updateStatusItemTitle()
    }

    /// 状态栏点击：左键切换面板，右键弹设置菜单。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // 右键：弹设置菜单。
            buildSettingsMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else {
            // 左键：切换主面板。
            togglePopover(sender)
        }
    }

    /// 刷新状态栏文字（功率/费用/电量/组合/仅图标，由偏好决定）。
    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let snap = store.currentSnapshot()
        let w = (lastSample?.totalMW ?? snap.currentMW) / 1000
        let kwh = snap.todayWh / 1000
        let cost = kwh * prefs.pricePerKWh
        let unit = tr("power.unit")

        switch prefs.statusItemMode {
        case .cost:
            button.title = " \(prefs.currency.symbol)\(L10n.decimal(cost, fractionDigits: 2))"
        case .kwh:
            button.title = " \(L10n.decimal(kwh, fractionDigits: 3))\(tr("kWh.unit"))"
        case .combo:
            button.title = " \(L10n.decimal(w, fractionDigits: 1))\(unit) · "
                + "\(prefs.currency.symbol)\(L10n.decimal(cost, fractionDigits: 2))"
        case .iconOnly:
            button.title = ""
        case .power:
            button.title = " \(L10n.decimal(w, fractionDigits: 1))\(unit)"
        }
    }

    private func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    // MARK: - 面板

    private func buildPopover() {
        panelController = PanelController(prefs: prefs)
        panelController.attachStore(store)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panelController
        popover.contentSize = NSSize(width: 340, height: 420)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // 打开前先刷新一次，保证内容是最新的。
            refreshAll()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 采样循环

    private func startSampling() {
        // 立即采一次首样。
        sampleOnce()
        scheduleNext()
    }

    private func scheduleNext() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = max(1, prefs.sampleIntervalSec)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sampleOnce()
        }
        t.resume()
        timer = t
    }

    private func sampleOnce() {
        guard let sample = PowerSampler.sample() else {
            // 采样失败（多半是 sudo 免密未配）。仅在面板打开时刷新提示。
            DispatchQueue.main.async { [weak self] in
                self?.refreshAll()
            }
            return
        }
        // 应用功率校正系数：把 SoC 功耗估算成整机墙功耗。
        // 系数默认 1.0（无校正），用户可在设置里用智能插座标定（通常 1.1~1.4）。
        let corrected = sample.applying(correctionFactor: prefs.powerCorrectionFactor)
        lastSample = corrected
        store.add(sample: corrected)
        // 告警评估用校正后的功率（告警阈值按墙功耗理解更直观）。
        alertManager.evaluate(currentW: corrected.totalMW / 1000, sample: corrected)
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusItemTitle()
            self?.refreshAll()
        }
    }

    /// 刷新面板内容（若已加载）。
    private func refreshAll() {
        guard popover.isShown, let pc = panelController else { return }
        let snap = store.currentSnapshot()
        pc.refresh(snapshot: snap, sample: lastSample)
    }

    private func observePrefs() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged),
            name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(privilegeGranted),
            name: .privilegeGranted, object: nil)
    }

    // MARK: - 右键设置菜单

    /// 构建右键设置菜单。NSMenu 系统托管，无布局问题。
    private func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 采样间隔子菜单
        let intervalMenu = NSMenu()
        for sec in [1, 5, 15, 30, 60] {
            let item = intervalMenu.addItem(withTitle: "\(sec)s", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.state = prefs.sampleIntervalSec == sec ? .on : .off
            item.representedObject = sec
        }
        menu.addItem(withTitle: NSLocalizedString("menu.interval", value: "采样间隔", comment: ""), action: nil, keyEquivalent: "").submenu = intervalMenu

        // 货币子菜单
        let currencyMenu = NSMenu()
        for c in Currency.allCases {
            let item = currencyMenu.addItem(withTitle: c.displayName, action: #selector(setCurrency(_:)), keyEquivalent: "")
            item.target = self
            item.state = prefs.currency == c ? .on : .off
            item.representedObject = c.rawValue
        }
        menu.addItem(withTitle: NSLocalizedString("menu.currency", value: "货币", comment: ""), action: nil, keyEquivalent: "").submenu = currencyMenu

        // 电价（极简弹窗输入）
        let priceItem = menu.addItem(withTitle: String(format: NSLocalizedString("menu.price", value: "电价: %.2f", comment: ""), prefs.pricePerKWh), action: #selector(editPrice), keyEquivalent: "")
        priceItem.target = self

        // 校正系数子菜单
        let corrMenu = NSMenu()
        for factor in [1.0, 1.1, 1.2, 1.3, 1.5] {
            let item = corrMenu.addItem(withTitle: String(format: "×%.1f", factor), action: #selector(setCorrection(_:)), keyEquivalent: "")
            item.target = self
            item.state = abs(prefs.powerCorrectionFactor - factor) < 0.001 ? .on : .off
            item.representedObject = factor
        }
        menu.addItem(withTitle: NSLocalizedString("menu.correction", value: "校正系数", comment: ""), action: nil, keyEquivalent: "").submenu = corrMenu

        menu.addItem(NSMenuItem.separator())

        // 状态栏显示模式子菜单
        let modeMenu = NSMenu()
        for mode in StatusItemMode.allCases {
            let item = modeMenu.addItem(withTitle: mode.shortLabel, action: #selector(setStatusMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = prefs.statusItemMode == mode ? .on : .off
            item.representedObject = mode.rawValue
        }
        menu.addItem(withTitle: NSLocalizedString("menu.statusbar", value: "状态栏显示", comment: ""), action: nil, keyEquivalent: "").submenu = modeMenu

        // 语言子菜单
        let langMenu = NSMenu()
        for lang in AppLanguage.allCases {
            let item = langMenu.addItem(withTitle: lang.displayName, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.state = prefs.appLanguage == lang ? .on : .off
            item.representedObject = lang.rawValue
        }
        menu.addItem(withTitle: NSLocalizedString("menu.language", value: "语言", comment: ""), action: nil, keyEquivalent: "").submenu = langMenu

        menu.addItem(NSMenuItem.separator())

        // 告警开关
        let powerAlert = menu.addItem(withTitle: NSLocalizedString("menu.powerAlert", value: "功率告警", comment: ""), action: #selector(togglePowerAlert), keyEquivalent: "")
        powerAlert.target = self
        powerAlert.state = prefs.alertPowerEnabled ? .on : .off
        let budgetAlert = menu.addItem(withTitle: NSLocalizedString("menu.budgetAlert", value: "日预算告警", comment: ""), action: #selector(toggleBudgetAlert), keyEquivalent: "")
        budgetAlert.target = self
        budgetAlert.state = prefs.alertBudgetEnabled ? .on : .off
        // 阈值编辑（弹输入框）
        menu.addItem(withTitle: String(format: NSLocalizedString("menu.powerThreshold", value: "功率阈值: %.0fW", comment: ""), prefs.alertPowerThresholdW), action: #selector(editPowerThreshold), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(format: NSLocalizedString("menu.budgetThreshold", value: "日预算: %.2f", comment: ""), prefs.alertBudgetThreshold), action: #selector(editBudgetThreshold), keyEquivalent: "").target = self

        // 开机自启
        let launch = menu.addItem(withTitle: NSLocalizedString("settings.launchAtLogin", value: "开机自启", comment: ""), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status != .notRegistered ? .on : .off

        menu.addItem(NSMenuItem.separator())

        // 导出 CSV
        menu.addItem(withTitle: NSLocalizedString("settings.export", value: "导出 CSV", comment: ""), action: #selector(exportCSVFromMenu), keyEquivalent: "").target = self

        // 授权（若未授权才显示）
        if PrivilegeManager.currentStatus() == .missing {
            menu.addItem(withTitle: NSLocalizedString("privilege.button", value: "一键授权", comment: ""), action: #selector(grantFromMenu), keyEquivalent: "").target = self
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: NSLocalizedString("menu.checkUpdate", value: "检查更新…", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: NSLocalizedString("menu.quit", value: "退出 PowerCumul", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return menu
    }

    // 菜单 action 方法
    @objc private func setInterval(_ item: NSMenuItem) {
        if let sec = item.representedObject as? Int { prefs.sampleIntervalSec = sec }
    }
    @objc private func setCurrency(_ item: NSMenuItem) {
        if let code = item.representedObject as? String, let c = Currency(rawValue: code) { prefs.currency = c }
    }
    @objc private func setCorrection(_ item: NSMenuItem) {
        if let f = item.representedObject as? Double { prefs.powerCorrectionFactor = f }
    }
    @objc private func setStatusMode(_ item: NSMenuItem) {
        if let raw = item.representedObject as? Int, let mode = StatusItemMode(rawValue: raw) { prefs.statusItemMode = mode }
    }
    @objc private func setLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String,
              let lang = AppLanguage(rawValue: code), lang != prefs.appLanguage else { return }
        prefs.appLanguage = lang
        relaunch()
    }
    @objc private func togglePowerAlert() {
        prefs.alertPowerEnabled.toggle()
        if prefs.alertPowerEnabled { AlertManager.requestAuthorizationShared() }
    }
    @objc private func toggleBudgetAlert() {
        prefs.alertBudgetEnabled.toggle()
        if prefs.alertBudgetEnabled { AlertManager.requestAuthorizationShared() }
    }
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .notRegistered { try? service.register() }
        else { try? service.unregister() }
    }
    /// 检查更新：打开 GitHub Releases 页（轻量方案，不集成 Sparkle）。
    @objc private func checkForUpdates() {
        if let url = URL(string: "https://github.com/StruggleYang/PowerCumul/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func exportCSVFromMenu() {
        _ = CSVExporter.export(snapshot: store.currentSnapshot(), prefs: prefs)
    }
    @objc private func grantFromMenu() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PrivilegeManager.requestPrivilege()
            DispatchQueue.main.async { [weak self] in
                self?.sampleOnce()
                self?.refreshAll()
            }
        }
    }

    /// 电价编辑：极简弹窗（单个输入框）。
    @objc private func editPrice() {
        if let v = promptNumber(title: NSLocalizedString("menu.price", value: "电价", comment: ""),
                                hint: NSLocalizedString("menu.priceHint", value: "每千瓦时价格", comment: ""),
                                current: prefs.pricePerKWh), v > 0 {
            prefs.pricePerKWh = v
        }
    }

    @objc private func editPowerThreshold() {
        if let v = promptNumber(title: NSLocalizedString("menu.powerThreshold", value: "功率阈值", comment: ""),
                                hint: NSLocalizedString("menu.powerThresholdHint", value: "超过此功率(W)时通知", comment: ""),
                                current: prefs.alertPowerThresholdW), v > 0 {
            prefs.alertPowerThresholdW = v
        }
    }

    @objc private func editBudgetThreshold() {
        if let v = promptNumber(title: NSLocalizedString("menu.budgetThreshold", value: "日预算", comment: ""),
                                hint: NSLocalizedString("menu.budgetThresholdHint", value: "超过此费用时通知", comment: ""),
                                current: prefs.alertBudgetThreshold), v > 0 {
            prefs.alertBudgetThreshold = v
        }
    }

    /// 通用数值输入弹窗，返回用户输入的双精度数（取消则 nil）。
    private func promptNumber(title: String, hint: String, current: Double) -> Double? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = hint
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: NSLocalizedString("menu.cancel", value: "取消", comment: ""))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        input.doubleValue = current
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.doubleValue : nil
    }

    /// 重启自身：用 `open` 重新拉起 .app，再退出当前进程。
    private func relaunch() {
        guard let appURL = Bundle.main.bundleURL.path.isEmpty ? nil : Bundle.main.bundleURL else { return }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", appURL.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    /// 面板内一键授权成功后，立即开始采样（首次授权场景）。
    @objc private func privilegeGranted() {
        DispatchQueue.main.async { [weak self] in
            self?.sampleOnce()
            self?.refreshAll()
        }
    }

    @objc private func prefsChanged() {
        // 间隔变化需重建定时器。
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusItemTitle()
            self?.scheduleNext()
        }
    }
}
