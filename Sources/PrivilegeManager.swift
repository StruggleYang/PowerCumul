//
//  PrivilegeManager.swift
//  PowerCumul
//
//  应用内授权：通过 NSAppleScript 触发系统原生密码授权框，
//  将 powermetrics 的 sudo 免密规则写入 /etc/sudoers.d/powercumul。
//
//  原理：`do shell script ... with administrator privileges` 是 Apple 官方推荐的
//  自 macOS 12 起获取 root 权限的方式（旧的 AuthorizationExecuteWithPrivileges 已移除）。
//  系统会弹出标准密码框，用户输入一次密码即完成授权。
//

import Foundation

enum PrivilegeStatus {
    case granted       // 已配置免密
    case missing       // 未配置
    case unknown       // 检测失败
}

final class PrivilegeManager {

    /// sudoers 规则文件路径。
    static let sudoersFile = "/etc/sudoers.d/powercumul"

    /// 检测当前是否已配置 powermetrics 免密（用 sudo -n 试探，不弹任何 UI）。
    static func currentStatus() -> PrivilegeStatus {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", "/usr/bin/powermetrics", "-h"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            // sudo -n 在免密就绪时退出码 0；需要密码时退出码 1。
            return task.terminationStatus == 0 ? .granted : .missing
        } catch {
            return .unknown
        }
    }

    /// 当前用户的短名（写入 sudoers 规则要用）。
    private static var userName: String {
        ProcessInfo.processInfo.userName
    }

    /// 写入 sudoers 免密规则。
    /// 成功返回 nil；失败返回错误信息。
    /// - Note: 会弹出系统原生密码授权框（由 AppleScript 驱动），需用户在主线程调用。
    static func requestPrivilege() -> String? {
        let rule = "\(userName) ALL=(ALL) NOPASSWD: /usr/bin/powermetrics"

        // 脚本：用临时文件写规则 → visudo -c 校验语法 → 通过则安装到 /etc/sudoers.d/。
        // 全程在一个 administrator shell 里完成，避免多次弹框。
        let script = """
        do shell script "\\
            TMP=$(mktemp); \\
            echo '\(rule)' > $TMP; \\
            if visudo -cf $TMP >/dev/null 2>&1; then \\
                install -m 0440 -o root -g wheel $TMP \(sudoersFile) && rm -f $TMP; \\
            else \\
                rm -f $TMP; exit 1; \\
            fi" with administrator privileges
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        _ = appleScript?.executeAndReturnError(&error)

        if let err = error {
            // 用户取消时 AppleScript 错误码 -128，返回友好的中文提示。
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 {
                return "已取消授权"
            }
            let msg = err[NSAppleScript.errorMessage] as? String ?? "未知错误"
            return "授权失败：\(msg)"
        }
        return nil
    }
}
