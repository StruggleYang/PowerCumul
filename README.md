<p align="center">
  <img src="docs/icon.png" width="128" alt="PowerCumul icon" />
</p>

<h1 align="center">PowerCumul</h1>

<p align="center">Mac mini Cumulative Power Monitoring</p>

<p align="center">
  <strong>English</strong> | <a href="./README.zh.md">中文</a>
</p>

---

A lightweight macOS menu bar app to track cumulative power consumption of your Mac mini. Click the status bar icon to see real-time power, today's energy in kWh, power trend charts, and estimated cost. **Pure software solution — no hardware required.**

> Works on Apple Silicon (M1/M2/M3/M4) Mac mini / MacBook / iMac, macOS 13+.

---

## ✨ Features

- **Status bar real-time display**: 5 switchable modes — Power / Cost / Energy / Power+Cost combo (default) / Icon only
- **Popover panel** (left-click): real-time power + CPU/GPU/ANE breakdown, today's kWh, estimated cost
- **Context menu** (right-click): all settings — sample interval, currency, price, correction factor, status bar mode, language, alerts, launch-at-login, export CSV, check for updates
- **Alert notifications**: power exceeds threshold / daily cost exceeds budget (debounced, no spam)
- **Multi-range charts**: 24H / 7D / 30D power trend, hand-drawn with Core Graphics
- **Data export**: CSV export (daily summary + hourly detail), opens in Excel/Numbers
- **Multi-currency pricing**: 12 common currency presets (¥ $ € £ ₩ ₽ ₹ NT$ HK$ A$ C$) + custom price
- **Full bilingual (CN/EN)**: switch language via right-click menu (Follow System / 中文 / English), restarts to apply
- **Power correction factor**: default ×1.2 estimates wall power from SoC power (calibrate with a smart plug)
- **Cumulative energy**: total consumption (Wh/kWh) since first run, auto-resumes after reboot
- **In-app authorization**: one-click `powermetrics` permission setup (native password prompt), no terminal needed

---

## 💾 Data Storage

Fully local, **no cloud, no network reporting**. Two-layer structure balancing performance and crash safety:

| Content | Location | Description |
|---|---|---|
| Raw sample stream | `~/Library/Application Support/PowerCumul/samples.jsonl` | JSONL **append-only**, one line per sample (~80B). Power loss loses at most the last line; one corrupted line doesn't affect others; aggregation can always be rebuilt from raw stream |
| Aggregated state | `~/Library/Application Support/PowerCumul/state.json` | Small file, atomic rewrite. Stores cumulative/today/hourly buckets/daily buckets. Small, constant write cost |
| Preferences | UserDefaults (`~/Library/Preferences/com.powercumul.app.plist`) | System-managed |

> Why two layers: the raw stream is append-only (constant writes, doesn't grow with history, crash-safe); the aggregation file is small, full-rewrite cost is low. Avoids rewriting a large file on every sample.

---

## 🌐 Internationalization

**Switch language in-app** (panel → Settings → Language), no need to change macOS system language:

- **Follow System** / **中文** / **English** — pick one
- Switching restarts the app, new language applies fully immediately (text + number formatting)
- Defaults to macOS system language

Numbers, dates, and currency symbols are formatted per the selected language's locale (e.g. `1.5 W` vs `1,5 W`, `¥0.36` vs `$0.05`).

> Technical note: macOS caches localization at app launch; changing language at runtime won't auto-refresh. So language switching uses "save preference → restart app" (~1 sec) to ensure text and number formats are immediately and fully consistent, avoiding a half-translated intermediate state.

To add a language: copy `Sources/Resources/en.lproj/` to `<lang>.lproj`, translate `Localizable.strings`, and add a case to the `AppLanguage` enum.

---

## ⚙️ How It Works

This tool samples instantaneous power (milliwatts) of CPU / GPU / ANE / SoC via macOS's built-in `powermetrics` command (requires root), integrating over time to get cumulative energy:

```
E(Wh) += P(mW) × Δt(seconds) / 3600 / 1000
```

Data uses two-layer persistence: raw samples append to `samples.jsonl`, aggregated state writes to `state.json` (see "Data Storage" above).

### A Note on Accuracy (Important)

macOS software layer **cannot obtain wall power (total machine input power)** — Mac mini has no battery or UPS, and the system doesn't expose total input power. So this tool reports an **approximate SoC cumulative power consumption**, which runs **10%–30% lower** than actual usage (excludes memory, SSD, USB peripherals, power conversion losses).

- For **trends, relative consumption, load patterns**: this tool is sufficient.
- For **exact real-world usage** (e.g. billing): use a smart plug (hardware solution) — this is a fundamental limitation of any macOS software approach.

The panel clearly labels this as "SoC estimate" to avoid misreading.

---

## 🚀 Installation & Usage

### 1. Build

```bash
./build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`), no full Xcode needed. Produces `build/PowerCumul.app`.

