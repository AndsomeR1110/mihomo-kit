#!/bin/bash
# 注册并启动 mihomo 守护进程（TUN 接管全部流量）。
# 前提：已运行 prepare、填好 private 文件、test-config 通过、Clash Verge / ClashX 已完全退出。
. "$(dirname "$0")/common.sh"

FORCE=0
for a in "$@"; do
    case "$a" in --force) FORCE=1 ;; --no-pause) NO_PAUSE=1 ;; esac
done
require_root "$@"
start_run_log install-service

title '1/5 前置检查'
check_kit_path
for f in "$MIHOMO_BIN" "$MAC_DIR/launchd/$LABEL.plist" "$MAC_DIR/launchd/$ROTATE_LABEL.plist"; do
    [ -e "$f" ] || die "缺少 $f，请先运行 prepare.command"
done
ok '程序文件齐全'

if app="$(conflict_app_running)"; then
    if [ "$FORCE" = 1 ]; then warn "$app 仍在运行（--force 忽略）"
    else die "$app 仍在运行：请先在它里面关闭系统代理 / TUN，再从菜单栏彻底退出，然后重试"; fi
else
    ok '没有其他代理软件在运行'
fi

if ! test_mihomo_config; then
    print_test_output
    die '配置检查未通过'
fi
ok '配置检查通过'

title '2/5 关闭系统代理'
if disable_local_system_proxy; then ok '已关闭指向本机的系统代理（改由 TUN 接管）'
else ok '没有指向本机的系统代理'; fi

title '3/5 注册守护进程'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; finish_run' EXIT
for l in "$LABEL" "$ROTATE_LABEL"; do
    sed "s|__KIT_ROOT__|$ROOT|g" "$MAC_DIR/launchd/$l.plist" > "$TMP/$l.plist"
    plutil -lint -s "$TMP/$l.plist" || die "生成的 $l.plist 格式不对"
done
mkdir -p "$LOG_DIR"
if cmp -s "$TMP/$LABEL.plist" "$PLIST"; then
    ok '守护进程已注册，跳过'
else
    if service_registered; then
        warn '已注册的守护进程指向别的目录或版本较旧，重新注册'
        stop_service
    fi
    install -m 0644 -o root -g wheel "$TMP/$LABEL.plist" "$PLIST" || die '写入 /Library/LaunchDaemons 失败'
    ok "守护进程 $LABEL 已注册（开机自启，崩溃自动拉起）"
fi
if ! cmp -s "$TMP/$ROTATE_LABEL.plist" "$ROTATE_PLIST"; then
    launchctl bootout "system/$ROTATE_LABEL" >/dev/null 2>&1
    install -m 0644 -o root -g wheel "$TMP/$ROTATE_LABEL.plist" "$ROTATE_PLIST"
fi
launchctl print "system/$ROTATE_LABEL" >/dev/null 2>&1 || launchctl bootstrap system "$ROTATE_PLIST"
ok '日志滚动已启用（5 MB × 5 份）'

title '4/5 启动守护进程'
start_service
if ! ver="$(wait_api 30)"; then
    fail '内核 30 秒内没有就绪，最近日志：'
    show_recent_log 30
    die '启动失败。可运行 rescue.command 恢复直连'
fi
ok "内核已就绪：$ver"
save_snapshot "$APPLIED_DIR"
ok '当前配置已保存为“最近一次成功应用”'

title '5/5 出口实测（经 TUN）'
sleep 3
probe "$PROBE_DIRECT"
info "国内直连：$(printf '%s' "$PROBE_BODY" | tr -s '[:space:]' ' ')"
trace "$PROBE_DEFAULT"
info "默认出口：ip=$TRACE_IP loc=$TRACE_LOC"
trace "$PROBE_AI"
if [ "$TRACE_LOC" = US ]; then ok "AI 出口：ip=$TRACE_IP loc=US"
else warn "AI 出口：ip=$TRACE_IP loc=$TRACE_LOC（应为 US，请在面板检查美国组）"; fi

echo ''
ok "完成。面板：$(api_base)/ui （后端地址 $(api_base)，密钥见 config.yaml 的 secret）"
