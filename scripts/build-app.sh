#!/bin/bash
# All application code is compiled from local Swift source; no Python runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf '\n构建停止：%s\n' "$1" >&2; exit 1; }
REVEAL=1
SWIFT_FLAGS=(--package-path "$ROOT" --cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/config" --security-path "$ROOT/.build/security")
for argument in "$@"; do
    case "$argument" in
        --no-reveal) REVEAL=0 ;;
        --disable-sandbox) SWIFT_FLAGS+=(--disable-sandbox) ;;
        *) fail "未知构建参数：$argument" ;;
    esac
done
[[ "$(uname -s)" == "Darwin" ]] || fail "需要 macOS 13+ 和 Apple 的 Swift / AppKit SDK。Linux 不能构建这个原生 App。"
[[ -x /usr/bin/xcrun ]] || fail "未找到 Apple 开发工具；请先安装 Xcode 或官方 Command Line Tools。此脚本不会替你安装。"
/usr/bin/xcrun --find swift >/dev/null 2>&1 || fail "当前 Xcode / Command Line Tools 没有 Swift。请在本机完成官方开发工具设置后重试。"
/usr/bin/xcrun --find xctest >/dev/null 2>&1 || fail "当前开发工具不含 XCTest。请选择完整 Xcode，或给本次命令设置 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer。"
printf '\n检查原生单元测试并构建两个 Swift 可执行文件…\n'
/usr/bin/xcrun swift test "${SWIFT_FLAGS[@]}"
/usr/bin/xcrun swift build --configuration release "${SWIFT_FLAGS[@]}"
BIN_DIR="$(/usr/bin/xcrun swift build --configuration release --show-bin-path "${SWIFT_FLAGS[@]}")"
# A fresh timestamped output preserves previous builds. No automatic rm/install.
OUT="$ROOT/dist/$(date +%Y%m%d-%H%M%S)-$$"
APP="$OUT/Miruun.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Miruun" "$APP/Contents/MacOS/Miruun"
cp "$BIN_DIR/MiruunEngine" "$APP/Contents/MacOS/MiruunEngine"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/Miruun" "$APP/Contents/MacOS/MiruunEngine"
# Deliberately no codesign, installer, launch-agent, pip or external dependency.
printf '\n纯 Swift 原生应用已在本机编译：\n%s\n\n不需要 Python。未做 Developer ID 签名或公证。\n双击应用开始使用。此脚本没有启动 Codex 后端或读取会话。\n' "$APP"
if [[ "$REVEAL" == 1 ]]; then open -R "$APP"; fi
