#!/usr/bin/env bash
# spike: coreml-mlx-01 —— 一条命令跑完，无人工干预。
#
#   ./run.sh              # 类型检查 + 宿主探针 + 模拟器探针
#   ./run.sh typecheck    # 只做类型检查（不需要模拟器）
#   ./run.sh convert      # 额外跑 coremltools 转换/压缩探针（需要 python 环境，见 README）
#
# 二进制编到 mktemp 目录，跑完删掉 —— 仓库里不留产物。
# 模型产物（.mlpackage / .mlmodelc）也只落在 mktemp 目录里，绝不入库。

set -euo pipefail
cd "$(dirname "$0")"
SPIKE="$PWD"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios26.2-simulator"
DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro}"
MODE="${1:-all}"

echo "==> [1/3] typecheck apicheck.swift（把 iOS 26.2 的 Core ML 精确签名钉住）"
# 这一步是本 spike 最有价值的部分：makeState() vs newState() 只有类型检查能抓出来。
xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" -swift-version 6 apicheck.swift
echo "    OK（0 错误）"

if [[ "$MODE" == "typecheck" ]]; then exit 0; fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> [2/3] 宿主 macOS 探针（对照组：宿主有 ANE，模拟器没有）"
xcrun swiftc hostprobe.swift -o "$BUILD/hostprobe"
"$BUILD/hostprobe"

echo "==> [3/3] 模拟器探针（compute device / 内存 / 热状态）"
xcrun swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 \
  probe.swift -o "$BUILD/mlprobe" 2>&1 | grep -v incompatible-sysroot || true

DEV="$(xcrun simctl list devices available | grep -m1 "$DEVICE_NAME (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [[ -z "$DEV" ]]; then echo "找不到可用模拟器：$DEVICE_NAME" >&2; exit 1; fi
echo "    device = $DEVICE_NAME ($DEV)"
xcrun simctl boot "$DEV" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1 || true
xcrun simctl spawn "$DEV" "$BUILD/mlprobe" || true

if [[ "$MODE" == "convert" ]]; then
  echo "==> [extra] coremltools 转换与压缩探针"
  PY="${PY:-python3}"
  "$PY" -c 'import coremltools, torch' 2>/dev/null || {
    echo "    跳过：当前 python 没有 coremltools + torch，装法见 README" >&2; exit 0; }
  ( cd "$BUILD" && "$PY" "$SPIKE/convert_probe.py" && "$PY" "$SPIKE/compress_probe.py" )
fi

echo "==> done"
