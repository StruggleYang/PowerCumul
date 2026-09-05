#!/bin/bash
#
# install-sudoers.sh — 配置 sudo 免密（仅需运行一次）
# 覆盖两项能力：powermetrics 采样 + 充电控制辅助工具（powercumul-smc）。
#
# 原理: 在 /etc/sudoers.d/ 写入规则，允许当前用户免密执行这两个具体程序。
# 安全性: 仅授权这两个程序，不放开其他 sudo 权限；文件权限 0440。
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "请用 sudo 运行本脚本（仅需一次）:"
    echo "  sudo ./scripts/install-sudoers.sh"
    exit 1
fi

# 用 sudo 失败时拿不到，回退到 logname / SUDO_USER。
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
POWERMETRICS="$(command -v powermetrics || echo /usr/bin/powermetrics)"
SUDOERS_FILE="/etc/sudoers.d/powercumul"
HELPER_PATH="/Library/PrivilegedHelperTools/powercumul-smc"

if [[ ! -x "$POWERMETRICS" ]]; then
    echo "错误: 未找到 powermetrics，请确认已安装 Xcode Command Line Tools。"
    exit 1
fi

# 辅助工具从 app bundle 里取（build.sh 会编译并打入 Resources）。
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_SRC="${APP_DIR}/build/PowerCumul.app/Contents/Resources/powercumul-smc"

echo "==> 目标用户: ${TARGET_USER}"

RULES=("${TARGET_USER} ALL=(ALL) NOPASSWD: ${POWERMETRICS}")

if [[ -f "$HELPER_SRC" ]]; then
    echo "==> 安装充电控制辅助工具: ${HELPER_PATH}"
    mkdir -p "$(dirname "$HELPER_PATH")"
    install -m 0755 -o root -g wheel "$HELPER_SRC" "$HELPER_PATH"
    RULES+=("${TARGET_USER} ALL=(ALL) NOPASSWD: ${HELPER_PATH}")
else
    echo "!! 未找到 ${HELPER_SRC}，跳过充电控制授权（仅配置功率采样）。"
    echo "   先 ./build.sh 构建后再运行本脚本可同时启用充电控制。"
fi

echo "==> 规则文件: ${SUDOERS_FILE}"
printf '    内容: %s\n' "${RULES[@]}"
echo ""

# 先校验规则语法，再写入（visudo -c 防止写出破坏 sudo 的非法文件）。
TMP_RULE="$(mktemp)"
printf '%s\n' "${RULES[@]}" > "$TMP_RULE"
if ! visudo -cf "$TMP_RULE" >/dev/null; then
    echo "错误: 规则语法校验失败，未写入。"
    rm -f "$TMP_RULE"
    exit 1
fi
rm -f "$TMP_RULE"

printf '%s\n' "${RULES[@]}" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

echo "✓ 已写入 sudoers 免密规则。"
echo ""
echo "验证（无需密码即成功）:"
echo "  sudo -n powermetrics -i 1000 -n 1 --samplers cpu_power,gpu_power | grep -i power"
if [[ -f "$HELPER_PATH" ]]; then
    echo "  sudo -n ${HELPER_PATH} status"
fi
echo ""
echo "卸载: sudo rm ${SUDOERS_FILE}; sudo rm -f ${HELPER_PATH}"
