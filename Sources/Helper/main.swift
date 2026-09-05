//
//  powercumul-smc — PowerCumul 特权辅助工具（root 运行，极小职责）
//
//  只做充电控制相关的 SMC 读写，由 app 经 sudoers 免密规则调用。
//  安装位置固定为 /Library/PrivilegedHelperTools/powercumul-smc
//  （sudoers 白名单按路径匹配，路径必须稳定，不随 app 安装位置变化）。
//
//  命令：
//    status               打印能力与状态：mode=<firmware|legacy|unsupported>
//                         charging=<0|1，仅 legacy> active=<0|1> upper=<n> lower=<n>（仅 firmware）
//    limit <20..99>       设置充电上限。固件模式写 bfD0/bfE0/bfF0（固件自行执行滞回）；
//                         legacy 模式仅开充电（滞回由 app 维护）
//    clear                恢复默认：固件模式停用限充；legacy 模式开启充电
//    charging <on|off>    直接开关充电（legacy 模式，供 app 滞回循环调用）
//
//  SMC 机制移植自开源实现 batt（github.com/charlie0129/batt，Apple Silicon）：
//  - 固件限充（较新固件）：bfF0 激活=0x02 / 停用=0x00；bfD0=上限、bfE0=下限，
//    ui32 小端百分比（80% → 50 00 00 00）。写入顺序固件要求：
//    bfF0=0x00 → bfD0 → bfE0 → bfF0=0x02
//  - 直接控制（legacy）：CH0B+CH0C 各 1 字节（0x00 开充 / 0x02 停充）；
//    老固件改用 CHTE 4 字节（00 00 00 00 开 / 01 00 00 00 停）
//
//  本文件独立编译为 CLI，不进 app target（见 build.sh）。
//

import Foundation
import IOKit

// MARK: - SMC 原语

// SMC 命令字（经 IOKit selector 2 下发）与参数结构长度。
private let kKernelIndexSMC: UInt32 = 2
private let kCmdReadBytes: UInt8 = 5
private let kCmdWriteBytes: UInt8 = 6
private let kCmdReadKeyInfo: UInt8 = 9

// 经典 SMC 参数结构共 80 字节。这里用手动偏移的字节缓冲而非 Swift 结构体，
// 彻底避开 Swift 与 C 的布局差异——IOConnectCallStructMethod 按字节原样传给内核。
// 偏移：key 0(4B) / vers 4(6B) / pLimitData 12(16B) / keyInfo.dataSize 28 /
// keyInfo.dataType 32 / keyInfo.attr 36 / result 40 / status 41 / data8 42 /
// data32 44 / payload bytes 48..79
private struct SMCParam {
    static let structSize = 80
    private static let offKeyInfoSize = 28
    private static let offResult = 40
    private static let offData8 = 42
    private static let offPayload = 48
    var bytes = [UInt8](repeating: 0, count: SMCParam.structSize)

    var data8: UInt8 {
        get { bytes[SMCParam.offData8] }
        set { bytes[SMCParam.offData8] = newValue }
    }
    var result: UInt8 { bytes[SMCParam.offResult] }
    var keyInfoSize: UInt32 {
        get {
            UInt32(bytes[SMCParam.offKeyInfoSize])
                | UInt32(bytes[SMCParam.offKeyInfoSize + 1]) << 8
                | UInt32(bytes[SMCParam.offKeyInfoSize + 2]) << 16
                | UInt32(bytes[SMCParam.offKeyInfoSize + 3]) << 24
        }
        set {
            bytes[SMCParam.offKeyInfoSize] = UInt8(newValue & 0xFF)
            bytes[SMCParam.offKeyInfoSize + 1] = UInt8((newValue >> 8) & 0xFF)
            bytes[SMCParam.offKeyInfoSize + 2] = UInt8((newValue >> 16) & 0xFF)
            bytes[SMCParam.offKeyInfoSize + 3] = UInt8((newValue >> 24) & 0xFF)
        }
    }
    mutating func setKey(_ key: String) {
        let chars = Array(key.utf8.prefix(4))
        for (i, c) in chars.enumerated() { bytes[i] = c }
    }
    mutating func setPayload(_ data: [UInt8]) {
        for (i, b) in data.enumerated() { bytes[SMCParam.offPayload + i] = b }
    }
    func payload(_ count: Int) -> [UInt8] {
        Array(bytes[SMCParam.offPayload ..< SMCParam.offPayload + count])
    }
}

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kr: Int32)
    case callFailed(kr: Int32)
    case keyMissing
    case result(UInt8)
    case badValue(String)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC 服务不存在"
        case .openFailed(let kr): return "打开 AppleSMC 失败 (kr=\(kr))"
        case .callFailed(let kr): return "SMC 调用失败 (kr=\(kr))"
        case .keyMissing: return "SMC 键不存在"
        case .result(let r): return String(format: "SMC 返回错误 0x%02X", r)
        case .badValue(let msg): return msg
        }
    }
}

