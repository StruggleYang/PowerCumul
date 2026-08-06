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
    private var settingsWindow: SettingsWindowController?

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
            button.action = #selector(togglePopover(_:))
        }
        updateStatusItemTitle()
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettingsRequested),
            name: .openSettingsRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChangeRequested),
            name: .languageChangeRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsWindowClosed),
            name: .settingsWindowClosed, object: nil)
    }

    /// 打开独立设置窗口（若已打开则前置）。
    /// 菜单栏 App（.accessory 策略）下，新窗口需要显式激活才能显示到前台。
    @objc private func openSettingsRequested() {
        // 先关闭弹出面板，避免遮挡焦点切换。
        if popover.isShown { popover.performClose(nil) }

        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(prefs: prefs, store: store)
        }

        // 顺序很关键：先切 regular 让窗口能进入循环，再 show，再强制置前。
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.show()

        // 激活到前台（macOS 14+ 用无参 activate，旧系统回退）。
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // orderFrontRegardless 是最强制的显示方式，确保窗口可见。
        settingsWindow?.window?.orderFrontRegardless()
    }

    /// 设置窗口关闭：切回 accessory（无 Dock 图标）+ 置空引用。
    @objc private func settingsWindowClosed() {
        NSApp.setActivationPolicy(.accessory)
        settingsWindow = nil
    }

    /// 设置窗口切换语言 → 保存偏好已由 SettingsWindowController 完成，这里执行重启。
    @objc private func languageChangeRequested() {
        relaunch()
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
