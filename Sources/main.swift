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
    private let processStore = ProcessEnergyStore()
    private lazy var alertManager = AlertManager(prefs: prefs, store: store)
    private var streamer: PowerStreamer?
    private let netMonitor = NetMonitor()
    private var netTimer: Timer?
    private var lastSample: PowerSample?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.cleanupOldBundle()   // 清理上次更新遗留的旧包
        buildStatusItem()
        buildPopover()
        startSampling()
        startNetMonitor()
        observePrefs()
    }

    /// 网速轮询：2s 一次（计数器差值需要自己的节拍，与功率流独立）。
    private func startNetMonitor() {
        netMonitor.poll()   // 建立基线
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.netMonitor.poll()
            // 勾了网速组件才需要随轮询刷新标题（其余组件随功率采样刷新）。
            if self?.prefs.statusComponents.contains(.net) == true {
                self?.updateStatusItemTitle()
            }
        }
        t.tolerance = 0.5   // 允许系统合并定时器唤醒，省电
        netTimer = t
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

    /// 刷新状态栏文字：按勾选组件拼接（功率/费用/电量/网速），全不勾 = 仅图标。
    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let snap = store.currentSnapshot()
        let comps = prefs.statusComponents
        guard !comps.isEmpty else { button.title = ""; return }

        let w = (lastSample?.totalMW ?? snap.currentMW) / 1000
        // 电量/费用均展示累计（语义一致；今日电费空闲量级下恒为 0.00 无信息量）。
        let kwh = snap.totalWh / 1000
        let cost = kwh * prefs.pricePerKWh

        var parts: [String] = []
        if comps.contains(.power) {
            parts.append("\(L10n.decimal(w, fractionDigits: 1))\(tr("power.unit"))")
        }
        if comps.contains(.cost) {
            parts.append(L10n.cumulativeCost(cost, currency: prefs.currency))
        }
        if comps.contains(.kwh) {
            parts.append("\(L10n.decimal(kwh, fractionDigits: 3))\(tr("kWh.unit"))")
        }
        if comps.contains(.net) {
            parts.append("↑\(NetMonitor.format(netMonitor.upBytesPerSec)) ↓\(NetMonitor.format(netMonitor.downBytesPerSec))")
        }
        button.title = " " + parts.joined(separator: " · ")
    }

    private func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    // MARK: - 面板

    private func buildPopover() {
        panelController = PanelController(prefs: prefs)
        panelController.attachStore(store)
        panelController.attachProcessStore(processStore)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panelController
        popover.contentSize = NSSize(width: 340, height: 580)
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
        // 权限未授予时不启动（授权成功后由 privilegeGranted 通知拉起）。
        guard PrivilegeManager.currentStatus() == .granted else { return }
        startStreamer()
    }

    /// 启动连续流式采样：powermetrics 常驻进程逐块回调，100% 时间覆盖。
    private func startStreamer() {
        guard streamer == nil else { return }   // 已在运行
        let s = PowerStreamer(intervalMs: max(1, prefs.sampleIntervalSec) * 1000)
        s.onSample = { [weak self] sample in
            self?.handleStreamSample(sample)
        }
        streamer = s
        s.start()
    }

    /// 流式采样回调（后台线程）：校正 → 累计 → 告警 → 刷 UI。
    private func handleStreamSample(_ sample: PowerSample) {
        // 应用功率校正系数：把 SoC 功耗估算成整机墙功耗（默认 ×1.2，可标定）。
        let corrected = sample.applying(correctionFactor: prefs.powerCorrectionFactor)
        lastSample = corrected
        store.add(sample: corrected)
        // 进程能耗是相对占比，不吃校正系数，用原始采样投喂。
        processStore.add(rows: sample.processEnergy, at: sample.timestamp)
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
        // 组件开关：勾选组合，全不勾 = 仅图标。
        for comp in StatusComponent.all {
            let item = modeMenu.addItem(withTitle: comp.label, action: #selector(toggleStatusComponent(_:)), keyEquivalent: "")
            item.target = self
            item.state = prefs.statusComponents.contains(comp) ? .on : .off
            item.representedObject = comp.rawValue
        }
        modeMenu.addItem(NSMenuItem.separator())
        let iconOnly = modeMenu.addItem(withTitle: NSLocalizedString("menu.iconOnly", value: "仅图标", comment: ""), action: #selector(iconOnlyStatus), keyEquivalent: "")
        iconOnly.target = self
        iconOnly.state = prefs.statusComponents.isEmpty ? .on : .off
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
    @objc private func toggleStatusComponent(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? Int else { return }
        var comps = prefs.statusComponents
        let comp = StatusComponent(rawValue: raw)
        if comps.contains(comp) { comps.remove(comp) } else { comps.insert(comp) }
        prefs.statusComponents = comps
    }

    @objc private func iconOnlyStatus() {
        prefs.statusComponents = []
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
    /// 检查更新：拉 GitHub Releases 最新版比对，新版本则应用内下载换装重启。
    @objc private func checkForUpdates() {
        let checking = NSAlert()
        checking.messageText = NSLocalizedString("update.checking", value: "正在检查更新…", comment: "")
        checking.alertStyle = .informational
        // 非阻塞提示：短延迟后自动关（结果对话框随后弹出）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { checking.window.orderOut(nil) }

        Updater.fetchLatest { [weak self] rel in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let rel = rel else {
                    self.updateAlert(text: NSLocalizedString("update.fetchFail", value: "检查更新失败（网络错误）", comment: ""))
                    return
                }
                let cur = Updater.currentVersion()
                if !Updater.isNewer(rel.version, than: cur) {
                    self.updateAlert(text: String(format: NSLocalizedString("update.upToDate", value: "已是最新版本 %@", comment: ""), cur))
                    return
                }
                // 有新版本：确认后安装。
                let a = NSAlert()
                a.messageText = String(format: NSLocalizedString("update.found", value: "发现新版本 v%@", comment: ""), rel.version)
                a.informativeText = String(rel.notes.prefix(400))
                a.alertStyle = .informational
                a.addButton(withTitle: NSLocalizedString("update.install", value: "下载并安装", comment: ""))
                a.addButton(withTitle: NSLocalizedString("menu.cancel", value: "取消", comment: ""))
                guard a.runModal() == .alertFirstButtonReturn else { return }

                // 后台下载安装（同步等待 + 换装重启）。
                DispatchQueue.global(qos: .userInitiated).async {
                    let err = Updater.downloadAndInstall(rel)
                    if let err = err {
                        DispatchQueue.main.async {
                            self.updateAlert(text: String(format: NSLocalizedString("update.installFail", value: "更新失败：%@", comment: ""), err))
                        }
                    }
                    // 成功路径：downloadAndInstall 内部已触发重启，无需处理。
                }
            }
        }
    }

    private func updateAlert(text: String) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .informational
        a.runModal()
    }

    @objc private func exportCSVFromMenu() {
        _ = CSVExporter.export(snapshot: store.currentSnapshot(), prefs: prefs)
    }
    @objc private func grantFromMenu() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PrivilegeManager.requestPrivilege()
            DispatchQueue.main.async { [weak self] in
                self?.startStreamer()
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

    /// 面板内一键授权成功后，立即开始流式采样（首次授权场景）。
    @objc private func privilegeGranted() {
        DispatchQueue.main.async { [weak self] in
            self?.startStreamer()
            self?.refreshAll()
        }
    }

    @objc private func prefsChanged() {
        // 采样间隔变化 → 用新间隔重启流。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateStatusItemTitle()
            self.streamer?.restart(intervalMs: max(1, self.prefs.sampleIntervalSec) * 1000)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前终止常驻 powermetrics，避免遗留孤儿进程。
        streamer?.stop()
        // 补写进行中的进程能耗桶（同一桶重启后由 load() 续算）。
        processStore.flush()
    }
}