### 2. Run

```bash
open build/PowerCumul.app
```

A ⚡ icon appears in the menu bar.

- **Left-click** ⚡ → monitoring panel (real-time power, today's kWh, charts, cost)
- **Right-click** ⚡ → settings menu (sample interval, currency, price, correction, mode, language, alerts, launch-at-login, export CSV, check for updates)

On first run, opening the panel shows an orange prompt "Authorization required" — click **"Grant Access"** → a native password dialog appears → enter your login password once → done. Permanent passwordless access after that, no terminal needed. You can also grant access via right-click → "Grant Access".

> Authorization happens in-app: via the standard system authorization mechanism (`do shell script ... with administrator privileges`), writing a passwordless rule for **only the `powermetrics` program** to `/etc/sudoers.d/powercumul` — no other sudo permissions are opened up.
>
> Prefer the terminal? Same effect: `sudo ./scripts/install-sudoers.sh`

### 3. Launch at Login

Right-click ⚡ → "Launch at Login", registered via `SMAppService` (modern login item API, macOS 13+).

---

## 📦 Distribution

### Package DMG

```bash
./scripts/package-dmg.sh
```

Produces `build/PowerCumul-1.0.dmg` (App + Applications symlink, drag-to-install). Share the DMG or upload to GitHub Releases.

### First Launch for Recipients (Important)

This app is **ad-hoc signed** (no Apple Developer account at $99/yr), so macOS Gatekeeper will block it. Recipients must manually trust it **once** on first launch:

1. In Finder, **right-click** PowerCumul.app → **Open**
2. In the warning dialog, click **"Open Anyway"**
3. Works normally afterward, no more prompts

(Double-clicking directly gets blocked with no "Open Anyway" option — you must use right-click → Open. After first run, the permission authorization flow is the same as above.)

### Want proper signed & notarized distribution?

With an Apple Developer account, you can add Developer ID signing + notarization for double-click-to-run. Automation scripts can be added when needed.

---

## 📁 Project Structure

```
PowerCumul/
├── Sources/
│   ├── main.swift            # AppDelegate: status bar / popover / context-menu settings / sampling timer
│   ├── PowerSampler.swift    # powermetrics invocation + tolerant parsing (cross-macOS)
│   ├── EnergyStore.swift     # cumulative energy + two-layer persistence (samples.jsonl + state.json)
│   ├── ChartView.swift       # Core Graphics line chart (24H/7D/30D)
│   ├── PanelController.swift # NSPopover panel layout & refresh
│   ├── AlertManager.swift    # power/budget alerts (system notifications + debounce)
│   ├── CSVExporter.swift     # CSV export (daily + hourly)
│   ├── PrivilegeManager.swift# in-app authorization (native password prompt → sudoers)
│   ├── Preferences.swift     # user preferences (interval/price/currency/mode/alerts/range)
│   ├── Currency.swift        # currency/status mode/language/chart range enums
│   ├── L10n.swift            # localization helpers + locale number formatting
│   ├── AppIcon.icns          # app icon (script-generated)
│   ├── Info.plist            # LSUIElement=true (menu bar app, no Dock icon)
│   └── Resources/*.lproj     # CN/EN localized strings
├── scripts/
│   ├── generate-icon.sh      # script to generate squircle bolt icon
│   ├── install-sudoers.sh    # sudo passwordless setup (terminal alternative)
│   └── package-dmg.sh        # package DMG for distribution
├── .github/workflows/
│   └── release.yml           # GitHub Actions: auto-build & publish on tag push
├── build.sh                  # one-click build (compile + assemble .app + icon + sign)
├── README.md                 # English documentation (this file)
└── README.zh.md              # Chinese documentation
```

---

## 🔄 Release Flow

Releases are automated via GitHub Actions. To publish a new version:

```bash
git tag v0.02
git push origin v0.02
# GitHub Actions auto-builds, packages DMG, and creates the Release
```

Downloads: [GitHub Releases](https://github.com/StruggleYang/PowerCumul/releases)

---

## ❓ FAQ

**Q: Why does the panel say "powermetrics permission required"?**
A: Passwordless sudo isn't configured yet. Click "Grant Permission" in the panel, or run `sudo ./scripts/install-sudoers.sh` once.

**Q: Will it break after a macOS upgrade?**
A: The parser is tolerant: it first matches the newer `Combined Power (CPU + GPU + ANE)`, falls back to the legacy `Package Power`, then falls back to summing components (CPU+GPU+ANE+DRAM). Works stably across macOS versions.

**Q: Why are the numbers low?**
A: This is an inherent limitation of pure software solutions (see "Accuracy" above). For precise data, use a smart plug.

**Q: How to uninstall?**
A: Delete the app; clean up the sudo rule: `sudo rm /etc/sudoers.d/powercumul`; clean up data: `rm -rf ~/Library/Application\ Support/PowerCumul`.
