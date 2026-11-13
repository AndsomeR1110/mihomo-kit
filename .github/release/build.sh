#!/usr/bin/env bash
# 打包发布文件（GitHub Actions 与本地均可运行）：
#   dist/mihomo-kit-<ver>-offline.zip  离线完整包：已内置内核 / WinSW / 面板 / 规则集，解压即装
#   dist/mihomo-kit-<ver>-lite.zip     精简包：只有脚本，首次 install.cmd 时联网下载
#   dist/SHA256SUMS.txt
# 下载地址与 scripts/prepare.ps1 保持一致（改版本时两边一起改）。
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
VER=$(tr -d ' \r\n' < VERSION)
KERNEL_VER=$(grep -oE "mihomo/releases/download/v[0-9.]+" scripts/prepare.ps1 | head -1 | sed 's#.*/v##')
WINSW_URL=$(grep -oE "https://github.com/winsw/[^']+" scripts/prepare.ps1 | head -1)
UI_URL='https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip'
RULE_BASE='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo'

DIST=$ROOT/dist; WORK=$(mktemp -d)
rm -rf "$DIST"; mkdir -p "$DIST"
dl() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# 1) 套件文件：只取 git 跟踪的内容（不含 .github）
STAGE=$WORK/mihomo-kit
mkdir -p "$STAGE"
git archive --format=tar HEAD | tar -x -C "$STAGE"
rm -rf "$STAGE/.github"
# .cmd 统一 CRLF，避免个别环境下批处理解析异常
find "$STAGE" -name '*.cmd' -exec sed -i 's/\r$//; s/$/\r/' {} +

( cd "$WORK" && zip -qr9 "$DIST/mihomo-kit-$VER-lite.zip" mihomo-kit )

# 2) 离线包：补齐二进制与规则集
dl "https://github.com/MetaCubeX/mihomo/releases/download/v$KERNEL_VER/mihomo-windows-amd64-v$KERNEL_VER.zip" "$WORK/kernel.zip"
unzip -qo "$WORK/kernel.zip" -d "$WORK/kernel"
mkdir -p "$STAGE/bin"
cp "$(find "$WORK/kernel" -name '*.exe' | head -1)" "$STAGE/bin/mihomo.exe"
dl "$WINSW_URL" "$STAGE/bin/mihomo-service.exe"

dl "$UI_URL" "$WORK/ui.zip"
unzip -qo "$WORK/ui.zip" -d "$WORK/ui"
UI_SRC=$WORK/ui; [ -d "$WORK/ui/dist" ] && UI_SRC=$WORK/ui/dist
mkdir -p "$STAGE/config/ui"; cp -r "$UI_SRC"/. "$STAGE/config/ui/"
test -f "$STAGE/config/ui/index.html"

RS=$STAGE/config/ruleset; mkdir -p "$RS"
dl "$RULE_BASE/geosite/private.mrs"            "$RS/private-domain.mrs"
dl "$RULE_BASE/geosite/anthropic.mrs"          "$RS/anthropic.mrs"
dl "$RULE_BASE/geosite/category-ai-!cn.mrs"    "$RS/ai.mrs"
dl "$RULE_BASE/geosite/cn.mrs"                 "$RS/cn-domain.mrs"
dl "$RULE_BASE/geosite/geolocation-!cn.mrs"    "$RS/global-domain.mrs"
dl "$RULE_BASE/geoip/cn.mrs"                   "$RS/cn-ip.mrs"

( cd "$WORK" && zip -qr9 "$DIST/mihomo-kit-$VER-offline.zip" mihomo-kit )

( cd "$DIST" && sha256sum *.zip > SHA256SUMS.txt )
rm -rf "$WORK"
echo "kernel v$KERNEL_VER"; ls -l "$DIST"; cat "$DIST/SHA256SUMS.txt"
