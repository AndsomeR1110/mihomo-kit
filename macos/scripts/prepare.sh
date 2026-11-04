#!/bin/bash
# 准备：下载内核 / 面板 / 规则集、生成面板密钥、建立私有文件模板
# 不改变当前上网方式，不需要管理员权限。优先走 gh-proxy.com 镜像，失败回退直连；
# 可用 --proxy http://127.0.0.1:7890 指定现有代理加速下载
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

PROXY=''
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --proxy) PROXY="$2"; shift ;;
        --force) FORCE=1 ;;
        --no-pause) NO_PAUSE=1 ;;
    esac
    shift
done
start_run_log prepare

KERNEL_VER='v1.19.32'
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then ARCH='arm64'; else ARCH='amd64'; fi
KERNEL_URL="https://github.com/MetaCubeX/mihomo/releases/download/$KERNEL_VER/mihomo-darwin-$ARCH-$KERNEL_VER.gz"
UI_URL='https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip'
RULE_BASE='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo'
MIRROR='https://gh-proxy.com/'
RULESETS="private-domain.mrs|$RULE_BASE/geosite/private.mrs
anthropic.mrs|$RULE_BASE/geosite/anthropic.mrs
ai.mrs|$RULE_BASE/geosite/category-ai-!cn.mrs
cn-domain.mrs|$RULE_BASE/geosite/cn.mrs
global-domain.mrs|$RULE_BASE/geosite/geolocation-!cn.mrs
cn-ip.mrs|$RULE_BASE/geoip/cn.mrs"

# 国内网络优先走 gh-proxy.com 镜像，失败回退直连；30 秒速度低于 10KB/s 视为失败。
# 先下到 .part，成功才改名，半截文件不会被下次当成“已存在”
get_file() {
    local url="$1" out="$2" u a
    for u in "$MIRROR$url" "$url"; do
        a=(-sSL --fail --retry 1 --connect-timeout 8 --max-time 300 --speed-limit 10240 --speed-time 30 -o "$out.part")
        [ -n "$PROXY" ] && a+=(-x "$PROXY")
        if curl "${a[@]}" "$u" 2>/dev/null && [ -s "$out.part" ]; then
            mv -f "$out.part" "$out"
            return 0
        fi
    done
    rm -f "$out.part"
    return 1
}

failed=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; finish_run' EXIT

title '1/6 创建目录'
mkdir -p "$BIN_DIR" "$PRIV_DIR" "$CONF_DIR/ruleset" "$CONF_DIR/ui" "$LOG_DIR" "$BACKUP_DIR" || die "无法在 $ROOT 下创建目录"
ok "$ROOT"

title "2/6 内核 mihomo ${KERNEL_VER}（darwin-${ARCH}）"
if [ -x "$MIHOMO_BIN" ] && [ "$FORCE" != 1 ]; then
    ok '已存在 bin/mihomo（加 --force 可覆盖）'
elif get_file "$KERNEL_URL" "$TMP/mihomo.gz"; then
    if gunzip -c "$TMP/mihomo.gz" > "$TMP/mihomo" && chmod 755 "$TMP/mihomo" && "$TMP/mihomo" -v >/dev/null 2>&1; then
        mv -f "$TMP/mihomo" "$MIHOMO_BIN"
        ok '已下载并解压到 bin/mihomo'
    else
        fail '内核压缩包解压后无法运行（下载不完整？）'
        failed=$((failed + 1))
    fi
else
    fail "内核下载失败（直连与镜像都没成功）：$KERNEL_URL"
    failed=$((failed + 1))
fi
[ -x "$MIHOMO_BIN" ] && info "$("$MIHOMO_BIN" -v 2>/dev/null | head -n 1)"

title '3/6 下载 zashboard 面板'
UI_DIR="$CONF_DIR/ui"
if [ -f "$UI_DIR/index.html" ] && [ "$FORCE" != 1 ]; then
    ok '面板已存在'
elif get_file "$UI_URL" "$TMP/ui.zip"; then
    mkdir -p "$TMP/ui"
    if unzip -q -o "$TMP/ui.zip" -d "$TMP/ui"; then
        inner="$TMP/ui/dist"
        [ -d "$inner" ] || inner="$TMP/ui"
        rm -rf "$UI_DIR" && mkdir -p "$UI_DIR" && cp -R "$inner/." "$UI_DIR/"
        ok '已解压到 config/ui'
    else
        fail '面板压缩包解压失败'; failed=$((failed + 1))
    fi
else
    fail "下载失败：$UI_URL"; failed=$((failed + 1))
fi

title '4/6 预下载规则集'
while IFS='|' read -r name url; do
    out="$CONF_DIR/ruleset/$name"
    if [ -s "$out" ] && [ "$FORCE" != 1 ]; then
        ok "$(printf '%-20s 已存在' "$name")"
    elif get_file "$url" "$out"; then
        ok "$(printf '%-20s %8s 字节' "$name" "$(stat -f %z "$out")")"
    else
        fail "$name 下载失败"; failed=$((failed + 1))
    fi
done <<EOF
$RULESETS
EOF

title '5/6 面板密钥'
if grep -q '__API_SECRET__' "$CONFIG_FILE"; then
    secret="$(openssl rand -hex 24 2>/dev/null)"
    [ -n "$secret" ] || secret="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
    # 写回原文件（cat >），保留文件的所有者与权限
    sed "s/__API_SECRET__/$secret/" "$CONFIG_FILE" > "$TMP/config.yaml" && cat "$TMP/config.yaml" > "$CONFIG_FILE"
    ok '已生成随机面板密钥（写入 config.yaml 的 secret）'
else
    ok '面板密钥已存在'
fi

title '6/6 私有文件'
for n in nodes infra-direct; do
    real="$PRIV_DIR/$n.yaml"
    tpl="$PRIV_DIR/$n.example.yaml"
    if [ ! -f "$real" ] && [ -f "$tpl" ]; then
        cp "$tpl" "$real"
        warn "已从模板创建 config/private/$n.yaml，请填写其中的占位符"
    elif [ -f "$real" ]; then
        ok "config/private/$n.yaml 已存在"
    fi
done

title '结果'
ph="$(list_placeholders)"
if [ -n "$ph" ]; then
    warn '还有占位符没填：'
    printf '%s\n' "$ph" | while IFS= read -r l; do info "- $l"; done
fi
if [ "$failed" -eq 0 ]; then
    ok '准备完成。下一步：填好 private 下的两个文件，然后运行 test-config.command'
else
    fail "$failed 项失败，请检查网络或代理后重试（已完成的项不会重复下载）"
    exit 1
fi
