#!/bin/bash
#
# install-sudoers.sh — 配置 powermetrics 的 sudo 免密（仅需运行一次）
#
# 原理: 在 /etc/sudoers.d/ 写入一条规则，允许当前用户免密执行 /usr/bin/powermetrics。
# 安全性: 仅授权 powermetrics 这一个具体程序，不放开其他 sudo 权限。
#         文件权限设为 0440（sudoers 要求）。
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

if [[ ! -x "$POWERMETRICS" ]]; then
    echo "错误: 未找到 powermetrics，请确认已安装 Xcode Command Line Tools。"
    exit 1
fi

SUDOERS_FILE="/etc/sudoers.d/powercumul"
RULE="${TARGET_USER} ALL=(ALL) NOPASSWD: ${POWERMETRICS}"

echo "==> 目标用户: ${TARGET_USER}"
echo "==> 授权程序: ${POWERMETRICS}"
echo "==> 规则文件: ${SUDOERS_FILE}"
echo "    内容: ${RULE}"
echo ""

# 先校验规则语法，再写入（visudo -c 防止写出破坏 sudo 的非法文件）。
TMP_RULE="$(mktemp)"
echo "$RULE" > "$TMP_RULE"
if ! visudo -cf "$TMP_RULE" >/dev/null; then
    echo "错误: 规则语法校验失败，未写入。"
    rm -f "$TMP_RULE"
    exit 1
fi
rm -f "$TMP_RULE"

echo "$RULE" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

echo "✓ 已写入 sudoers 免密规则。"
echo ""
echo "验证（无需密码即成功）:"
echo "  sudo -n powermetrics -i 1000 -n 1 --samplers cpu_power,gpu_power | grep -i power"
echo ""
echo "卸载: sudo rm ${SUDOERS_FILE}"