private final class SMCConnection {
    private var conn: io_connect_t = 0

    func open() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr: kr) }
    }

    func close() {
        guard conn != 0 else { return }
        IOServiceClose(conn)
        conn = 0
    }

    private func call(_ input: SMCParam) throws -> SMCParam {
        var input = input
        var output = SMCParam()
        var inSize = SMCParam.structSize
        var outSize = SMCParam.structSize
        let kr = withUnsafeMutableBytes(of: &input) { inBuf in
            withUnsafeMutableBytes(of: &output) { outBuf in
                IOConnectCallStructMethod(conn, kKernelIndexSMC,
                                          inBuf.baseAddress, inSize,
                                          outBuf.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr: kr) }
        return output
    }

    /// 键元数据（dataSize）。dataSize=0 视为键不存在（部分固件会暴露占位键）。
    func keyInfoSize(_ key: String) throws -> UInt32 {
        var input = SMCParam()
        input.setKey(key)
        input.data8 = kCmdReadKeyInfo
        let output = try call(input)
        guard output.result == 0 else { throw SMCError.result(output.result) }
        return output.keyInfoSize
    }

    func hasKey(_ key: String) -> Bool {
        (try? keyInfoSize(key)) ?? 0 > 0
    }

    func read(_ key: String) throws -> [UInt8] {
        let size = try keyInfoSize(key)
        guard size >= 1, size <= 32 else { throw SMCError.badValue("\(key) 数据长度异常 \(size)") }
        var input = SMCParam()
        input.setKey(key)
        input.data8 = kCmdReadBytes
        input.keyInfoSize = size
        let output = try call(input)
        guard output.result == 0 else { throw SMCError.result(output.result) }
        return output.payload(Int(size))
    }

    func write(_ key: String, _ data: [UInt8]) throws {
        var input = SMCParam()
        input.setKey(key)
        input.data8 = kCmdWriteBytes
        input.keyInfoSize = UInt32(data.count)
        input.setPayload(data)
        let output = try call(input)
        guard output.result == 0 else { throw SMCError.result(output.result) }
    }
}

// MARK: - 充电控制语义（对照 batt）

private let keyCH0B = "CH0B"
private let keyCH0C = "CH0C"
private let keyCHTE = "CHTE"   // Tahoe 世代老固件的直接控制键
private let keyBfF0 = "bfF0"   // 固件限充激活：0x02 生效 / 0x00 停用
private let keyBfD0 = "bfD0"   // 固件限充上限（ui32 小端百分比）
private let keyBfE0 = "bfE0"   // 固件限充下限（ui32 小端百分比）

private enum Mode: String {
    case firmware
    case legacy
    case unsupported
}

private func detectMode(_ smc: SMCConnection) -> Mode {
    // 固件键优先：老系统可能刷了新固件（与 batt 的判据一致）。
    if smc.hasKey(keyBfF0), smc.hasKey(keyBfD0), smc.hasKey(keyBfE0) { return .firmware }
    if smc.hasKey(keyCH0B), smc.hasKey(keyCH0C) { return .legacy }
    if smc.hasKey(keyCHTE) { return .legacy }
    return .unsupported
}

private func enableCharging(_ smc: SMCConnection) throws {
    if smc.hasKey(keyCH0B), smc.hasKey(keyCH0C) {
        try smc.write(keyCH0B, [0x00])
        try smc.write(keyCH0C, [0x00])
    } else if smc.hasKey(keyCHTE) {
        try smc.write(keyCHTE, [0x00, 0x00, 0x00, 0x00])
    }
}

