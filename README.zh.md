<p align="center">
  <img src="docs/icon.png" width="128" alt="PowerCumul 图标" />
</p>

<h1 align="center">PowerCumul</h1>

<p align="center">Mac mini 用电累计监控</p>

<p align="center">
  <strong>中文</strong> | <a href="./README.md">English</a>
</p>

---

一个轻量的 macOS 菜单栏 App，用于监控 Mac mini 的累计用电量。状态栏点开即看面板：实时功率、今日累计 kWh、24 小时功率曲线、估算电费。**纯软件方案，不依赖任何硬件。**

> 适用于 Apple Silicon (M1/M2/M3/M4) 的 Mac mini / MacBook / iMac，macOS 13+。

---

## ✨ 功能

- **状态栏实时显示**：组件自由组合 —— 功率 / 累计费用 / 累计电量 / 网速 / 电池（笔记本）按需勾选（默认功率+费用），全不勾即仅图标
- **弹出面板**（左键）：实时功率 + CPU/GPU/ANE 分量、今日累计 kWh、估算电费
- **电池信息**（仅笔记本）：面板电池卡片 —— 电量、充电状态与充满/剩余时间估算、健康度、循环次数、温度、充/放电功率；Mac mini 等无电池设备自动隐藏（状态栏电池组件也只在笔记本上出现）
- **充电上限**（仅笔记本，AlDente 免费版同款）：右键菜单设定 80/85/90/95% 或自定义（20–99），固件级限充由 SMC 固件自行维持滞回，老固件走软件滞回循环；「关闭」即恢复充满。面板电池卡片显示「已到充电上限 / 限充 N%」状态
- **右键菜单**（右键）：全部设置 —— 采样间隔、货币、电价、校正系数、状态栏模式、语言、告警、开机自启、导出 CSV、检查更新
- **应用内更新**：右键「检查更新」直接拉取 GitHub 最新 Release，下载换装原地重启，无需浏览器/手动下载（含不限流回退通道）
- **告警通知**：功率超过阈值 / 今日电费超过预算时弹系统通知（防抖，不刷屏）
- **多时段图表**：24H / 7D / 30D 功率趋势切换，Core Graphics 手绘
- **数据导出**：CSV 导出（天级汇总 + 小时级明细），Excel/Numbers 直接打开
- **多货币电价**：12 种常用货币预设（¥ $ € £ ₩ ₽ ₹ NT$ HK$ A$ C$）+ 自定义电价
- **完整中英双语**：右键菜单切换语言（跟随系统/中文/English），重启即生效
- **功率校正系数**：默认 ×1.2 把 SoC 功耗估算成整机墙功耗（有智能插座可标定）
- **累计用电**：自首次运行起的总用电量（Wh/kWh），断电重启后自动续算
- **应用内授权**：一键配置 powermetrics 权限（系统原生密码框），无需碰终端

---

## 💾 数据存储

全部本地存储，**不上云、不联网上报**。采用双层结构兼顾性能与断电安全：

| 内容 | 位置 | 说明 |
|---|---|---|
| 原始采样流 | `~/Library/Application Support/PowerCumul/samples.jsonl` | JSONL **只追加**，每次采样写一行（~80B）。断电最多丢最后一行，坏一行不影响其他；想重算聚合随时可从原始流重建 |
| 聚合状态 | `~/Library/Application Support/PowerCumul/state.json` | 小文件原子重写，存累计/今日/小时桶/天桶。写入量小、恒定 |
| 偏好设置 | UserDefaults（`~/Library/Preferences/com.powercumul.app.plist`） | 系统托管 |

> 为什么分两层：原始流只追加（写入恒定、不随历史增长、断电安全）；聚合状态文件小、全量重写代价低。避免每次采样都重写整个大文件。

---

## 🌐 国际化

**支持 App 内一键切换语言**（面板「设置 → 语言」），无需改 macOS 系统语言：

- **跟随系统** / **中文** / **English** 三选一
- 切换后自动重启 App，新语言立即全程生效（文本 + 数字格式）
- 默认跟随 macOS 系统语言

数字、日期、货币符号按所选语言的地区格式化（如 `1,50 W` vs `1.5 W`，`¥0.36` vs `$0.05`）。

