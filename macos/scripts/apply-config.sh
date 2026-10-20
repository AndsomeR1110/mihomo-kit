#!/bin/bash
# 应用修改后的配置：检查 → 留快照 → 重启 → 健康检查；内核起不来就自动退回上一次成功的配置。
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log apply-config

service_registered || die '守护进程未注册，请先运行 install.command'

title '1/4 检查新配置'
if ! test_mihomo_config; then
    print_test_output
    die '新配置检查未通过，未做任何改动，内核继续使用原配置'
fi
ok '检查通过'

title '2/4 留快照'
snap="$HISTORY_DIR/$(date +%Y%m%d-%H%M%S)"
save_snapshot "$snap"
ok "新配置已存档：$snap"

title '3/4 重启内核'
stop_service
start_service
ver="$(wait_api 30)"

title '4/4 健康检查'
if [ -z "$ver" ]; then
    fail '新配置下内核 30 秒内没有就绪，最近日志：'
    show_recent_log 20
    if [ -f "$APPLIED_DIR/config.yaml" ]; then
        warn '正在自动退回上一次成功应用的配置……'
        restore_snapshot "$APPLIED_DIR"
        stop_service
        start_service
        if wait_api 30 >/dev/null; then ok '已退回并恢复运行。出问题的版本保存在上面的存档目录里'
        else fail '退回后仍无法启动，请运行 rescue.command 恢复直连'; fi
    else
        fail '没有可退回的版本，请运行 rescue.command 恢复直连'
    fi
    exit 1
fi
ok "内核已就绪：$ver"
save_snapshot "$APPLIED_DIR"
if test_egress; then ok '默认出口连通'
else warn '默认出口不通。若是新配置导致的，运行 rollback.command 退回“已知可用”版本'; fi
trace "$PROBE_AI"
if [ "$TRACE_LOC" = US ]; then ok 'AI 出口为美国'
else warn "AI 出口检查：ip=$TRACE_IP loc=$TRACE_LOC"; fi
info '新配置稳定用几天后，运行 mark-good.command 把它保存为“已知可用”版本'
