#!/bin/bash
#
# generate-icon.sh — 脚本化生成 PowerCumul 应用图标 (.icns)
#
# 流程:
#   1. 用 Swift + Core Graphics 在 1024×1024 画布绘制 squircle + 闪电
#   2. 用 sips 缩放出 Apple 要求的全部尺寸 (@1x/@2x)
#   3. 用 iconutil 打包成 AppIcon.icns
#
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="build/iconset"
ICONSET="${WORK}/AppIcon.iconset"
OUT="Sources/AppIcon.icns"

mkdir -p "${ICONSET}"

# --- 第1步: 用 Swift 绘制 1024×1024 主图 ---
echo "==> 绘制 1024×1024 主图"
SWIFT_SRC=$(mktemp -d)/draw.swift
cat > "${SWIFT_SRC}" <<'SWIFT'
import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
let s = CGFloat(size)
let rect = CGRect(x: 0, y: 0, width: s, height: s)

// 1) squircle 背景：用圆角矩形近似 Apple squircle。
//    圆角半径取边长 ~22.37%（iOS squircle 经验值），视觉上接近系统图标。
let radius = s * 0.2237
let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0),
                          xRadius: radius, yRadius: radius)
bgPath.addClip()

// 明亮的蓝色渐变背景（自上而下，从亮蓝到深蓝），让图标整体更醒目。
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [CGColor(red: 0.25, green: 0.60, blue: 0.96, alpha: 1.0),
                                   CGColor(red: 0.13, green: 0.38, blue: 0.82, alpha: 1.0)] as CFArray,
                          locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: s),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

// 2) 内圈装饰圆环（仪表盘语义，呼应"累计/监控"），亮背景下用半透明白。
NSColor.white.withAlphaComponent(0.18).setStroke()
let ring = NSBezierPath(ovalIn: rect.insetBy(dx: s*0.09, dy: s*0.09))
ring.lineWidth = s * 0.014
ring.stroke()

// 3) 中心闪电：用路径绘制（非系统符号，保证跨版本一致 & 自定义造型）。
//    闪电主体放大，占据约 62% 边长的区域，更醒目。
let cx = s * 0.5
let cy = s * 0.5
let h = s * 0.62   // 闪电高度（放大）
let w = s * 0.34   // 闪电宽度（放大）
// 闪电相对中心的归一化顶点（-1..1），再按 w/h 缩放。
let pts: [(Double, Double)] = [
    ( 0.05,  0.50),   // 顶
    (-0.45,  0.05),   // 左上拐
    (-0.05,  0.05),   // 左中
    (-0.25, -0.50),   // 底尖
    ( 0.45, -0.05),   // 右下拐
    ( 0.05, -0.05),   // 右中
]
let bolt = NSBezierPath()
for (i, p) in pts.enumerated() {
    let x = cx + CGFloat(p.0) * w
    let y = cy + CGFloat(p.1) * h
    if i == 0 { bolt.move(to: NSPoint(x: x, y: y)) }
    else      { bolt.line(to: NSPoint(x: x, y: y)) }
}
bolt.close()

// 闪电填充用暖黄渐变（左上亮、右下暗），带发光感。
ctx.saveGState()
bolt.addClip()
let boltGrad = CGGradient(colorsSpace: colorSpace,
                          colors: [CGColor(red: 1.0,  green: 0.83, blue: 0.30, alpha: 1.0),
                                   CGColor(red: 0.98, green: 0.65, blue: 0.15, alpha: 1.0)] as CFArray,
                          locations: [0.0, 1.0])!
ctx.drawLinearGradient(boltGrad,
                       start: CGPoint(x: cx - w, y: cy + h),
                       end: CGPoint(x: cx + w, y: cy - h),
                       options: [])
ctx.restoreGState()

// 4) 闪电描边（增强边缘清晰度）。
NSColor(red: 0.85, green: 0.55, blue: 0.10, alpha: 0.8).setStroke()
bolt.lineWidth = s * 0.006
bolt.lineJoinStyle = .round
bolt.stroke()

img.unlockFocus()

// 写出 PNG。
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let outPath = CommandLine.arguments[1]
try! png.write(to: URL(fileURLWithPath: outPath))
SWIFT

MAIN_PNG="${ICONSET}/main_1024.png"
swift "${SWIFT_SRC}" "${MAIN_PNG}"
rm -rf "$(dirname "${SWIFT_SRC}")"

# --- 第2步: 缩放出全部尺寸 ---
echo "==> 缩放生成各尺寸"
declare -a SIZES=(16 32 64 128 256 512 1024)
# 先把主图复制为 1024@2x 的源
cp "${MAIN_PNG}" "${ICONSET}/icon_512x512@2x.png"

# 用 sips 批量生成
sips -z 16 16   "${MAIN_PNG}" --out "${ICONSET}/icon_16x16.png"     >/dev/null
sips -z 32 32   "${MAIN_PNG}" --out "${ICONSET}/icon_16x16@2x.png"  >/dev/null
sips -z 32 32   "${MAIN_PNG}" --out "${ICONSET}/icon_32x32.png"     >/dev/null
sips -z 64 64   "${MAIN_PNG}" --out "${ICONSET}/icon_32x32@2x.png"  >/dev/null
sips -z 128 128 "${MAIN_PNG}" --out "${ICONSET}/icon_128x128.png"   >/dev/null
sips -z 256 256 "${MAIN_PNG}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${MAIN_PNG}" --out "${ICONSET}/icon_256x256.png"   >/dev/null
sips -z 512 512 "${MAIN_PNG}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${MAIN_PNG}" --out "${ICONSET}/icon_512x512.png"   >/dev/null
rm -f "${MAIN_PNG}"

# --- 第3步: 打包成 icns ---
echo "==> 打包 AppIcon.icns"
iconutil -c icns "${ICONSET}" -o "${OUT}"
rm -rf "${WORK}"

echo "✓ 图标已生成: ${OUT}"