> 技术说明：macOS 的本地化在 App 启动时缓存，运行中改语言不会自动刷新。因此切换语言采用「保存偏好 → 重启 App」的方式（约 1 秒），保证文本与数字格式立即完全一致，避免半中半英的中间态。

如需新增语言，复制 `Sources/Resources/en.lproj/` 为 `<语言>.lproj` 并翻译其中的 `Localizable.strings`，再在 `AppLanguage` 枚举加一项即可。

---

## ⚙️ 工作原理

本工具通过 macOS 自带的 `powermetrics` 命令（需 root 权限）采样 CPU / GPU / ANE / SoC 的瞬时功率（毫瓦），按时间积分得到累计能量：

```
E(Wh) += P(mW) × Δt(秒) / 3600 / 1000
```

数据采用双层持久化：原始采样追加到 `samples.jsonl`，聚合状态写入 `state.json`（详见上文「数据存储」）。

### 关于精度的说明（重要）

macOS 软件层**无法获取整机墙功耗（wall power）**——Mac mini 没有电池或 UPS，系统不暴露整机输入功率。因此本工具统计的是 **SoC 累计功耗近似值**，会比真实用电量**偏低**约 10%–30%（未计入内存、SSD、USB 外设、电源转换损耗）。

- 想看**趋势、相对用电量、负载时段**：本工具完全够用。
- 想要**精确到度数的真实用电量**（比如算电费）：请用智能插座（硬件方案），这是 macOS 软件方案的根本限制。

面板上会明确标注"SoC 估算值"，避免误读。

---

## 🚀 安装与使用

### 1. 构建

```bash
./build.sh
```

需要 Xcode Command Line Tools（`xcode-select --install`），无需完整 Xcode。产出 `build/PowerCumul.app`。

### 2. 运行

```bash
open build/PowerCumul.app
```

菜单栏出现 ⚡ 图标。

- **左键** ⚡ → 监控面板（实时功率、今日电量、趋势图、电费）
- **右键** ⚡ → 设置菜单（采样间隔、货币、电价、校正系数、状态栏模式、语言、告警、开机自启、导出 CSV、检查更新）

首次运行时，点开面板会看到橙色提示「需要授权才能采样功率」，点击 **「一键授权」** 按钮 → 系统弹出原生密码框 → 输入一次开机密码 → 完成。之后永久免密，无需再碰终端。也可右键 → 「一键授权」。

> 权限授权是应用内完成的：通过系统标准授权机制（`do shell script ... with administrator privileges`）把**仅 powermetrics 一个程序**的免密规则写入 `/etc/sudoers.d/powercumul`，不放开其他 sudo 权限。
>
> 不喜欢 GUI 方式？也可用终端（效果相同）：`sudo ./scripts/install-sudoers.sh`

### 3. 开机自启

右键 ⚡ → 「开机自启」，即用 `SMAppService`（macOS 13+ 现代登录项）注册。

---

## 📦 分发

### 打包 DMG

```bash
./scripts/package-dmg.sh
```

产出 `build/PowerCumul-1.0.dmg`（含 App + Applications 软链，拖拽即装）。把这个 DMG 发给朋友、上传到 GitHub Release 即可。

### 接收方首次打开（重要）

本应用是 **ad-hoc 签名**（无 Apple Developer 账号 $99/年），macOS Gatekeeper 会拦截。接收方首次打开需手动信任**一次**：

1. 在访达里**右键点击** PowerCumul.app → **打开**
2. 弹出警告点 **「仍要打开」**
3. 之后正常使用，不再提示

（直接双击会被拦且无「仍要打开」选项——必须用右键打开这条路。首次运行后权限授权流程同上。）

### 想做正式签名公证分发？

若有 Apple Developer 账号，可加上 Developer ID 签名 + notarize，做成双击即跑。需要时再补自动化脚本。

---

## 🔄 发布流程

发布通过 GitHub Actions 自动化。发新版本只需：

```bash
git tag v0.02
git push origin v0.02
# GitHub Actions 自动构建、打包 DMG、创建 Release
```

