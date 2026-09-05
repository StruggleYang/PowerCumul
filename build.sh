#!/bin/bash
#
# build.sh — PowerCumul 一键构建脚本
# 用 swiftc 命令行编译（无需 Xcode 工程文件），手工组装 .app bundle 并 ad-hoc 签名。
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PowerCumul"
BUNDLE_ID="com.powercumul.app"
SRC_DIR="Sources"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

echo "==> 检查 swiftc"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "错误: 未找到 swiftc。请安装 Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "==> 生成应用图标"
if [[ ! -f "${SRC_DIR}/AppIcon.icns" ]]; then
    ./scripts/generate-icon.sh
fi

echo "==> 编译 Swift 源码"
mkdir -p "${BUILD_DIR}/obj"

# 收集 Sources 顶层（maxdepth 1）的 .swift —— Helper/ 子目录是特权辅助工具，
# 单独编译为 root CLI，不进 app target。
SWIFT_SOURCES=()
while IFS= read -r f; do
    SWIFT_SOURCES+=("$f")
done < <(find "${SRC_DIR}" -maxdepth 1 -name '*.swift' | sort)

# 注意: 不加 -parse-as-library —— main.swift 的顶层代码本身就是程序入口。
swiftc \
    -O \
    -target arm64-apple-macos13 \
    -framework AppKit \
    -framework ServiceManagement \
    -framework UserNotifications \
    -o "${BUILD_DIR}/obj/${APP_NAME}" \
    "${SWIFT_SOURCES[@]}"

echo "==> 编译特权辅助工具 (powercumul-smc)"
# root CLI：充电控制的 SMC 读写，经 sudoers 白名单免密调用。
# 只做充电相关的几个 SMC 键操作，安装到 /Library/PrivilegedHelperTools/。
swiftc \
    -O \
    -target arm64-apple-macos13 \
    -framework IOKit \
    -o "${BUILD_DIR}/obj/powercumul-smc" \
    "${SRC_DIR}/Helper/main.swift"
codesign --force --sign - "${BUILD_DIR}/obj/powercumul-smc"

echo "==> 组装 .app bundle"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BUILD_DIR}/obj/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "${SRC_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
# 嵌入应用图标到 Resources（Info.plist 的 CFBundleIconFile 指向 AppIcon）。
if [[ -f "${SRC_DIR}/AppIcon.icns" ]]; then
    cp "${SRC_DIR}/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi
# 嵌入特权辅助工具（授权时由 PrivilegeManager 安装到 /Library/PrivilegedHelperTools/）。
if [[ -f "${BUILD_DIR}/obj/powercumul-smc" ]]; then
    cp "${BUILD_DIR}/obj/powercumul-smc" "${RESOURCES_DIR}/powercumul-smc"
fi
# 嵌入本地化资源：把 Resources/下的 *.lproj 目录整体拷入 bundle 的 Resources/。
if [[ -d "${SRC_DIR}/Resources" ]]; then
    find "${SRC_DIR}/Resources" -maxdepth 1 -name '*.lproj' -type d -exec cp -R {} "${RESOURCES_DIR}/" \;
fi

echo "==> 代码签名 (ad-hoc)"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo ""
echo "✓ 构建完成: ${APP_BUNDLE}"
echo ""
echo "运行方式:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "首次使用前，请配置 powermetrics 的 sudo 免密（仅一次）:"
echo "  sudo ./scripts/install-sudoers.sh"
