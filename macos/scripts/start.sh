#!/bin/bash
# 启动 mihomo 守护进程（并恢复为开机自启）
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log start

service_registered || die '守护进程未注册，请先运行 install.command'
if app="$(conflict_app_running)"; then die "$app 正在运行，两者端口相同、TUN 互相冲突，不能同时开。请先退出 $app"; fi
title '启动'
start_service
if ver="$(wait_api 30)"; then
    ok "内核已就绪：$ver（开机自启已恢复）"
    if test_egress; then ok '默认出口连通'; else warn '默认出口暂时不通，可在面板里换一个节点'; fi
else
    fail '内核 30 秒内没有就绪，最近日志：'
    show_recent_log 30
    exit 1
fi
