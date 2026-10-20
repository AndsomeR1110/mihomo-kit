#!/bin/bash
# 重启 mihomo 守护进程（不改配置）。适合网络异常时“重开一下”。
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log restart

service_registered || die '守护进程未注册，请先运行 install.command'
title '重启'
stop_service
start_service
if ver="$(wait_api 30)"; then
    ok "内核已就绪：$ver"
    if test_egress; then ok '默认出口连通'; else warn '默认出口暂时不通，可在面板里换一个节点'; fi
else
    fail '内核 30 秒内没有就绪，最近日志：'
    show_recent_log 30
    exit 1
fi
