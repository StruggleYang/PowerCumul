#!/bin/bash
#
# package-dmg.sh — 把 build/PowerCumul.app 打包成 DMG，用于分发给朋友/社区。
#
# 产出的 DMG 内含 PowerCumul.app + Applications 文件夹软链，
# 拖拽即可安装（类似多数 macOS 应用分发方式）。
#
# 注意：本应用是 ad-hoc 签名（无 Apple Developer 账号），
# 接收方首次打开时需手动信任一次（右键打开，或系统设置→隐私与安全性→仍要打开）。
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PowerCumul.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")
DMG="build/PowerCumul-${VERSION}.dmg"

if [[ ! -d "${APP}" ]]; then
    echo "错误: 未找到 ${APP}，请先运行 ./build.sh"
    exit 1
fi

echo "==> 准备 DMG 临时目录"
STAGING="build/dmg-staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "==> 生成 DMG: ${DMG}"
rm -f "${DMG}"
# 用 hdiutil 创建只读 DMG（UDZO 压缩），带应用图标。
hdiutil create -volname "PowerCumul" \
    -srcfolder "${STAGING}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${DMG}"

rm -rf "${STAGING}"

echo ""
echo "✓ 打包完成: ${DMG}"
du -h "${DMG}" | awk '{print "   大小: " $1}'
echo ""
echo "分发方式: 把 ${DMG} 发给朋友 / 上传到 GitHub Release。"
echo "接收方首次打开会被 Gatekeeper 拦截，需:"
echo "  右键点击 App → 打开 → 仍要打开（仅需一次）"
