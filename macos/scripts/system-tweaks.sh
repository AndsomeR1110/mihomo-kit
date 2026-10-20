#!/bin/bash
# 系统层调整：关闭各网络服务（Wi-Fi、有线等）的 IPv6，防止 IPv6 流量绕过 TUN。
#   --apply   关闭（会记录原状态到 backup/system-state-macos.tsv）
#   --revert  按记录恢复
# 执行时网络可能短暂断开几秒。macOS 没有 Teredo，无需处理。
. "$(dirname "$0")/common.sh"
MODE=''
for a in "$@"; do
    case "$a" in --apply) MODE=apply ;; --revert) MODE=revert ;; --no-pause) NO_PAUSE=1 ;; esac
done
[ -n "$MODE" ] && require_root "$@"
start_run_log system-tweaks

STATE_FILE="$BACKUP_DIR/system-state-macos.tsv"
TAB="$(printf '\t')"

# Automatic / Off / Manual / LinkLocal；没有 IPv6 设置的服务（如部分 VPN）返回空
ipv6_mode() {
    networksetup -getinfo "$1" 2>/dev/null | sed -n 's/^IPv6: //p' | head -n 1
}

show_state() {
    title '当前状态'
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        m="$(ipv6_mode "$svc")"
        [ -n "$m" ] || continue
        case "$m" in Off) s='关闭' ;; Automatic) s='开启（自动）' ;; *) s="开启（$m）" ;; esac
        info "$(printf '%-24s IPv6: %s' "$svc" "$s")"
    done <<LIST
$(list_network_services)
LIST
}

case "$MODE" in
'')
    show_state
    info ''
    info '用法：system-tweaks-apply.command   关闭 IPv6'
    info '      system-tweaks-revert.command  恢复到调整前'
    ;;
apply)
    mkdir -p "$BACKUP_DIR"
    if [ ! -f "$STATE_FILE" ]; then
        while IFS= read -r svc; do
            [ -n "$svc" ] || continue
            m="$(ipv6_mode "$svc")"
            [ -n "$m" ] && printf '%s\t%s\n' "$svc" "$m"
        done > "$STATE_FILE" <<LIST
$(list_network_services)
LIST
        ok "原状态已记录到 $STATE_FILE"
    else
        ok '已有原状态记录，保留不覆盖'
    fi
    title '关闭 IPv6'
    while IFS="$TAB" read -r svc m; do
        [ -n "$svc" ] || continue
        if [ "$m" = Off ]; then ok "$svc（本来就是关闭的）"; continue; fi
        if networksetup -setv6off "$svc" 2>/dev/null; then ok "$svc"; else warn "$svc 设置失败，已跳过"; fi
    done < "$STATE_FILE"
    show_state
    warn '另请手动关闭浏览器的“使用安全 DNS”（Chrome/Edge：设置 → 隐私和安全 → 安全）'
    ;;
revert)
    [ -f "$STATE_FILE" ] || die "没有找到原状态记录 $STATE_FILE，无法自动恢复"
    title '恢复 IPv6'
    while IFS="$TAB" read -r svc m; do
        [ -n "$svc" ] || continue
        case "$m" in
            Automatic) networksetup -setv6automatic "$svc" && ok "$svc 已恢复为自动" ;;
            LinkLocal) networksetup -setv6LinkLocal "$svc" && ok "$svc 已恢复为仅本地链接" ;;
            Off) ok "$svc 原本就是关闭的，保持不变" ;;
            *) warn "$svc 原本是手动配置（$m），请在「系统设置 → 网络 → $svc → 详细信息 → TCP/IP」里手动恢复" ;;
        esac
    done < "$STATE_FILE"
    rm -f "$STATE_FILE"
    show_state
    ;;
esac