private func disableCharging(_ smc: SMCConnection) throws {
    if smc.hasKey(keyCH0B), smc.hasKey(keyCH0C) {
        try smc.write(keyCH0B, [0x02])
        try smc.write(keyCH0C, [0x02])
    } else if smc.hasKey(keyCHTE) {
        try smc.write(keyCHTE, [0x01, 0x00, 0x00, 0x00])
    }
}

private func isChargingEnabled(_ smc: SMCConnection) -> Bool? {
    if smc.hasKey(keyCH0B), let v = try? smc.read(keyCH0B), let b = v.first {
        return b == 0x00
    }
    if smc.hasKey(keyCHTE), let v = try? smc.read(keyCHTE), let b = v.first {
        return b == 0x00
    }
    return nil
}

/// 读固件限充状态：(激活, 上限, 下限)。
private func firmwareLimit(_ smc: SMCConnection) -> (active: Bool, upper: Int, lower: Int)? {
    guard let act = try? smc.read(keyBfF0), let actByte = act.first,
          let up = try? smc.read(keyBfD0), up.count == 4,
          let low = try? smc.read(keyBfE0), low.count == 4 else { return nil }
    func le32(_ b: [UInt8]) -> Int {
        Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    }
    return (actByte == 0x02, le32(up), le32(low))
}

/// 幂等设置固件限充。写入顺序为固件要求：先停用 → 上限 → 下限 → 激活。
private func ensureFirmwareLimit(_ smc: SMCConnection, lower: Int, upper: Int) throws {
    guard lower >= 0, upper <= 100, lower < upper else {
        throw SMCError.badValue("非法限充区间 \(lower)-\(upper)")
    }
    if let cur = firmwareLimit(smc), cur.active, cur.upper == upper, cur.lower == lower {
        return   // 已是目标状态，免写
    }
    try smc.write(keyBfF0, [0x00])
    try smc.write(keyBfD0, [UInt8(upper & 0xFF), 0, 0, 0])
    try smc.write(keyBfE0, [UInt8(lower & 0xFF), 0, 0, 0])
    try smc.write(keyBfF0, [0x02])
}

private func disableFirmwareLimit(_ smc: SMCConnection) throws {
    guard let act = try? smc.read(keyBfF0), let actByte = act.first else { return }
    if actByte != 0x00 { try smc.write(keyBfF0, [0x00]) }
}

// MARK: - CLI

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("错误: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("用法: powercumul-smc <status|limit <20..99>|clear|charging <on|off>>")
}

private let smc = SMCConnection()
do {
    try smc.open()
    defer { smc.close() }
} catch {
    fail("\(error)")
}

do {
    switch command {
    case "status":
        let mode = detectMode(smc)
        var parts = ["mode=\(mode.rawValue)"]
        if mode == .legacy, let charging = isChargingEnabled(smc) {
            parts.append("charging=\(charging ? 1 : 0)")
        }
        if mode == .firmware, let limit = firmwareLimit(smc) {
            parts.append("active=\(limit.active ? 1 : 0)")
            parts.append("upper=\(limit.upper)")
            parts.append("lower=\(limit.lower)")
        }
        print(parts.joined(separator: " "))

    case "limit":
        guard args.count == 2, let pct = Int(args[1]), (20...99).contains(pct) else {
            fail("limit 需要一个 20..99 的百分比参数")
        }
        switch detectMode(smc) {
        case .firmware:
            try ensureFirmwareLimit(smc, lower: pct - 2, upper: pct)
        case .legacy:
            // legacy 的 SMC 只能开/关充电，先开充，滞回由 app 维护。
            try enableCharging(smc)
        case .unsupported:
            fail("此设备不支持充电控制")
        }

    case "clear":
        switch detectMode(smc) {
        case .firmware:
            try disableFirmwareLimit(smc)
        case .legacy:
            try enableCharging(smc)   // 恢复默认 = 放开充电
        case .unsupported:
            fail("此设备不支持充电控制")
        }

    case "charging":
        guard args.count == 2, ["on", "off"].contains(args[1]) else {
            fail("charging 需要 on 或 off 参数")
        }
        guard detectMode(smc) == .legacy else {
            fail("charging 仅用于 legacy 模式（固件模式由固件自行控制）")
        }
        if args[1] == "on" { try enableCharging(smc) } else { try disableCharging(smc) }

    default:
        fail("未知命令: \(command)")
    }
} catch {
    fail("\(error)")
}