下载地址：[GitHub Releases](https://github.com/StruggleYang/PowerCumul/releases)

---

## 📁 项目结构

```
PowerCumul/
├── Sources/
│   ├── main.swift            # AppDelegate：状态栏 / 弹出面板 / 右键菜单设置 / 采样定时器
│   ├── PowerSampler.swift    # 调用 powermetrics + 容错解析（兼容多 macOS 版本）
│   ├── EnergyStore.swift     # 累计能量计算 + 双层持久化（samples.jsonl + state.json）
│   ├── ChartView.swift       # Core Graphics 手绘折线图（24H/7D/30D）
│   ├── PanelController.swift # NSPopover 主面板布局与刷新
│   ├── ChargeController.swift# 充电控制：能力探测 / 固件限充补写 / legacy 滞回循环
│   ├── BatteryMonitor.swift  # 电池信息只读采样（电量/健康度/循环/温度；无电池设备自动降级隐藏）
│   ├── Helper/main.swift     # powercumul-smc 特权辅助工具（root CLI，独立编译，见 build.sh）
│   ├── AlertManager.swift    # 功率/预算告警（系统通知 + 防抖）
│   ├── CSVExporter.swift     # 数据导出 CSV（天级+小时级）
│   ├── PrivilegeManager.swift# 应用内一键授权（原生密码框写 sudoers）
│   ├── Preferences.swift     # 用户偏好（间隔/电价/货币/模式/告警/区间）
│   ├── Currency.swift        # 货币/状态栏模式/语言/图表区间枚举
│   ├── L10n.swift            # 本地化封装 + locale 数字格式化
│   ├── AppIcon.icns          # 应用图标（脚本生成）
│   ├── Info.plist            # LSUIElement=true（菜单栏 App，无 Dock 图标）
│   └── Resources/*.lproj     # 中英文本地化字符串
├── scripts/
│   ├── generate-icon.sh      # 脚本化生成 squircle 闪电图标
│   ├── install-sudoers.sh    # sudo 免密配置（终端备选方式）
│   └── package-dmg.sh        # 打包 DMG 用于分发
├── .github/workflows/
│   └── release.yml           # GitHub Actions：打 tag 自动构建并发布 Release
├── build.sh                  # 一键构建（编译 + 组装 .app + 图标 + 签名）
├── README.md                 # 英文文档（主文档）
└── README.zh.md              # 中文文档（本文件）
```

---

## ❓ FAQ

**Q: 为什么状态栏/面板显示"需要 powermetrics 权限"？**
A: 还没配置 sudo 免密。点开面板，点橙色卡片里的 **「一键配置权限」** 按钮，输入一次开机密码即可（应用内完成，无需终端）。也可用终端：`sudo ./scripts/install-sudoers.sh`。

**Q: 升级 macOS 后会不会失效？**
A: 解析器采用容错策略：优先匹配新版 `Combined Power (CPU + GPU + ANE)`，回退到旧版 `Package Power`，最后回退到分量求和（CPU+GPU+ANE+DRAM）。能跨 macOS 版本稳定工作。

**Q: 数值偏低怎么办？**
A: 这是纯软件方案的固有限制（见上文"精度说明"）。若需精确数据请配合智能插座。

**Q: 怎么卸载？**
A: 删除 App 即可；清理 sudo 规则与充电控制辅助工具：`sudo rm /etc/sudoers.d/powercumul /Library/PrivilegedHelperTools/powercumul-smc`；清理数据：`rm -rf ~/Library/Application\ Support/PowerCumul`。

---

## 🔋 充电上限（笔记本专属）

原理与 AlDente / 开源 batt 相同：直接写 SMC。实现上把 SMC 读写独立成极小的 root 辅助工具 `powercumul-smc`（装到 `/Library/PrivilegedHelperTools/`，与 powermetrics 一起走 sudoers 白名单免密，一次密码授权全覆盖）。

- **固件模式**（较新固件，`bfD0/bfE0/bfF0` 键）：限充与滞回（充到上限停、回落 2% 再充）由固件自己执行，设一次持续生效，app 不在也有效
- **legacy 模式**（`CH0B+CH0C` / 老固件 `CHTE`）：SMC 只能开关充电，滞回由 app 每 30 秒维护；睡眠前自动停充防过充，**app 退出时自动放开充电**（此模式限充仅在 app 运行期间生效）

安全护栏：上限最低 20%；关闭 = 恢复充满；固件写入后回读校验；检测不到 SMC 充电键的设备（mini/台式机）完全不显示充电菜单。
