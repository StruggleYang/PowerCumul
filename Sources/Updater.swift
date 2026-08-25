//
//  Updater.swift
//  PowerCumul
//
//  应用内更新：直接拉 GitHub Releases（公开 API，无需 Sparkle/appcast）。
//
//  流程：GET /repos/<owner>/<repo>/releases/latest → 比对版本 →
//        下载 DMG → hdiutil 挂载 → 换装 .app → 去隔离属性 → 重启。
//
//  换装细节：
//  - 运行中的 .app 可安全重命名（进程持有 inode），旧包改名为 .old.app，
//    下次启动时清理；复制失败则回滚
//  - 新包来自网络下载带 quarantine 属性，ad-hoc 签名会被 Gatekeeper 再拦，
//    安装时用 xattr 剥掉即可（对本地用户等价于已信任）
//

import AppKit
import Foundation

enum Updater {

    struct Release {
        let tag: String          // 如 "v0.04"
        let name: String
        let notes: String
        let dmgURL: URL

        /// 纯版本号（去掉 v 前缀）。
        var version: String {
            tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }
    }

    static let latestAPI = URL(string: "https://api.github.com/repos/StruggleYang/PowerCumul/releases/latest")!

    static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - 检查

    /// 拉最新 Release（后台线程回调；失败返回 nil）。
    /// ① GitHub API（有限流：匿名 60 次/时/IP）→ ② 失败则走 releases/latest
    /// 网页重定向探测 tag（无 API 限流），DMG 地址按固定规则拼接。
    static func fetchLatest(completion: @escaping (Release?) -> Void) {
        var req = URLRequest(url: latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String,
               let assets = obj["assets"] as? [[String: Any]],
               let firstAsset = assets.first,
               let urlStr = firstAsset["browser_download_url"] as? String,
               let url = URL(string: urlStr) {
                let name = obj["name"] as? String ?? tag
                let notes = obj["body"] as? String ?? ""
                completion(Release(tag: tag, name: name, notes: notes, dmgURL: url))
                return
            }
            // 回退：releases/latest 会 302 到 /tag/<vX.YZ>，重定向后的最终 URL 即含 tag。
            if let fallback = fetchViaRedirect() {
                completion(fallback)
            } else {
                completion(nil)
            }
        }.resume()
    }

    /// 回退通道：请求 releases/latest（跟随重定向），从最终 URL 提取 tag。
    /// DMG 资产名由 workflow 固定生成：PowerCumul-<version>.dmg。
    private static func fetchViaRedirect() -> Release? {
        guard let pageURL = URL(string: "https://github.com/StruggleYang/PowerCumul/releases/latest") else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var finalURL: URL? = nil
        var req = URLRequest(url: pageURL)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, response, _ in
            finalURL = response?.url
            sem.signal()
        }.resume()
        sem.wait()
        guard let final = finalURL else { return nil }
        let tag = final.lastPathComponent
        guard tag.hasPrefix("v") else { return nil }
        let version = String(tag.dropFirst())
        let dmg = URL(string: "https://github.com/StruggleYang/PowerCumul/releases/download/\(tag)/PowerCumul-\(version).dmg")
        guard let dmg = dmg else { return nil }
        return Release(tag: tag, name: tag, notes: "", dmgURL: dmg)
    }

    /// 版本比较："v0.10" > "0.4"（数字段逐段比较，非字符串比较）。
    static func isNewer(_ a: String, than b: String) -> Bool {
        func segments(_ s: String) -> [Int] {
            s.replacingOccurrences(of: "v", with: "")
             .split(separator: ".").map { Int($0) ?? 0 }
        }
        let sa = segments(a), sb = segments(b)
        for i in 0..<max(sa.count, sb.count) {
            let x = i < sa.count ? sa[i] : 0
            let y = i < sb.count ? sb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 下载安装

    /// 下载 DMG 并原地换装，成功后重启 App。返回 nil 表示成功，否则为错误描述。
    /// 必须在后台线程调用（内部有同步等待）。
    static func downloadAndInstall(_ release: Release) -> String? {
        // ① 下载 DMG 到临时目录（同步等待）。
        let dmgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PowerCumul-\(release.version).dmg")
        try? FileManager.default.removeItem(at: dmgURL)
        let sem = DispatchSemaphore(value: 0)
        var dlError: String? = nil
        URLSession.shared.downloadTask(with: release.dmgURL) { tempURL, _, error in
            defer { sem.signal() }
            guard let tempURL = tempURL, error == nil else {
                dlError = error?.localizedDescription ?? "下载失败"
                return
            }
            do { try FileManager.default.moveItem(at: tempURL, to: dmgURL) }
            catch { dlError = "保存下载失败：\(error.localizedDescription)" }
        }.resume()
        sem.wait()
        if let e = dlError { return e }

        // ② 挂载 DMG（输出最后一行的最后一段是挂载点）。
        guard let mountOut = run("/usr/bin/hdiutil", ["attach", "-nobrowse", dmgURL.path])?.out,
              let lastLine = mountOut.split(separator: "\n").last,
              let mountPoint = lastLine.split(separator: "\t").last.map(String.init)?
                  .trimmingCharacters(in: .whitespaces), !mountPoint.isEmpty else {
            return "挂载 DMG 失败"
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint]) }

        // ③ 在挂载卷里找 .app。
        let mountedApp: URL
        if let name = try? FileManager.default.contentsOfDirectory(atPath: mountPoint).first(where: { $0.hasSuffix(".app") }) {
            mountedApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(name)
        } else {
            return "DMG 中未找到 .app"
        }

        // ④ 换装：旧包改名（运行中安全）→ ditto 复制新包（保留签名/权限）。
        let appURL = Bundle.main.bundleURL
        let oldURL = appURL.deletingLastPathComponent()
            .appendingPathComponent("PowerCumul.old.app")
        try? FileManager.default.removeItem(at: oldURL)
        do {
            try FileManager.default.moveItem(at: appURL, to: oldURL)
        } catch {
            return "无法移动旧版本（权限？）：\(error.localizedDescription)"
        }
        guard run("/usr/bin/ditto", [mountedApp.path, appURL.path]) != nil else {
            // 复制失败回滚。
            try? FileManager.default.moveItem(at: oldURL, to: appURL)
            return "复制新版本失败（权限？）"
        }

        // ⑤ 剥隔离属性：新包来自网络下载，不去掉会被 Gatekeeper 再拦
        //    （ad-hoc 签名无公证，用户需要的就是无缝更新）。
        _ = run("/usr/bin/xattr", ["-rd", "com.apple.quarantine", appURL.path])

        // ⑥ 重启到新版本（open 由 launchd 接管，旧进程随后退出）。
        _ = run("/usr/bin/open", ["-n", appURL.path])
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return nil
    }

    /// 启动时清理上次更新遗留的旧包。
    static func cleanupOldBundle() {
        let oldURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PowerCumul.old.app")
        try? FileManager.default.removeItem(at: oldURL)
    }

    // MARK: - 工具

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (out: String?, err: String?)? {
        let p = Process()
        p.launchPath = path
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return (o, nil)
    }
}
