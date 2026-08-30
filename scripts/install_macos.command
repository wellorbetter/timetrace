#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/TimeTrace.app"
DATA_DIR="$HOME/Library/Application Support/TimeTrace"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "找不到 TimeTrace.app。"
  echo "请保持 Install TimeTrace.command 和 TimeTrace.app 在同一个文件夹中。"
  read -r -p "按回车键退出..."
  exit 1
fi

# Prefer the normal system Applications directory. Standard accounts that cannot
# write there fall back to ~/Applications without asking for administrator rights.
TARGET_DIR="/Applications"
if [[ ! -w "$TARGET_DIR" ]]; then
  TARGET_DIR="$HOME/Applications"
  mkdir -p "$TARGET_DIR"
fi
TARGET_APP="$TARGET_DIR/TimeTrace.app"

echo "正在安装 TimeTrace → $TARGET_APP"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

# GitHub/browser downloads receive the com.apple.quarantine attribute. This app
# is an open-source self-use preview build with ad-hoc signing, so remove only
# this app's quarantine marker instead of disabling Gatekeeper globally.
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

# Verify that the bundle itself was not damaged while copying.
if ! codesign --verify --deep --strict "$TARGET_APP" 2>/dev/null; then
  echo "TimeTrace.app 签名完整性校验失败，安装已停止。"
  rm -rf "$TARGET_APP"
  read -r -p "按回车键退出..."
  exit 1
fi

mkdir -p "$DATA_DIR"

echo "安装完成，正在启动 TimeTrace…"
open "$TARGET_APP"

echo
echo "TimeTrace 已安装到：$TARGET_APP"
echo "数据目录：$DATA_DIR"
echo "此预览版仅清除了 TimeTrace.app 自身的 quarantine 标记，没有关闭系统 Gatekeeper。"
sleep 2
