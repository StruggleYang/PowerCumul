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
    private lazy var processAlertManager = ProcessAlertManager(prefs: prefs)
    private lazy var statusExporter = StatusExporter(prefs: prefs, store: store, processStore: processStore)
    private lazy var chargeController = ChargeController(prefs: prefs)
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
        statusExporter.start()   // 每分钟写出 status.json 供外部脚本/监控读取
        observePrefs()
        // 探测充电控制能力并补写已存限充（固件模式幂等；legacy 起维护循环）。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.chargeController.refreshAndApply()
        }
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

    /// 刷新状态栏文字。全部单行常规字号；唯一例外：仅勾选网速组件时，
    /// ↑↓ 拆成上下两行 9pt 小字（状态栏 ~22pt 高度内正好放下）。
    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let snap = store.currentSnapshot()
        let comps = prefs.statusComponents
        guard !comps.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

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
        // 电池：外接电源 🔌 / 使用电池 🔋。无电池设备（mini）上勾选了也不显示。
        if comps.contains(.battery), BatteryMonitor.hasBattery() {
            let batt = BatteryMonitor.current()
            if let lvl = batt.levelPercent {
                parts.append("\(batt.isExternalConnected ? "🔌" : "🔋")\(lvl)%")
            }
        }

        let normalFont = NSFont.systemFont(ofSize: 11)   // 菜单栏默认字号
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 0.85   // 压缩行高，让两行文本装进状态栏固定高度

        var lines: [(String, NSFont)] = []
        if comps.contains(.net) {
            let up = "↑\(NetMonitor.format(netMonitor.upBytesPerSec))"
            let down = "↓\(NetMonitor.format(netMonitor.downBytesPerSec))"
            if parts.isEmpty {
                // 仅网速：↑↓ 上下两行小字。
                lines = [(up, smallFont), (down, smallFont)]
            } else {
                // 与其他组件混排：保持单行，网速内联回常规写法。
                parts.append("\(up) \(down)")
                lines = [(parts.joined(separator: " · "), normalFont)]
            }
        } else if !parts.isEmpty {
            lines = [(parts.joined(separator: " · "), normalFont)]
        }

        let attr = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            // 首行前置空格与图标留间距，其余行以 \n 换行。
            let prefix = i == 0 ? " " : "\n"
            attr.append(NSAttributedString(string: prefix + line.0,
                                           attributes: [.font: line.1, .paragraphStyle: para]))
        }
        button.attributedTitle = attr

        // 功率超阈值时图标染红，比通知更即时的视觉反馈（恢复后还原模板色）。
        button.contentTintColor = w >= prefs.alertPowerThresholdW ? .systemRed : nil
    }

    private func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    // MARK: - 面板

    private func buildPopover() {
        panelController = PanelController(prefs: prefs)
        panelController.attachStore(store)
        panelController.attachProcessStore(processStore)
        panelController.attachChargeController(chargeController)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panelController
        // 面板尺寸由 PanelController 按内容自适应（preferredContentSize），
        // 笔记本多一块电池卡片时自动加高，无需在此按设备硬编码高度。
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
        processAlertManager.evaluate(rows: sample.processEnergy,
                                     systemW: corrected.totalMW / 1000)
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
        // 组件开关：勾选组合，全不勾 = 仅图标。电池组件仅在有电池的设备上出现。
        let hasBattery = BatteryMonitor.hasBattery()
        for comp in StatusComponent.all {
            if comp == .battery && !hasBattery { continue }
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

        // 充电上限子菜单（仅笔记本且 SMC 支持充电控制时显示）
        if BatteryMonitor.hasBattery() {
            let chargeStatus = PrivilegeManager.chargeStatus()
            if chargeStatus == .missing {
                let auth = menu.addItem(withTitle: NSLocalizedString("menu.chargeLimit.auth", value: "充电控制需授权…", comment: ""), action: #selector(grantFromMenu), keyEquivalent: "")
                auth.target = self
            } else if chargeController.isCapable {
                let limitMenu = NSMenu()
                let off = limitMenu.addItem(withTitle: NSLocalizedString("menu.chargeLimit.off", value: "关闭（充满）", comment: ""), action: #selector(setChargeLimit(_:)), keyEquivalent: "")
                off.target = self
                off.representedObject = 100
                off.state = !chargeController.isActive ? .on : .off
                limitMenu.addItem(NSMenuItem.separator())
                for pct in [80, 85, 90, 95] {
                    let item = limitMenu.addItem(withTitle: "\(pct)%", action: #selector(setChargeLimit(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = pct
                    item.state = chargeController.limitPercent == pct ? .on : .off
                }
                let custom = limitMenu.addItem(withTitle: NSLocalizedString("menu.chargeLimit.custom", value: "自定义…", comment: ""), action: #selector(editChargeLimit), keyEquivalent: "")
                custom.target = self
                menu.addItem(withTitle: NSLocalizedString("menu.chargeLimit", value: "充电上限", comment: ""), action: nil, keyEquivalent: "").submenu = limitMenu
            }
        }

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
        let processAlert = menu.addItem(withTitle: NSLocalizedString("menu.processAlert", value: "进程耗电告警", comment: ""), action: #selector(toggleProcessAlert), keyEquivalent: "")
        processAlert.target = self
        processAlert.state = prefs.processAlertEnabled ? .on : .off
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

        // 数据管理子菜单：重置 / 备份 / 恢复 / Finder 查看
        let dataMenu = NSMenu()
        let dataItems: [(String, Selector)] = [
            (NSLocalizedString("menu.resetCumulative", value: "重新累计…", comment: ""), #selector(resetCumulative(_:))),
            (NSLocalizedString("menu.backupData", value: "备份数据…", comment: ""), #selector(backupData(_:))),
            (NSLocalizedString("menu.restoreData", value: "恢复数据…", comment: ""), #selector(restoreData(_:))),
            (NSLocalizedString("menu.revealData", value: "在 Finder 中查看数据", comment: ""), #selector(revealData(_:))),
        ]
        for (title, sel) in dataItems {
            let item = dataMenu.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(withTitle: NSLocalizedString("menu.data", value: "数据", comment: ""), action: nil, keyEquivalent: "").submenu = dataMenu

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
    @objc private func toggleProcessAlert() {
        prefs.processAlertEnabled.toggle()
        if prefs.processAlertEnabled { AlertManager.requestAuthorizationShared() }
    }

    // MARK: - 数据管理

    /// 重新累计：清零累计电量/费用基线（图表历史保留），需确认。
    @objc private func resetCumulative(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = NSLocalizedString("menu.resetCumulative", value: "重新累计", comment: "")
        a.informativeText = NSLocalizedString("reset.confirm",
            value: "累计电量与累计费用将清零并从现在重新计算。\n图表历史（24H/7D/30D）不受影响。确定吗？", comment: "")
        a.alertStyle = .warning
        a.addButton(withTitle: NSLocalizedString("reset.confirmButton", value: "重新累计", comment: ""))
        a.addButton(withTitle: NSLocalizedString("menu.cancel", value: "取消", comment: ""))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.resetCumulative()
        refreshAll()
    }

    /// 备份数据：把 state.json / samples.jsonl / process_energy.jsonl 拷到用户选择的目标夹。
    @objc private func backupData(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("backup.prompt", value: "备份到此处", comment: "")
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let files = store.dataFileURLs + [processStore.dataFileURL]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var copied = 0
            for src in files where fm.fileExists(atPath: src.path) {
                let dst = dir.appendingPathComponent(src.lastPathComponent)
                try? fm.removeItem(at: dst)
                if (try? fm.copyItem(at: src, to: dst)) != nil { copied += 1 }
            }
            DispatchQueue.main.async {
                self?.dataDoneAlert(
                    text: L10n.tr("backup.done", "已备份 %d 个文件到 %@", copied, dir.path))
            }
        }
    }

    /// 恢复数据：从备份夹覆盖当前数据，完成后重启应用生效。
    @objc private func restoreData(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("restore.prompt", value: "选择备份夹", comment: "")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        // 至少要有 state.json 才算有效备份。
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path) else {
            dataDoneAlert(text: NSLocalizedString("restore.invalid", value: "所选文件夹不包含 state.json，不是有效的备份", comment: ""))
            return
        }
        let a = NSAlert()
        a.messageText = NSLocalizedString("restore.confirmTitle", value: "恢复数据", comment: "")
        a.informativeText = L10n.tr("restore.confirm", "将用 %@ 中的备份覆盖当前数据，并重启应用生效。确定吗？", dir.path)
        a.alertStyle = .warning
        a.addButton(withTitle: NSLocalizedString("restore.confirmButton", value: "恢复并重启", comment: ""))
        a.addButton(withTitle: NSLocalizedString("menu.cancel", value: "取消", comment: ""))
        guard a.runModal() == .alertFirstButtonReturn else { return }

        streamer?.stop()
        let files = store.dataFileURLs + [processStore.dataFileURL]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            for dst in files {
                let src = dir.appendingPathComponent(dst.lastPathComponent)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
            DispatchQueue.main.async { self?.relaunch() }
        }
    }

    /// 在 Finder 中展示数据目录。
    @objc private func revealData(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([EnergyStore.dataDirectory])
    }

    private func dataDoneAlert(text: String) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .informational
        a.runModal()
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PrivilegeManager.requestPrivilege()
            // 授权同时覆盖充电控制：探测能力并补写已存限充。
            self?.chargeController.refreshAndApply()
            DispatchQueue.main.async { [weak self] in
                self?.startStreamer()
                self?.refreshAll()
            }
        }
    }

    // MARK: - 充电控制

    @objc private func setChargeLimit(_ item: NSMenuItem) {
        guard let pct = item.representedObject as? Int else { return }
        applyChargeLimit(pct)
    }

    @objc private func editChargeLimit() {
        let current = chargeController.isActive ? chargeController.limitPercent : 80
        if let v = promptNumber(title: NSLocalizedString("menu.chargeLimit", value: "充电上限", comment: ""),
                                hint: NSLocalizedString("charge.customHint", value: "上限百分比（20–99），回落 2% 后再充", comment: ""),
                                current: Double(current)) {
            applyChargeLimit(Int(v))
        }
    }

    /// 应用充电上限（后台跑 helper；100 = 关闭恢复充满）。失败弹错误，成功刷新 UI。
    private func applyChargeLimit(_ pct: Int) {
        let clamped = min(99, max(20, pct))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error: String?
            if clamped >= 100 {
                self.chargeController.clearLimit()
                error = nil
            } else {
                error = self.chargeController.setLimit(clamped)
            }
            DispatchQueue.main.async {
                if let error {
                    self.dataDoneAlert(text: String(format: NSLocalizedString("charge.failed", value: "设置失败：%@", comment: ""), error))
                }
                self.refreshAll()
                self.updateStatusItemTitle()
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
        // legacy 充电控制在退出前放开充电：app 不在时没人维持滞回，
        // 若停在停充状态退出，插着电电池也充不进。
        chargeController.prepareForTermination()
        // 退出前终止常驻 powermetrics，避免遗留孤儿进程。
        streamer?.stop()
        statusExporter.stop()
        // 补写进行中的进程能耗桶（同一桶重启后由 load() 续算）。
        processStore.flush()
    }
}
